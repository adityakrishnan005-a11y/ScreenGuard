import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import 'package:screenguard/services/app_icon.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/notification_service.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';
import 'package:screenguard/utils/format.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/widgets/focus_profile_selector.dart';
import 'package:screenguard/widgets/screen_time_ring.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => FocusScreenState();
}

class FocusScreenState extends State<FocusScreen> {
  Timer? _timer;
  int _remainingSeconds = 0;
  bool _isActive = false;
  bool _isPaused = false;
  bool _isBreak = false;
  int _breakDurationMinutes = 5;
  int _currentCycle = 1;
  int _totalCycles = 1;

  List<Map<String, dynamic>> _profiles = [];
  int? _selectedProfileId;
  int? _activeProfileId;
  int _selectedDurationMinutes = 25;
  Set<String> _distractingApps = {};

  List<Map<String, dynamic>> _allApps = [];
  final AppResolver _resolver = AppResolver();
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _resolver.init();
    _loadApps();
    _loadState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTimer());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Reloads modes and settings. Called when the Focus tab becomes visible so
  /// changes made in Settings (for example the Pomodoro toggle) show up.
  void refresh() {
    _loadState();
  }

  Map<String, dynamic>? _findProfile(
    List<Map<String, dynamic>> profiles,
    int? id,
  ) {
    if (id == null) return null;
    for (final profile in profiles) {
      if (profile['id'] == id) return profile;
    }
    return null;
  }

  Map<String, dynamic>? get _currentProfile {
    final profiles = _profiles;
    return _findProfile(profiles, _selectedProfileId) ??
        (profiles.isEmpty ? null : profiles.first);
  }

  void _loadApps() {
    final db = Provider.of<DatabaseService>(context, listen: false);

    // Build a lookup of DB-tracked totals keyed by app id.
    final tracked = db.allTrackedApps();
    final trackedTotals = <String, int>{};
    for (final row in tracked) {
      trackedTotals[row['app'] as String] = (row['t'] as int?) ?? 0;
    }

    // Get every installed app from .desktop files, overlay DB totals.
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
    // Include any tracked apps whose .desktop wasn't found on disk.
    for (final row in tracked) {
      final appId = row['app'] as String;
      if (!seenApps.contains(appId)) {
        merged.add(row);
      }
    }

    setState(() => _allApps = merged);
  }

  void _loadState() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    final state = db.getActiveFocusState();
    final profiles = db.getFocusProfiles();

    var selected = db.getActiveFocusProfileId();
    if (selected == null && profiles.isNotEmpty) {
      selected = profiles.first['id'] as int;
    }

    int? activeProfileId;
    if (state != null) {
      final stateProfile = state['profile_id'] as int?;
      if (stateProfile != null && _findProfile(profiles, stateProfile) != null) {
        selected = stateProfile;
        activeProfileId = stateProfile;
      } else {
        activeProfileId = selected;
      }
    }

    final selectedProfile = _findProfile(profiles, selected) ??
        (profiles.isEmpty ? null : profiles.first);
    final effectiveId = selectedProfile?['id'] as int?;
    final apps = effectiveId != null
        ? db.getFocusProfileApps(effectiveId)
        : <String>{};

    setState(() {
      _profiles = profiles;
      _selectedProfileId = effectiveId;
      _activeProfileId = activeProfileId;
      _distractingApps = apps;

      if (state != null) {
        _isPaused = (state['is_paused'] as int? ?? 0) == 1;
        _isBreak = (state['is_break'] as int? ?? 0) == 1;
        _selectedDurationMinutes = state['duration_minutes'] as int? ??
            (selectedProfile?['duration_minutes'] as int?) ??
            25;
        _breakDurationMinutes = state['break_duration_minutes'] as int? ?? 5;
        _currentCycle = state['current_cycle'] as int? ?? 1;
        _totalCycles = state['total_cycles'] as int? ?? 1;
        if (_isPaused) {
          _remainingSeconds = (state['remaining_seconds'] as int?) ??
              (_isBreak
                  ? _breakDurationMinutes * 60
                  : _selectedDurationMinutes * 60);
          _isActive = true;
        } else {
          final endTime = state['end_time_ms'] as int;
          final now = DateTime.now().millisecondsSinceEpoch;
          _remainingSeconds =
              ((endTime - now) / 1000).ceil().clamp(0, 999999);
          _isActive = _remainingSeconds > 0;
        }
      } else {
        _isActive = false;
        _isPaused = false;
        _isBreak = false;
        _currentCycle = 1;
        _totalCycles = 1;
        _selectedDurationMinutes =
            (selectedProfile?['duration_minutes'] as int?) ?? 25;
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
      final stateProfile = state['profile_id'] as int?;

      if (isPaused) {
        setState(() {
          _isActive = true;
          _isPaused = true;
          _isBreak = isBreakNow;
          _currentCycle = cycle;
          _totalCycles = totalCyc;
          _breakDurationMinutes = brkMins;
          if (stateProfile != null) _activeProfileId = stateProfile;
          _remainingSeconds = (state['remaining_seconds'] as int?) ??
              (isBreakNow
                  ? brkMins * 60
                  : _selectedDurationMinutes * 60);
        });
        return;
      }
      final endTime = state['end_time_ms'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final diff = ((endTime - now) / 1000).ceil();
      if (diff <= 0) {
        // Phase completed — let DB transition to next phase, then reload UI.
        db.getActiveFocusState(); // triggers the DB state machine
        _loadState(); // reload whatever phase is now active
      } else {
        setState(() {
          _isActive = true;
          _isPaused = false;
          _isBreak = isBreakNow;
          _currentCycle = cycle;
          _totalCycles = totalCyc;
          _breakDurationMinutes = brkMins;
          if (stateProfile != null) _activeProfileId = stateProfile;
          _remainingSeconds = diff;
        });
      }
    } else if (_isActive) {
      // Session fully ended (all cycles done).
      _loadState();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎉 All Focus Sessions Complete! Great work!'),
        ),
      );
    }
  }

  void _showLockedMessage() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('End your current focus mode before starting this one.'),
        ),
      );
  }

  void _selectProfile(int id) {
    if (_isActive && id != _activeProfileId) {
      _showLockedMessage();
      return;
    }
    if (id == _selectedProfileId) return;

    final db = Provider.of<DatabaseService>(context, listen: false);
    db.setActiveFocusProfile(id);
    final profile = _findProfile(_profiles, id);
    setState(() {
      _selectedProfileId = id;
      _distractingApps = db.getFocusProfileApps(id);
      if (!_isActive) {
        _selectedDurationMinutes =
            (profile?['duration_minutes'] as int?) ?? 25;
        _remainingSeconds = _selectedDurationMinutes * 60;
      }
    });
  }

  void _toggleFocusApp(int profileId, String app) {
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.toggleFocusProfileApp(profileId, app);
    setState(() {
      final next = Set<String>.from(_distractingApps);
      if (!next.add(app)) next.remove(app);
      _distractingApps = next;
    });
  }

  void _updateProfile({
    int? durationMinutes,
    int? customDurationMinutes,
    int? totalCycles,
    int? breakMinutes,
  }) {
    final profile = _currentProfile;
    if (profile == null) return;
    final profileId = profile['id'] as int;
    final db = Provider.of<DatabaseService>(context, listen: false);
    db.updateFocusProfile(
      profileId,
      durationMinutes: durationMinutes,
      customDurationMinutes: customDurationMinutes,
      totalCycles: totalCycles,
      breakMinutes: breakMinutes,
    );

    final updated = db.getFocusProfile(profileId);
    setState(() {
      if (updated != null) {
        final index = _profiles.indexWhere((p) => p['id'] == profileId);
        if (index >= 0) _profiles[index] = updated;
      }
      if (durationMinutes != null) {
        _selectedDurationMinutes = durationMinutes;
        _remainingSeconds = durationMinutes * 60;
      }
    });
  }

  void _startSession() {
    final profile = _currentProfile;
    if (profile == null) return;
    final profileId = profile['id'] as int;
    final profileName = profile['name'] as String? ?? 'Focus';

    final db = Provider.of<DatabaseService>(context, listen: false);
    db.startFocusSession(_selectedDurationMinutes, profileId: profileId);
    _loadState();

    NotificationService.show(
      db: db,
      eventKey: 'focus_mode',
      title: 'Focus Mode Started 🎯',
      body: '$profileName focus session active for '
          '$_selectedDurationMinutes minutes.',
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
            Icon(Icons.timer_outlined,
                color: Theme.of(context).colorScheme.primary),
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
      _updateProfile(durationMinutes: result, customDurationMinutes: result);
    }
  }

  Future<void> _addProfile() async {
    if (_isActive) {
      _showLockedMessage();
      return;
    }
    final draft = await showDialog<_ProfileDraft>(
      context: context,
      builder: (context) => const _AddProfileDialog(),
    );
    if (draft == null || !mounted) return;

    final db = Provider.of<DatabaseService>(context, listen: false);
    final id = db.addFocusProfile(draft.name, icon: draft.icon);
    db.setActiveFocusProfile(id);
    _loadState();
  }

  Future<void> _renameCurrentProfile() async {
    final profile = _currentProfile;
    if (profile == null || _isActive) return;
    final controller =
        TextEditingController(text: profile['name'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename focus mode'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;

    final db = Provider.of<DatabaseService>(context, listen: false);
    db.updateFocusProfile(profile['id'] as int, name: name);
    _loadState();
  }

  Future<void> _changeCurrentProfileIcon() async {
    final profile = _currentProfile;
    if (profile == null || _isActive) return;
    final icon = await showDialog<String>(
      context: context,
      builder: (context) => _IconPickerDialog(
        selected: profile['icon'] as String? ?? 'center_focus_strong',
      ),
    );
    if (icon == null || !mounted) return;

    final db = Provider.of<DatabaseService>(context, listen: false);
    db.updateFocusProfile(profile['id'] as int, icon: icon);
    _loadState();
  }

  Future<void> _deleteCurrentProfile() async {
    final profile = _currentProfile;
    if (profile == null || _isActive) return;
    if ((profile['is_default'] as int? ?? 0) == 1) return;

    final name = profile['name'] as String? ?? 'this mode';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text(
          'The mode and its blocked-app list will be removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.of(context).danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final db = Provider.of<DatabaseService>(context, listen: false);
    db.deleteFocusProfile(profile['id'] as int);
    _loadState();
  }

  String _formatTimerText(int seconds) {
    final m = (seconds / 60).floor().toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _ringCaption(String profileName) {
    if (!_isActive) return 'READY TO START';
    if (_isPaused) return _isBreak ? 'BREAK PAUSED' : 'SESSION PAUSED';
    if (_isBreak) return 'BREAK TIME';
    return '${profileName.toUpperCase()} IN PROGRESS';
  }

  @override
  Widget build(BuildContext context) {
    final db = Provider.of<DatabaseService>(context);
    final completedCount = db.getCompletedFocusSessionsToday();
    final pomodoroEnabled = db.isPomodoroLoopEnabled();

    final filteredApps = _allApps.where((item) {
      final name =
          (item['app_name'] as String? ?? item['app'] as String).toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return AppScrollView(
      children: [
        const AppPageHeader(
          title: 'Focus',
          subtitle: 'Pick a mode, block distractions and protect deep work',
        ),
        const SizedBox(height: AppSpacing.xl),
        FocusProfileSelector(
          profiles: _profiles,
          selectedId: _selectedProfileId,
          locked: _isActive,
          onSelect: _selectProfile,
          onAdd: _addProfile,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildModeCard(
          context,
          db: db,
          completedCount: completedCount,
          pomodoroEnabled: pomodoroEnabled,
          filteredApps: filteredApps,
        ),
      ],
    );
  }

  Widget _buildModeCard(
    BuildContext context, {
    required DatabaseService db,
    required int completedCount,
    required bool pomodoroEnabled,
    required List<Map<String, dynamic>> filteredApps,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final profile = _currentProfile;

    if (profile == null) {
      return AppSectionCard(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          'No focus modes yet.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final profileId = profile['id'] as int;
    final profileName = profile['name'] as String? ?? 'Focus mode';
    final isDefault = (profile['is_default'] as int? ?? 0) == 1;

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
          Icon(Icons.workspace_premium_rounded,
              size: 16, color: palette.warning),
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

    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pomodoroChip,
        if (!_isActive) ...[
          const SizedBox(width: AppSpacing.xs),
          PopupMenuButton<String>(
            tooltip: 'Mode options',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  _renameCurrentProfile();
                  break;
                case 'icon':
                  _changeCurrentProfileIcon();
                  break;
                case 'delete':
                  _deleteCurrentProfile();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Rename'),
                ),
              ),
              const PopupMenuItem(
                value: 'icon',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.emoji_emotions_outlined),
                  title: Text('Change icon'),
                ),
              ),
              if (!isDefault)
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline_rounded,
                        color: palette.danger),
                    title: Text(
                      'Delete',
                      style: TextStyle(color: palette.danger),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );

    return AppSectionCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            title: profileName,
            subtitle: _isActive
                ? (_isBreak
                    ? 'Break time — apps stay blocked'
                    : 'Focus session in progress')
                : 'Choose apps to block and this mode’s timer',
            trailing: trailing,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: AppSpacing.xl),
          if (_isActive)
            _buildRunningBody(
              context,
              palette: palette,
              scheme: scheme,
              profileName: profileName,
            )
          else
            _buildIdleBody(
              context,
              db: db,
              palette: palette,
              scheme: scheme,
              profile: profile,
              profileId: profileId,
              profileName: profileName,
              pomodoroEnabled: pomodoroEnabled,
              filteredApps: filteredApps,
            ),
        ],
      ),
    );
  }

  Widget _buildIdleBody(
    BuildContext context, {
    required DatabaseService db,
    required AppPalette palette,
    required ColorScheme scheme,
    required Map<String, dynamic> profile,
    required int profileId,
    required String profileName,
    required bool pomodoroEnabled,
    required List<Map<String, dynamic>> filteredApps,
  }) {
    final theme = Theme.of(context);
    const presets = [15, 25, 45, 60];
    final isCustom = !presets.contains(_selectedDurationMinutes);

    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ScreenTimeRing(
            progress: 0,
            value: _formatTimerText(_selectedDurationMinutes * 60),
            caption: _ringCaption(profileName),
            color: palette.chartBar,
            size: 190,
            strokeWidth: 14,
            icon: focusProfileIcon(profile['icon'] as String? ?? ''),
            valueStyle: theme.textTheme.displaySmall?.copyWith(fontSize: 42),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          alignment: WrapAlignment.center,
          children: [
            ...presets.map((mins) {
              final selected = _selectedDurationMinutes == mins;
              return ChoiceChip(
                label: Text('$mins min'),
                selected: selected,
                onSelected: (_) => _updateProfile(durationMinutes: mins),
              );
            }),
            ChoiceChip(
              avatar: const Icon(Icons.tune_rounded, size: 16),
              label: Text(isCustom
                  ? '$_selectedDurationMinutes min (Custom)'
                  : 'Custom'),
              selected: isCustom,
              onSelected: (_) => _showCustomDurationDialog(),
            ),
          ],
        ),
        if (pomodoroEnabled) ...[
          const SizedBox(height: AppSpacing.xl),
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              children: [
                _buildStepper(
                  icon: Icons.repeat_one_outlined,
                  title: 'Focus cycles',
                  subtitle: 'Sessions before this mode stops',
                  value: profile['total_cycles'] as int? ?? 1,
                  min: 1,
                  max: 20,
                  unit: 'cycle',
                  onChanged: (value) => _updateProfile(totalCycles: value),
                ),
                const Divider(height: AppSpacing.xl),
                _buildStepper(
                  icon: Icons.coffee_outlined,
                  title: 'Break duration',
                  subtitle: 'Rest between each cycle',
                  value: profile['break_minutes'] as int? ?? 5,
                  min: 1,
                  max: 60,
                  unit: 'minute',
                  onChanged: (value) => _updateProfile(breakMinutes: value),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton.icon(
          onPressed: _startSession,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text('Start $profileName'),
        ),
      ],
    );

    final apps = _buildAppsPicker(
      context,
      db: db,
      profileId: profileId,
      profileName: profileName,
      filteredApps: filteredApps,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 760) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 4, child: settings),
              const SizedBox(width: AppSpacing.xl),
              Expanded(flex: 5, child: apps),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            settings,
            const SizedBox(height: AppSpacing.xxl),
            apps,
          ],
        );
      },
    );
  }

  Widget _buildRunningBody(
    BuildContext context, {
    required AppPalette palette,
    required ColorScheme scheme,
    required String profileName,
  }) {
    final theme = Theme.of(context);
    final totalDurationSec = _isBreak
        ? _breakDurationMinutes * 60
        : _selectedDurationMinutes * 60;
    final progress = totalDurationSec > 0
        ? (1.0 - (_remainingSeconds / totalDurationSec)).clamp(0.0, 1.0)
        : 0.0;
    final ringColor = _isPaused
        ? palette.warning
        : _isBreak
            ? palette.breakTime
            : palette.chartBar;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Column(
            children: [
              ScreenTimeRing(
                progress: progress,
                value: _formatTimerText(_remainingSeconds),
                caption: _ringCaption(profileName),
                color: ringColor,
                size: 210,
                strokeWidth: 16,
                icon: _isActive && _isBreak && !_isPaused
                    ? Icons.coffee_outlined
                    : null,
                valueStyle:
                    theme.textTheme.displaySmall?.copyWith(fontSize: 44),
              ),
              if (_totalCycles > 1) ...[
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
        const SizedBox(height: AppSpacing.xl),
        AppInfoBanner(
          icon: Icons.block_outlined,
          message: _isBreak
              ? 'Break in progress. Your blocked apps stay paused until the '
                  'next cycle starts.'
              : '${_distractingApps.length} app'
                  '${_distractingApps.length == 1 ? '' : 's'} blocked in '
                  '$profileName.',
        ),
        const SizedBox(height: AppSpacing.xl),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
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
                side: BorderSide(
                  color: palette.danger.withValues(alpha: 0.55),
                ),
              ),
              onPressed: _cancelSession,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Cancel Session'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepper({
    required IconData icon,
    required String title,
    required String subtitle,
    required int value,
    required int min,
    required int max,
    required String unit,
    required ValueChanged<int> onChanged,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Decrease',
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            minimumSize: const Size(34, 34),
            padding: EdgeInsets.zero,
          ),
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
        Container(
          constraints: const BoxConstraints(minWidth: 54),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            '$value ${value == 1 ? unit : '${unit}s'}',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Increase',
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            minimumSize: const Size(34, 34),
            padding: EdgeInsets.zero,
          ),
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline_rounded),
        ),
      ],
    );
  }

  Widget _buildAppsPicker(
    BuildContext context, {
    required DatabaseService db,
    required int profileId,
    required String profileName,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeader(
          title: 'Apps to block',
          subtitle: 'These apps are paused/minimized while $profileName runs.',
          trailing: layoutToggle,
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: AppSpacing.lg),
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
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 110,
              mainAxisSpacing: AppSpacing.md,
              crossAxisSpacing: AppSpacing.md,
              childAspectRatio: 0.92,
            ),
            itemCount: filteredApps.length,
            itemBuilder: (context, index) {
              final item = filteredApps[index];
              final app = item['app'] as String;
              return _AppGridTile(
                app: app,
                name: item['app_name'] as String? ?? app,
                selected: _distractingApps.contains(app),
                onTap: () => _toggleFocusApp(profileId, app),
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
              final name = item['app_name'] as String? ?? app;
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
                onChanged: (_) => _toggleFocusApp(profileId, app),
              );
            },
          ),
      ],
    );
  }
}

class _ProfileDraft {
  const _ProfileDraft(this.name, this.icon);

  final String name;
  final String icon;
}

class _AddProfileDialog extends StatefulWidget {
  const _AddProfileDialog();

  @override
  State<_AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<_AddProfileDialog> {
  final TextEditingController _controller = TextEditingController();
  String _icon = 'center_focus_strong';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_ProfileDraft(name, _icon));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('New focus mode'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Study time',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Icon',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _IconWrap(
                selected: _icon,
                onSelected: (icon) => setState(() => _icon = icon),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty ? null : _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _IconPickerDialog extends StatelessWidget {
  const _IconPickerDialog({required this.selected});

  final String selected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose an icon'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: _IconWrap(
            selected: selected,
            onSelected: (icon) => Navigator.of(context).pop(icon),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _IconWrap extends StatelessWidget {
  const _IconWrap({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final neon = AppPalette.of(context).chartBar;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: focusProfileIcons.entries.map((entry) {
        final isSelected = entry.key == selected;
        return InkWell(
          onTap: () => onSelected(entry.key),
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected
                  ? neon.withValues(alpha: 0.2)
                  : scheme.surfaceContainerHighest,
              border: Border.all(
                color: isSelected ? neon : Colors.transparent,
                width: 2,
              ),
            ),
            child: Icon(
              entry.value,
              size: 22,
              color: isSelected ? neon : scheme.onSurfaceVariant,
            ),
          ),
        );
      }).toList(),
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.sm,
        ),
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
                color: selected
                    ? palette.danger
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
