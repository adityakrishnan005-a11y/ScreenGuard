import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/sound_service.dart';
import 'package:screenguard/screens/settings_screen.dart';
import 'package:screenguard/utils/format.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  int _selectedDurationMinutes = 25;
  Timer? _timer;
  int _remainingSeconds = 0;
  bool _isActive = false;
  bool _isPaused = false;
  bool _isBreak = false;
  int _breakDurationMinutes = 5;
  int _currentCycle = 1;
  int _totalCycles = 1;
  Set<String> _distractingApps = {};
  List<Map<String, dynamic>> _allApps = [];
  final AppResolver _resolver = AppResolver();
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _resolver.init();
    _loadState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTimer());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _loadState() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    final state = db.getActiveFocusState();
    final apps = db.getDistractingApps();

    // Build a lookup of DB-tracked totals keyed by app id
    final tracked = db.allTrackedApps();
    final trackedTotals = <String, int>{};
    for (final row in tracked) {
      trackedTotals[row['app'] as String] = (row['t'] as int?) ?? 0;
    }

    // Get every installed app from .desktop files, overlay DB totals
    final installed = _resolver.listAllApps();
    final seenApps = <String>{};
    final merged = <Map<String, dynamic>>[];
    for (final entry in installed) {
      final appId = entry['app']!;
      seenApps.add(appId);
      merged.add({
        'app': appId,
        'app_name': entry['name']!,
        't': trackedTotals[appId] ?? 0,
      });
    }
    // Include any tracked apps whose .desktop wasn't found on disk
    for (final row in tracked) {
      final appId = row['app'] as String;
      if (!seenApps.contains(appId)) {
        merged.add(row);
      }
    }

    setState(() {
      _distractingApps = apps;
      _allApps = merged;
      if (state != null) {
        _isPaused = (state['is_paused'] as int? ?? 0) == 1;
        _isBreak = (state['is_break'] as int? ?? 0) == 1;
        _selectedDurationMinutes = state['duration_minutes'] as int;
        _breakDurationMinutes = state['break_duration_minutes'] as int? ?? 5;
        _currentCycle = state['current_cycle'] as int? ?? 1;
        _totalCycles = state['total_cycles'] as int? ?? 1;
        if (_isPaused) {
          _remainingSeconds = (state['remaining_seconds'] as int?) ??
              (_isBreak ? _breakDurationMinutes * 60 : _selectedDurationMinutes * 60);
          _isActive = true;
        } else {
          final endTime = state['end_time_ms'] as int;
          final now = DateTime.now().millisecondsSinceEpoch;
          _remainingSeconds = ((endTime - now) / 1000).ceil().clamp(0, 999999);
          _isActive = _remainingSeconds > 0;
        }
      } else {
        _isActive = false;
        _isPaused = false;
        _isBreak = false;
        _currentCycle = 1;
        _totalCycles = 1;
        _remainingSeconds = _selectedDurationMinutes * 60;
      }
    });
  }

  void _updateTimer() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    final state = db.getActiveFocusState();
    if (state != null) {
      final isPaused = (state['is_paused'] as int? ?? 0) == 1;
      final isBreakNow = (state['is_break'] as int? ?? 0) == 1;
      final cycle = state['current_cycle'] as int? ?? 1;
      final totalCyc = state['total_cycles'] as int? ?? 1;
      final brkMins = state['break_duration_minutes'] as int? ?? 5;

      if (isPaused) {
        setState(() {
          _isActive = true;
          _isPaused = true;
          _isBreak = isBreakNow;
          _currentCycle = cycle;
          _totalCycles = totalCyc;
          _breakDurationMinutes = brkMins;
          _remainingSeconds = (state['remaining_seconds'] as int?) ??
              (isBreakNow ? brkMins * 60 : _selectedDurationMinutes * 60);
        });
        return;
      }
      final endTime = state['end_time_ms'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final diff = ((endTime - now) / 1000).ceil();
      if (diff <= 0) {
        // Phase completed — let DB transition to next phase, then reload UI
        db.getActiveFocusState(); // triggers DB state machine
        _loadState(); // reload whatever phase is now active
      } else {
        setState(() {
          _isActive = true;
          _isPaused = false;
          _isBreak = isBreakNow;
          _currentCycle = cycle;
          _totalCycles = totalCyc;
          _breakDurationMinutes = brkMins;
          _remainingSeconds = diff;
        });
      }
    } else if (_isActive) {
      // Session fully ended (all cycles done)
      final durationMin = _selectedDurationMinutes;
      setState(() {
        _isActive = false;
        _isPaused = false;
        _isBreak = false;
        _currentCycle = 1;
        _totalCycles = 1;
        _remainingSeconds = durationMin * 60;
      });

      // Desktop Notification
      if (db.isNotificationsGloballyEnabled() && db.isEventNotificationEnabled('focus_mode')) {
        try {
          Process.run('notify-send', [
            '🎉 All Focus Sessions Complete!',
            'Amazing work! You finished your $durationMin min focus session.',
            '-i',
            'dialog-information',
            '-a',
            'ScreenGuard',
          ]);
        } catch (_) {}
      }

      // Sound cue
      if (db.isSoundGloballyEnabled() && db.isEventSoundEnabled('focus_mode')) {
        SoundService.playSound(
          soundId: db.getSoundTheme(),
          customPath: db.getCustomSoundPath(),
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎉 All Focus Sessions Complete! Great work!'),
          backgroundColor: Colors.teal,
        ),
      );
    }
  }


  void _startSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.startFocusSession(_selectedDurationMinutes);
    _loadState();

    // Desktop Notification
    if (db.isNotificationsGloballyEnabled() && db.isEventNotificationEnabled('focus_mode')) {
      try {
        Process.run('notify-send', [
          'Focus Mode Started 🎯',
          'Focus session active for $_selectedDurationMinutes minutes.',
          '-i',
          'dialog-information',
          '-a',
          'ScreenGuard',
        ]);
      } catch (_) {}
    }

    // Sound cue
    if (db.isSoundGloballyEnabled() && db.isEventSoundEnabled('focus_mode')) {
      SoundService.playSound(
        soundId: db.getSoundTheme(),
        customPath: db.getCustomSoundPath(),
      );
    }
  }

  void _pauseSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.pauseFocusSession();
    _loadState();

    if (db.isNotificationsGloballyEnabled() && db.isEventNotificationEnabled('focus_mode')) {
      try {
        Process.run('notify-send', [
          'Focus Mode Paused ⏸️',
          'Your focus session is temporarily paused.',
          '-i',
          'dialog-information',
          '-a',
          'ScreenGuard',
        ]);
      } catch (_) {}
    }
  }

  void _resumeSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.resumeFocusSession();
    _loadState();

    if (db.isNotificationsGloballyEnabled() && db.isEventNotificationEnabled('focus_mode')) {
      try {
        Process.run('notify-send', [
          'Focus Mode Resumed ▶️',
          'Focus session resumed.',
          '-i',
          'dialog-information',
          '-a',
          'ScreenGuard',
        ]);
      } catch (_) {}
    }

    if (db.isSoundGloballyEnabled() && db.isEventSoundEnabled('focus_mode')) {
      SoundService.playSound(
        soundId: db.getSoundTheme(),
        customPath: db.getCustomSoundPath(),
      );
    }
  }

  void _cancelSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.cancelFocusSession();
    _loadState();
  }

  Future<void> _showCustomDurationDialog() async {
    int customMins = _selectedDurationMinutes;
    final controller = TextEditingController(text: customMins.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.timer_outlined, color: Colors.teal),
            SizedBox(width: 8),
            Text('Custom Focus Duration'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter duration in minutes:'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Minutes',
                suffixText: 'mins',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [5, 10, 20, 30, 50, 90, 120].map((m) {
                return ActionChip(
                  label: Text('$m min'),
                  onPressed: () {
                    controller.text = m.toString();
                  },
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final val = int.tryParse(controller.text.trim());
              if (val != null && val > 0 && val <= 720) {
                Navigator.of(context).pop(val);
              }
            },
            child: const Text('Set Duration'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _selectedDurationMinutes = result;
        _remainingSeconds = result * 60;
      });
    }
  }

  String _formatTimerText(int seconds) {
    final m = (seconds / 60).floor().toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final db = Provider.of<DatabaseService>(context);
    final completedCount = db.getCompletedFocusSessionsToday();
    // During break, the arc should fill over break duration; during focus, over focus duration
    final totalDurationSec = _isBreak
        ? _breakDurationMinutes * 60
        : _selectedDurationMinutes * 60;
    final progress = totalDurationSec > 0
        ? (1.0 - (_remainingSeconds / totalDurationSec)).clamp(0.0, 1.0)
        : 0.0;

    final presets = [15, 25, 45, 60];

    final filteredApps = _allApps.where((item) {
      final name = (item['app_name'] as String? ?? item['app'] as String).toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('ScreenGuard — Digital Wellbeing for Linux', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Notifications & Sounds',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(db: context.read<DatabaseService>()),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1150),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Hero Section: Pomodoro Timer + Stats
                LayoutBuilder(
                  builder: (context, constraints) {
                    return Card(
                      elevation: 0.5,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Focus Mode 🎯',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Block distracting apps & stay in deep flow',
                                      style: TextStyle(color: Colors.grey, fontSize: 13),
                                    ),
                                  ],
                                ),
                                Chip(
                                  avatar: const Icon(Icons.workspace_premium_rounded,
                                      size: 16, color: Colors.amber),
                                  label: Text(
                                      '$completedCount Pomodoro${completedCount == 1 ? '' : 's'} Today'),
                                  backgroundColor: Colors.amber.withValues(alpha: 0.12),
                                ),
                              ],
                            ),
                            const SizedBox(height: 28),

                            // Circular Animated Timer
                            SizedBox(
                              width: 200,
                              height: 200,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  SizedBox(
                                    width: 200,
                                    height: 200,
                                    child: CircularProgressIndicator(
                                      value: _isActive ? progress : 0.0,
                                      strokeWidth: 10,
                                      color: _isPaused
                                          ? Colors.amber.shade700
                                          : _isBreak
                                              ? Colors.blue.shade400
                                              : Colors.teal,
                                      backgroundColor: (_isPaused
                                              ? Colors.amber
                                              : _isBreak
                                                  ? Colors.blue
                                                  : Colors.teal)
                                          .withValues(alpha: 0.12),
                                    ),
                                  ),
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Break icon when in break mode
                                      if (_isActive && _isBreak && !_isPaused) ...[
                                        Icon(Icons.coffee_outlined,
                                            size: 22, color: Colors.blue.shade400),
                                        const SizedBox(height: 4),
                                      ],
                                      Text(
                                        _formatTimerText(_remainingSeconds),
                                        style: const TextStyle(
                                          fontSize: 42,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: -1,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _isActive
                                            ? (_isPaused
                                                ? (_isBreak ? 'BREAK PAUSED' : 'SESSION PAUSED')
                                                : _isBreak
                                                    ? 'BREAK TIME'
                                                    : 'SESSION IN PROGRESS')
                                            : 'FOCUS MODE TIMER',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: _isPaused
                                              ? Colors.amber.shade800
                                              : _isBreak
                                                  ? Colors.blue.shade700
                                                  : Colors.teal.shade700,
                                          letterSpacing: 1,
                                        ),
                                      ),
                                      // Cycle counter
                                      if (_isActive && _totalCycles > 1) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          'CYCLE $_currentCycle / $_totalCycles',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: _isBreak
                                                ? Colors.blue.shade400
                                                : Colors.teal.shade400,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 28),

                            // Presets Selector & Custom Option (Disabled when active)
                            if (!_isActive) ...[
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ...presets.map((mins) {
                                    final isSelected = _selectedDurationMinutes == mins;
                                    return ChoiceChip(
                                      label: Text('$mins min'),
                                      selected: isSelected,
                                      onSelected: (_) {
                                        setState(() {
                                          _selectedDurationMinutes = mins;
                                          _remainingSeconds = mins * 60;
                                        });
                                      },
                                    );
                                  }),
                                  ChoiceChip(
                                    avatar: const Icon(Icons.tune_rounded, size: 16),
                                    label: Text(!presets.contains(_selectedDurationMinutes)
                                        ? '$_selectedDurationMinutes min (Custom)'
                                        : 'Custom'),
                                    selected: !presets.contains(_selectedDurationMinutes),
                                    onSelected: (_) => _showCustomDurationDialog(),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                            ],

                            // Action Buttons
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (!_isActive)
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 32, vertical: 14),
                                      backgroundColor: Colors.teal,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: _startSession,
                                    icon: const Icon(Icons.play_arrow_rounded,
                                        size: 24),
                                    label: const Text(
                                      'Start Focus Session',
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  )
                                else ...[
                                  if (!_isPaused)
                                    FilledButton.tonalIcon(
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 20, vertical: 14),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      onPressed: _pauseSession,
                                      icon: const Icon(Icons.pause_rounded, size: 22),
                                      label: Text(
                                        _isBreak ? 'Pause Break' : 'Pause Session',
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    )
                                  else
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 20, vertical: 14),
                                        backgroundColor: _isBreak ? Colors.blue.shade700 : Colors.teal,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      onPressed: _resumeSession,
                                      icon: const Icon(Icons.play_arrow_rounded, size: 22),
                                      label: Text(
                                        _isBreak ? 'Resume Break' : 'Resume Session',
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  const SizedBox(width: 12),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 14),
                                      foregroundColor: Colors.red,
                                      side: const BorderSide(color: Colors.red),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: _cancelSession,
                                    icon: const Icon(Icons.stop_rounded, size: 22),
                                    label: const Text(
                                      'Cancel Session',
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Distracting Apps Checklist
                Card(
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.block_rounded, color: Colors.redAccent),
                            SizedBox(width: 10),
                            Text(
                              'Distracting Apps to Block',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Select apps that should be paused/minimized automatically during a Focus Session.',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                        const SizedBox(height: 16),

                        // Search Input Field
                        TextField(
                          controller: _searchController,
                          decoration: const InputDecoration(
                            hintText: 'Search installed apps...',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.all(Radius.circular(10)),
                            ),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          onChanged: (val) => setState(() => _searchQuery = val),
                        ),

                        const SizedBox(height: 16),

                        if (filteredApps.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16.0),
                            child: Text('No matching apps found.',
                                style: TextStyle(color: Colors.grey)),
                          )
                        else
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: filteredApps.length,
                            itemBuilder: (context, index) {
                              final item = filteredApps[index];
                              final app = item['app'] as String;
                              final name =
                                  item['app_name'] as String? ?? app;
                              final totalMs = item['t'] as int? ?? 0;
                              final isBlocked = _distractingApps.contains(app);

                              return CheckboxListTile(
                                value: isBlocked,
                                activeColor: Colors.redAccent,
                                title: Text(
                                  name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600, fontSize: 14),
                                ),
                                subtitle: Text(
                                  totalMs > 0 ? 'Total tracked: ${formatDuration(totalMs)}' : 'Not yet tracked',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onChanged: (_) {
                                  db.toggleDistractingApp(app);
                                  _loadState();
                                },
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
