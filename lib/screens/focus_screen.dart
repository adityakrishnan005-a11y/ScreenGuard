import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
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
  Set<String> _distractingApps = {};
  List<Map<String, dynamic>> _allTrackedApps = [];
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
    final tracked = db.allTrackedApps();

    setState(() {
      _distractingApps = apps;
      _allTrackedApps = tracked;
      if (state != null) {
        final endTime = state['end_time_ms'] as int;
        final now = DateTime.now().millisecondsSinceEpoch;
        _remainingSeconds = ((endTime - now) / 1000).ceil().clamp(0, 999999);
        _selectedDurationMinutes = state['duration_minutes'] as int;
        _isActive = _remainingSeconds > 0;
      } else {
        _isActive = false;
        _remainingSeconds = _selectedDurationMinutes * 60;
      }
    });
  }

  void _updateTimer() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    final state = db.getActiveFocusState();
    if (state != null) {
      final endTime = state['end_time_ms'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final diff = ((endTime - now) / 1000).ceil();
      if (diff <= 0) {
        // Completed
        db.getActiveFocusState(); // triggers completion logic
        setState(() {
          _isActive = false;
          _remainingSeconds = _selectedDurationMinutes * 60;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 Focus Session Completed! Great work!'),
            backgroundColor: Colors.teal,
          ),
        );
      } else {
        setState(() {
          _isActive = true;
          _remainingSeconds = diff;
        });
      }
    } else if (_isActive) {
      setState(() {
        _isActive = false;
        _remainingSeconds = _selectedDurationMinutes * 60;
      });
    }
  }

  void _startSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.startFocusSession(_selectedDurationMinutes);
    _loadState();
  }

  void _cancelSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.cancelFocusSession();
    _loadState();
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
    final totalDurationSec = _selectedDurationMinutes * 60;
    final progress = totalDurationSec > 0
        ? (1.0 - (_remainingSeconds / totalDurationSec)).clamp(0.0, 1.0)
        : 0.0;

    final presets = [15, 25, 45, 60];

    final filteredApps = _allTrackedApps.where((item) {
      final name = (item['app_name'] as String? ?? item['app'] as String).toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return SingleChildScrollView(
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
                                    color: Colors.teal,
                                    backgroundColor:
                                        Colors.teal.withValues(alpha: 0.12),
                                  ),
                                ),
                                Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
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
                                          ? 'SESSION IN PROGRESS'
                                          : 'POMODORO TIMER',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.teal.shade700,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 28),

                          // Presets Selector (Disabled when active)
                          if (!_isActive) ...[
                            Wrap(
                              spacing: 10,
                              children: presets.map((mins) {
                                final isSelected =
                                    _selectedDurationMinutes == mins;
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
                              }).toList(),
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
                              else
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 28, vertical: 14),
                                    foregroundColor: Colors.red,
                                    side: const BorderSide(color: Colors.red),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: _cancelSession,
                                  icon: const Icon(Icons.stop_rounded, size: 24),
                                  label: const Text(
                                    'Cancel Session',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
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
                          hintText: 'Search tracked apps...',
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
                          child: Text('No matching apps found in tracking history.',
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
                                'Total tracked: ${formatDuration(totalMs)}',
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
    );
  }
}
