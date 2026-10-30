import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/notification_service.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/app_icon.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/widgets/screen_time_ring.dart';
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

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎉 All Focus Sessions Complete! Great work!'),
        ),
      );
    }
  }


  void _startSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.startFocusSession(_selectedDurationMinutes);
    _loadState();

    NotificationService.show(
      db: db,
      eventKey: 'focus_mode',
      title: 'Focus Mode Started 🎯',
      body: 'Focus session active for $_selectedDurationMinutes minutes.',
      icon: 'dialog-information',
    );
  }

  void _pauseSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.pauseFocusSession();
    _loadState();

    NotificationService.show(
      db: db,
      eventKey: 'focus_mode',
      title: 'Focus Mode Paused ⏸️',
      body: 'Your focus session is temporarily paused.',
      icon: 'dialog-information',
    );
  }

  void _resumeSession() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.resumeFocusSession();
    _loadState();

    NotificationService.show(
      db: db,
      eventKey: 'focus_mode',
      title: 'Focus Mode Resumed ▶️',
      body: 'Focus session resumed.',
      icon: 'dialog-information',
    );
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
        title: Row(
          children: [
            Icon(Icons.timer_outlined, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            const Text('Custom Focus Duration'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter duration in minutes:'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Minutes',
                suffixText: 'mins',
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
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
          FilledButton(
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

  String _ringCaption() {
    if (!_isActive) return 'FOCUS MODE TIMER';
    if (_isPaused) return _isBreak ? 'BREAK PAUSED' : 'SESSION PAUSED';
    return _isBreak ? 'BREAK TIME' : 'SESSION IN PROGRESS';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);

    final db = Provider.of<DatabaseService>(context);
    final completedCount = db.getCompletedFocusSessionsToday();
    // During break, the arc should fill over break duration; during focus, over focus duration
    final totalDurationSec = _isBreak
        ? _breakDurationMinutes * 60
        : _selectedDurationMinutes * 60;
    final progress = totalDurationSec > 0
        ? (1.0 - (_remainingSeconds / totalDurationSec)).clamp(0.0, 1.0)
        : 0.0;

    // Ring accent follows the session phase: blue for breaks, amber while
    // paused, and the brand primary for an idle or running focus session.
    final ringColor = _isPaused
        ? palette.warning
        : _isBreak
            ? palette.breakTime
            : scheme.primary;

    final presets = [15, 25, 45, 60];

    final filteredApps = _allApps.where((item) {
      final name = (item['app_name'] as String? ?? item['app'] as String).toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return AppScrollView(
      children: [
        const AppPageHeader(
          title: 'Focus',
          subtitle: 'Block distracting apps and protect deep work',
        ),
        const SizedBox(height: AppSpacing.xl),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;

            final timerCard = _buildTimerCard(
              context,
              palette: palette,
              scheme: scheme,
              completedCount: completedCount,
              progress: progress,
              ringColor: ringColor,
              presets: presets,
            );
            final appsCard = _buildAppsCard(
              context,
              db: db,
              palette: palette,
              filteredApps: filteredApps,
            );

            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: timerCard),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(flex: 4, child: appsCard),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                timerCard,
                const SizedBox(height: AppSpacing.lg),
                appsCard,
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildTimerCard(
    BuildContext context, {
    required AppPalette palette,
    required ColorScheme scheme,
    required int completedCount,
    required double progress,
    required Color ringColor,
    required List<int> presets,
  }) {
    final theme = Theme.of(context);
    final wide = AppLayout.of(context).size.width >= 1000;

    final pomodoroChip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: palette.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded, size: 16, color: palette.warning),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '$completedCount Pomodoro${completedCount == 1 ? '' : 's'} Today',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );

    return AppSectionCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            title: 'Focus mode',
            subtitle: 'Block distracting apps & stay in deep flow',
            trailing: pomodoroChip,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: AppSpacing.xl),

          // ── Countdown ring ────────────────────────────────────────────
          Center(
            child: Column(
              children: [
                ScreenTimeRing(
                  progress: _isActive ? progress : 0.0,
                  value: _formatTimerText(_remainingSeconds),
                  caption: _ringCaption(),
                  color: ringColor,
                  size: wide ? 220 : 190,
                  strokeWidth: wide ? 16 : 14,
                  icon: _isActive && _isBreak && !_isPaused
                      ? Icons.coffee_outlined
                      : null,
                  valueStyle: theme.textTheme.displaySmall?.copyWith(
                    fontSize: 44,
                  ),
                ),
                // Cycle counter
                if (_isActive && _totalCycles > 1) ...[
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: ringColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      'CYCLE $_currentCycle / $_totalCycles',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Presets (only while nothing is running) ───────────────────
          if (!_isActive) ...[
            const SizedBox(height: AppSpacing.xl),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              alignment: WrapAlignment.center,
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
          ],

          const SizedBox(height: AppSpacing.xl),

          // ── Action buttons ────────────────────────────────────────────
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!_isActive)
                FilledButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Start Focus Session'),
                )
              else ...[
                if (!_isPaused)
                  FilledButton.tonalIcon(
                    onPressed: _pauseSession,
                    icon: const Icon(Icons.pause_rounded),
                    label: Text(_isBreak ? 'Pause Break' : 'Pause Session'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _resumeSession,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_isBreak ? 'Resume Break' : 'Resume Session'),
                  ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.danger,
                    side: BorderSide(color: palette.danger.withValues(alpha: 0.55)),
                  ),
                  onPressed: _cancelSession,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Cancel Session'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppsCard(
    BuildContext context, {
    required DatabaseService db,
    required AppPalette palette,
    required List<Map<String, dynamic>> filteredApps,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final layoutToggle = SegmentedButton<bool>(
      showSelectedIcon: false,
      selected: {db.isFocusAppGridLayout()},
      onSelectionChanged: (selection) =>
          setState(() => db.setFocusAppGridLayout(selection.first)),
      segments: const [
        ButtonSegment(
          value: false,
          icon: Icon(Icons.subject_rounded, size: 18),
          label: Text('List'),
        ),
        ButtonSegment(
          value: true,
          icon: Icon(Icons.grid_view_rounded, size: 18),
          label: Text('Grid'),
        ),
      ],
    );

    return AppSectionCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            title: 'Distracting apps to block',
            subtitle:
                'Select apps that should be paused/minimized automatically during a Focus Session.',
            trailing: layoutToggle,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: AppSpacing.lg),

          // Search Input Field
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: 'Search installed apps...',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (val) => setState(() => _searchQuery = val),
          ),

          const SizedBox(height: AppSpacing.lg),

          if (filteredApps.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'No matching apps found.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (db.isFocusAppGridLayout())
            // Grid layout: GNOME app-grid style — icon above
            // the name, selection shown by a checkbox badge.
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 110,
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 0.92,
              ),
              itemCount: filteredApps.length,
              itemBuilder: (context, index) {
                final item = filteredApps[index];
                return _AppGridTile(
                  app: item['app'] as String,
                  name: item['app_name'] as String? ??
                      item['app'] as String,
                  selected: _distractingApps
                      .contains(item['app'] as String),
                  onTap: () {
                    db.toggleDistractingApp(item['app'] as String);
                    _loadState();
                  },
                );
              },
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
                  checkboxShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  title: Text(
                    name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    totalMs > 0
                        ? 'Total tracked: ${formatDuration(totalMs)}'
                        : 'Not yet tracked',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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
    );
  }
}

/// One tile in the grid app picker: themed icon over the app name, GNOME
/// app-grid style. Selection is a danger check badge in the icon's corner.
class _AppGridTile extends StatelessWidget {
  final String app;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _AppGridTile({
    required this.app,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  Widget _icon(BuildContext context, AppPalette palette) {
    final scheme = Theme.of(context).colorScheme;
    final path = AppIconService.resolve(app);
    final image = _appImage(context, path);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: selected
            ? palette.danger.withValues(alpha: 0.14)
            : scheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: image,
    );
  }

  Widget _appImage(BuildContext context, String? path) {
    final scheme = Theme.of(context).colorScheme;
    Widget letter() => Center(
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: scheme.primary,
            ),
          ),
        );
    if (path == null) {
      return letter();
    }
    if (AppIconService.isSvg(path)) {
      return SvgPicture.file(File(path), fit: BoxFit.contain);
    }
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => letter(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _icon(context, palette),
                if (selected)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.xxs),
                      decoration: BoxDecoration(
                        color: palette.danger,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 12,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? palette.danger : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
