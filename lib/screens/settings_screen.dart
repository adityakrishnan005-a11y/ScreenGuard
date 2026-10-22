import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/crash_reporter.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/feedback_service.dart';
import 'package:screenguard/services/sound_service.dart';
import 'package:screenguard/services/theme_service.dart';
import 'package:screenguard/services/update_checker.dart';
import 'package:screenguard/screens/crash_reports_screen.dart';

class SettingsScreen extends StatefulWidget {
  final DatabaseService db;
  final int initialTabIndex;
  const SettingsScreen({
    super.key,
    required this.db,
    this.initialTabIndex = 0,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedIndex = 0;

  // ── Tab 1: General ─────────────────────────────────────────────────────────
  late bool _notificationsEnabled;
  late bool _soundEnabled;
  late String _soundTheme;
  late String _customSoundPath;

  late bool _notifyGoal50;
  late bool _soundGoal50;
  late bool _notifyGoal100;
  late bool _soundGoal100;
  late bool _notifyGoalOvertime;
  late bool _soundGoalOvertime;
  late bool _notifyAppLimit;
  late bool _soundAppLimit;
  late bool _notifyFocusMode;
  late bool _soundFocusMode;
  late bool _notifyFeedback;

  bool _isPlayingTest = false;

  // ── Feedback ─────────────────────────────────────────────────────────────
  late FeedbackService _feedbackService;
  late String _feedbackPromptId;
  late String _feedbackLastCheck;
  bool _feedbackChecking = false;

  // ── Tab 2: Daily Limits & Pomodoro ─────────────────────────────────────────
  late bool _pomodoroLoopEnabled;
  late int _pomodoroCycles;
  late int _pomodoroBreakMinutes;
  late bool _focusStrictAutoclose;

  // ── Tab 4: Updates & Crash Reports ─────────────────────────────────────
  late UpdateChecker _updateChecker;
  late bool _checkUpdatesEnabled;
  late bool _includeBeta;
  late String _checkFrequency;
  late bool _crashReportingEnabled;
  bool _isCheckingUpdate = false;
  bool _isInstallingUpdate = false;
  bool _isSendingTestCrash = false;
  int _crashCount = 0;

  // ── Tab 5: Data & Storage ──────────────────────────────────────────────
  bool _dataLoading = true;
  int _dataFileBytes = 0;
  int _dataSessionCount = 0;
  DateTime? _dataOldest;
  DateTime? _dataNewest;
  DateTimeRange? _dataRange;
  final Set<DateTime> _dataDays = {};
  bool _dataBusy = false;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialTabIndex.clamp(0, 4);
    _loadSettings();
  }

  void _loadSettings() {
    // Tab 1: General
    _notificationsEnabled = widget.db.isNotificationsGloballyEnabled();
    _soundEnabled = widget.db.isSoundGloballyEnabled();
    _soundTheme = widget.db.getSoundTheme();
    _customSoundPath = widget.db.getCustomSoundPath();

    _notifyGoal50 = widget.db.isEventNotificationEnabled('daily_goal_50');
    _soundGoal50 = widget.db.isEventSoundEnabled('daily_goal_50');
    _notifyGoal100 = widget.db.isEventNotificationEnabled('daily_goal_100');
    _soundGoal100 = widget.db.isEventSoundEnabled('daily_goal_100');
    _notifyGoalOvertime = widget.db.isEventNotificationEnabled('goal_overtime');
    _soundGoalOvertime = widget.db.isEventSoundEnabled('goal_overtime');
    _notifyAppLimit = widget.db.isEventNotificationEnabled('app_limit');
    _soundAppLimit = widget.db.isEventSoundEnabled('app_limit');
    _notifyFocusMode = widget.db.isEventNotificationEnabled('focus_mode');
    _soundFocusMode = widget.db.isEventSoundEnabled('focus_mode');
    _notifyFeedback = widget.db.isEventNotificationEnabled('feedback');

    // Feedback requests published by the maintainer.
    _feedbackService = FeedbackService(db: widget.db);
    _feedbackPromptId = _feedbackService.storedPromptId;
    _feedbackLastCheck = _feedbackService.lastCheckTime;

    // Tab 2: Limits & Pomodoro
    _pomodoroLoopEnabled = widget.db.isPomodoroLoopEnabled();
    _pomodoroCycles = widget.db.getPomodoroCyclesCount();
    _pomodoroBreakMinutes = widget.db.getPomodoroBreakMinutes();
    _focusStrictAutoclose = widget.db.isFocusStrictAutoclose();

    // Tab 4: Updates & Crash Reports
    _updateChecker = UpdateChecker(db: widget.db);
    _checkUpdatesEnabled = _updateChecker.checkUpdatesEnabled;
    _includeBeta = _updateChecker.includeBeta;
    _checkFrequency = _updateChecker.checkFrequency;
    final crashReporter = CrashReporter();
    _crashCount = crashReporter.getCrashCount();
    _crashReportingEnabled = crashReporter.isReportingEnabled();

    _refreshDataStats();
  }

  void _refreshDataStats() {
    setState(() => _dataLoading = true);
    try {
      _dataFileBytes = widget.db.databaseFileSize();
      _dataSessionCount = widget.db.sessionCount();
      final range = widget.db.sessionDateRange();
      _dataOldest =
          range == null ? null : DateTime.fromMillisecondsSinceEpoch(range[0]);
      _dataNewest =
          range == null ? null : DateTime.fromMillisecondsSinceEpoch(range[1]);
    } catch (_) {
      _dataFileBytes = 0;
      _dataSessionCount = 0;
      _dataOldest = null;
      _dataNewest = null;
    }
    if (mounted) setState(() => _dataLoading = false);
  }

  Future<void> _pickCustomAudio() async {
    final path = await SoundService.pickAudioFile();
    if (path != null && mounted) {
      setState(() {
        _customSoundPath = path;
        _soundTheme = 'custom';
      });
      widget.db.setCustomSoundPath(path);
      widget.db.setSoundTheme('custom');
    }
  }

  Future<void> _testSound() async {
    setState(() => _isPlayingTest = true);
    await SoundService.playSound(
      soundId: _soundTheme,
      customPath: _customSoundPath,
    );
    if (mounted) {
      setState(() => _isPlayingTest = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            labelType: NavigationRailLabelType.all,
            groupAlignment: -1.0,
            minWidth: 88,
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('General'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.timer_outlined),
                selectedIcon: Icon(Icons.timer),
                label: Text('Limits &\nPomodoro', textAlign: TextAlign.center),
              ),
              NavigationRailDestination(
                icon: Badge(
                  isLabelVisible: _crashCount > 0,
                  label: Text('$_crashCount'),
                  child: const Icon(Icons.bug_report_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: _crashCount > 0,
                  label: Text('$_crashCount'),
                  child: const Icon(Icons.bug_report),
                ),
                label: const Text('Diagnostics'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.system_update_outlined),
                selectedIcon: Icon(Icons.system_update),
                label: Text('Updates'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.storage_outlined),
                selectedIcon: Icon(Icons.storage),
                label: Text('Data'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                _buildGeneralTab(),
                _buildLimitsTab(),
                _buildDaemonTab(),
                _buildUpdatesTab(),
                _buildDataTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 1: General
  // ────────────────────────────────────────────────────────────────────────────

  Widget _buildGeneralTab() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            _buildAppearanceCard(),
            const SizedBox(height: 16),
            _buildMasterCard(),
            const SizedBox(height: 16),
            _buildSoundSelectionCard(),
            const SizedBox(height: 16),
            _buildEventAlertsCard(),
            const SizedBox(height: 16),
            _buildFeedbackCard(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildAppearanceCard() {
    final themeService = Provider.of<ThemeService>(context);

    return _sectionCard(
      children: [
        _sectionHeader('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.palette_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
            ),
            title: const Text(
              'Theme Mode',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: const Text(
              'Choose adaptive (system default), light, or dark mode',
              style: TextStyle(fontSize: 12),
            ),
            trailing: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: themeService.themeModeString,
                borderRadius: BorderRadius.circular(12),
                items: const [
                  DropdownMenuItem(
                    value: 'system',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.brightness_auto_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('Adaptive'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'light',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.light_mode_rounded, size: 18, color: Colors.orange),
                        SizedBox(width: 8),
                        Text('Light'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'dark',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.dark_mode_rounded, size: 18, color: Colors.indigo),
                        SizedBox(width: 8),
                        Text('Dark'),
                      ],
                    ),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    themeService.setThemeMode(val);
                  }
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMasterCard() {
    return _sectionCard(
      children: [
        _sectionHeader('Master Controls'),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('Desktop Notifications', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Show system notification banners on desktop'),
          value: _notificationsEnabled,
          onChanged: (val) {
            setState(() => _notificationsEnabled = val);
            widget.db.setNotificationsGloballyEnabled(val);
          },
        ),
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.volume_up_outlined),
          title: const Text('Sound Effects', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Play audio cues for limits, goals, and focus mode'),
          value: _soundEnabled,
          onChanged: (val) {
            setState(() => _soundEnabled = val);
            widget.db.setSoundGloballyEnabled(val);
          },
        ),
      ],
    );
  }

  Widget _buildSoundSelectionCard() {
    final isCustom = _soundTheme == 'custom';
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: _soundEnabled ? 1.0 : 0.5,
      child: _sectionCard(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Sound Tone & Preview',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
              FilledButton.tonalIcon(
                onPressed: _soundEnabled && !_isPlayingTest ? _testSound : null,
                icon: _isPlayingTest
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: const Text('Test Sound'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...SoundService.presets.map((preset) {
            return RadioListTile<String>(
              title: Text(preset.label),
              value: preset.id,
              groupValue: _soundTheme,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: _soundEnabled
                  ? (val) {
                      if (val != null) {
                        setState(() => _soundTheme = val);
                        widget.db.setSoundTheme(val);
                      }
                    }
                  : null,
            );
          }),
          RadioListTile<String>(
            title: const Text('Custom Audio File (.ogg, .wav, .mp3)'),
            value: 'custom',
            groupValue: _soundTheme,
            dense: true,
            contentPadding: EdgeInsets.zero,
            onChanged: _soundEnabled
                ? (val) {
                    if (val != null) {
                      setState(() => _soundTheme = val);
                      widget.db.setSoundTheme(val);
                    }
                  }
                : null,
          ),
          if (isCustom) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.15)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.audio_file_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _customSoundPath.isNotEmpty
                          ? _customSoundPath
                          : 'No custom audio file selected yet',
                      style: TextStyle(
                        fontSize: 13,
                        fontStyle: _customSoundPath.isEmpty ? FontStyle.italic : FontStyle.normal,
                        color: _customSoundPath.isEmpty
                            ? Theme.of(context).textTheme.bodySmall?.color
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _soundEnabled ? _pickCustomAudio : null,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('Browse...'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEventAlertsCard() {
    return _sectionCard(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Alert Events',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Configure which notifications and sound effects trigger for each event',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _buildEventRow(
          icon: Icons.timelapse_outlined,
          title: '50% Daily Goal Milestone',
          subtitle: 'Gentle reminder when halfway through daily screen time target',
          notifyVal: _notifyGoal50,
          soundVal: _soundGoal50,
          onNotifyChanged: (val) {
            setState(() => _notifyGoal50 = val);
            widget.db.setEventNotificationEnabled('daily_goal_50', val);
          },
          onSoundChanged: (val) {
            setState(() => _soundGoal50 = val);
            widget.db.setEventSoundEnabled('daily_goal_50', val);
          },
        ),
        const Divider(height: 24),
        _buildEventRow(
          icon: Icons.flag_outlined,
          title: '100% Daily Goal Reached',
          subtitle: 'Alert when daily screen time target is reached',
          notifyVal: _notifyGoal100,
          soundVal: _soundGoal100,
          onNotifyChanged: (val) {
            setState(() => _notifyGoal100 = val);
            widget.db.setEventNotificationEnabled('daily_goal_100', val);
          },
          onSoundChanged: (val) {
            setState(() => _soundGoal100 = val);
            widget.db.setEventSoundEnabled('daily_goal_100', val);
          },
        ),
        const Divider(height: 24),
        _buildEventRow(
          icon: Icons.warning_amber_outlined,
          title: 'Goal Exceeded / Overtime',
          subtitle: 'Alerts at every +50% interval beyond your daily goal',
          notifyVal: _notifyGoalOvertime,
          soundVal: _soundGoalOvertime,
          onNotifyChanged: (val) {
            setState(() => _notifyGoalOvertime = val);
            widget.db.setEventNotificationEnabled('goal_overtime', val);
          },
          onSoundChanged: (val) {
            setState(() => _soundGoalOvertime = val);
            widget.db.setEventSoundEnabled('goal_overtime', val);
          },
        ),
        const Divider(height: 24),
        _buildEventRow(
          icon: Icons.timer_outlined,
          title: 'App Limits & Lockout',
          subtitle: '90% limit warning and 100% lockout alerts for restricted apps',
          notifyVal: _notifyAppLimit,
          soundVal: _soundAppLimit,
          onNotifyChanged: (val) {
            setState(() => _notifyAppLimit = val);
            widget.db.setEventNotificationEnabled('app_limit', val);
          },
          onSoundChanged: (val) {
            setState(() => _soundAppLimit = val);
            widget.db.setEventSoundEnabled('app_limit', val);
          },
        ),
        const Divider(height: 24),
        _buildEventRow(
          icon: Icons.psychology_outlined,
          title: 'Focus Mode Alerts',
          subtitle: 'Session start, completion, and distraction blocking notices',
          notifyVal: _notifyFocusMode,
          soundVal: _soundFocusMode,
          onNotifyChanged: (val) {
            setState(() => _notifyFocusMode = val);
            widget.db.setEventNotificationEnabled('focus_mode', val);
          },
          onSoundChanged: (val) {
            setState(() => _soundFocusMode = val);
            widget.db.setEventSoundEnabled('focus_mode', val);
          },
        ),
      ],
    );
  }

  Widget _buildFeedbackCard() {
    final theme = Theme.of(context);
    final lastCheck = _formatRelative(_feedbackLastCheck);

    return _sectionCard(
      children: [
        _sectionHeader('Feedback'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                color: theme.colorScheme.primary,
                size: 20,
              ),
            ),
            title: const Text(
              'Send feedback',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: const Text(
              'Tell the maintainer what works and what does not',
              style: TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => _openUrl(FeedbackService.feedbackHubUrl),
          ),
        ),
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.campaign_outlined),
          title: const Text(
            'Feedback request notifications',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Notify me when the maintainer asks for feedback',
            style: TextStyle(fontSize: 12),
          ),
          value: _notifyFeedback,
          onChanged: (val) {
            setState(() => _notifyFeedback = val);
            widget.db.setEventNotificationEnabled('feedback', val);
          },
        ),
        const Divider(height: 1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.sync_alt_rounded),
          title: Text(
            _feedbackPromptId.isEmpty
                ? 'No feedback request waiting'
                : 'Feedback request waiting: $_feedbackPromptId',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          subtitle: Text(
            'Last checked $lastCheck — ScreenGuard only downloads a small '
            'public file; your usage data never leaves this PC.',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_feedbackPromptId.isNotEmpty)
                IconButton(
                  tooltip: 'Clear request',
                  onPressed: _feedbackChecking ? null : _clearFeedbackRequest,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              IconButton(
                tooltip: 'Check now',
                onPressed: _feedbackChecking ? null : _checkFeedbackNow,
                icon: _feedbackChecking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _checkFeedbackNow() async {
    setState(() => _feedbackChecking = true);
    // fetchAndStore (not checkNow) — the user is already looking at the
    // result, so no desktop notification is needed.
    final changed = await _feedbackService.fetchAndStore();
    if (!mounted) return;
    setState(() {
      _feedbackChecking = false;
      _feedbackPromptId = _feedbackService.storedPromptId;
      _feedbackLastCheck = _feedbackService.lastCheckTime;
    });
    _snack(changed
        ? 'A new feedback request arrived.'
        : 'Checked — no new feedback request.');
  }

  void _clearFeedbackRequest() {
    _feedbackService.clearStoredPrompt();
    setState(() => _feedbackPromptId = _feedbackService.storedPromptId);
    _snack('Stored feedback request cleared.');
  }

  String _formatRelative(String iso) {
    if (iso.isEmpty) return 'never';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return 'never';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }

  Widget _buildEventRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool notifyVal,
    required bool soundVal,
    required ValueChanged<bool> onNotifyChanged,
    required ValueChanged<bool> onSoundChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Toggle Notification',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _notificationsEnabled ? () => onNotifyChanged(!notifyVal) : null,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    notifyVal && _notificationsEnabled
                        ? Icons.notifications_active
                        : Icons.notifications_off_outlined,
                    size: 20,
                    color: _notificationsEnabled
                        ? (notifyVal ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor)
                        : Theme.of(context).disabledColor.withOpacity(0.3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Toggle Sound',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _soundEnabled ? () => onSoundChanged(!soundVal) : null,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    soundVal && _soundEnabled ? Icons.volume_up : Icons.volume_off_outlined,
                    size: 20,
                    color: _soundEnabled
                        ? (soundVal ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor)
                        : Theme.of(context).disabledColor.withOpacity(0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 2: Daily Limits & App Limits
  // ────────────────────────────────────────────────────────────────────────────

  Widget _buildLimitsTab() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            _buildPomodoroLoopCard(),
            const SizedBox(height: 12),
            _buildFocusBlockingCard(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildPomodoroLoopCard() {
    final enabled = _pomodoroLoopEnabled;
    return _sectionCard(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Row(
          children: [
            Icon(Icons.repeat_outlined, size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Focus Mode Timer (Pomodoro Loop)',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Automatically repeat focus sessions with short breaks in between',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // ── Master toggle ────────────────────────────────────────────────────
        SwitchListTile(
          secondary: Icon(
            Icons.loop_outlined,
            color: enabled ? Theme.of(context).colorScheme.primary : null,
          ),
          title: const Text('Enable Pomodoro Loop', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            enabled
                ? 'Sessions will cycle automatically with breaks'
                : 'Single session mode — no auto-repeat',
          ),
          value: enabled,
          onChanged: (val) {
            setState(() => _pomodoroLoopEnabled = val);
            widget.db.setPomodoroLoopEnabled(val);
          },
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 24),
        // ── Number of cycles ─────────────────────────────────────────────────
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: enabled ? 1.0 : 0.4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStepperRow(
                icon: Icons.repeat_one_outlined,
                title: 'Number of Focus Cycles',
                subtitle: 'How many focus sessions to run before stopping',
                value: _pomodoroCycles,
                min: 1,
                max: 20,
                unit: _pomodoroCycles == 1 ? 'cycle' : 'cycles',
                enabled: enabled,
                onDecrement: () {
                  if (_pomodoroCycles > 1) {
                    setState(() => _pomodoroCycles--);
                    widget.db.setPomodoroCyclesCount(_pomodoroCycles);
                  }
                },
                onIncrement: () {
                  if (_pomodoroCycles < 20) {
                    setState(() => _pomodoroCycles++);
                    widget.db.setPomodoroCyclesCount(_pomodoroCycles);
                  }
                },
                onEdit: enabled ? () => _showNumberInputDialog(
                  title: 'Number of Focus Cycles',
                  currentValue: _pomodoroCycles,
                  minValue: 1,
                  maxValue: 20,
                  unit: 'cycles',
                  onConfirm: (val) {
                    setState(() => _pomodoroCycles = val);
                    widget.db.setPomodoroCyclesCount(val);
                  },
                ) : null,
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              // ── Break duration ─────────────────────────────────────────────
              _buildStepperRow(
                icon: Icons.coffee_outlined,
                title: 'Break Duration Between Sessions',
                subtitle: 'Rest time between each focus cycle',
                value: _pomodoroBreakMinutes,
                min: 1,
                max: 60,
                unit: _pomodoroBreakMinutes == 1 ? 'minute' : 'minutes',
                enabled: enabled,
                onDecrement: () {
                  if (_pomodoroBreakMinutes > 1) {
                    setState(() => _pomodoroBreakMinutes--);
                    widget.db.setPomodoroBreakMinutes(_pomodoroBreakMinutes);
                  }
                },
                onIncrement: () {
                  if (_pomodoroBreakMinutes < 60) {
                    setState(() => _pomodoroBreakMinutes++);
                    widget.db.setPomodoroBreakMinutes(_pomodoroBreakMinutes);
                  }
                },
                onEdit: enabled ? () => _showNumberInputDialog(
                  title: 'Break Duration',
                  currentValue: _pomodoroBreakMinutes,
                  minValue: 1,
                  maxValue: 60,
                  unit: 'minutes',
                  onConfirm: (val) {
                    setState(() => _pomodoroBreakMinutes = val);
                    widget.db.setPomodoroBreakMinutes(val);
                  },
                ) : null,
              ),
            ],
          ),
        ),
        // ── Info banner ───────────────────────────────────────────────────────
        if (enabled) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'When you start a session, it will repeat $_pomodoroCycles '
                    '${_pomodoroCycles == 1 ? "time" : "times"} with a '
                    '$_pomodoroBreakMinutes-minute break between each cycle.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFocusBlockingCard() {
    return _sectionCard(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(Icons.block_outlined,
                size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Blocked-App Handling',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'What happens when a limit hits 100% or you open a blocked app mid-focus',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          secondary: Icon(
            Icons.warning_amber_outlined,
            color: _focusStrictAutoclose
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
          title: const Text('Strict auto-close',
              style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            _focusStrictAutoclose
                ? 'ON: limit & focus apps are closed immediately — unsaved work can be lost'
                : 'OFF: window is only minimized, with a warning offering save time or manual close',
          ),
          value: _focusStrictAutoclose,
          onChanged: (val) {
            setState(() => _focusStrictAutoclose = val);
            widget.db.setFocusStrictAutoclose(val);
          },
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _buildStepperRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required int value,
    required int min,
    required int max,
    required String unit,
    required bool enabled,
    required VoidCallback onDecrement,
    required VoidCallback onIncrement,
    VoidCallback? onEdit,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 22, color: enabled ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Decrement
            _stepBtn(
              icon: Icons.remove,
              enabled: enabled && value > min,
              onTap: onDecrement,
            ),
            const SizedBox(width: 4),
            // Value display — tap to type
            InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: enabled
                      ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4)
                      : Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$value $unit',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: enabled
                        ? Theme.of(context).colorScheme.onPrimaryContainer
                        : Theme.of(context).disabledColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Increment
            _stepBtn(
              icon: Icons.add,
              enabled: enabled && value < max,
              onTap: onIncrement,
            ),
          ],
        ),
      ],
    );
  }

  Widget _stepBtn({required IconData icon, required bool enabled, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 18,
            color: enabled ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }

  Future<void> _showNumberInputDialog({
    required String title,
    required int currentValue,
    required int minValue,
    required int maxValue,
    required String unit,
    required ValueChanged<int> onConfirm,
  }) async {
    final controller = TextEditingController(text: '$currentValue');
    final formKey = GlobalKey<FormState>();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Value ($minValue – $maxValue $unit)',
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
            validator: (v) {
              final n = int.tryParse(v ?? '');
              if (n == null) return 'Enter a number';
              if (n < minValue || n > maxValue) return 'Must be between $minValue and $maxValue';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                onConfirm(int.parse(controller.text.trim()));
                Navigator.pop(ctx);
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 3: Diagnostics (Daemon + Crash Reports)
  // ────────────────────────────────────────────────────────────────────────────

  Widget _buildDaemonTab() {
    final daemonService = Provider.of<DaemonService>(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // ── Status & Main Controls Card ─────────────────────────────────
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (daemonService.isRunning ? Colors.teal : Colors.red)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        daemonService.isRunning
                            ? Icons.shield_rounded
                            : Icons.shield_outlined,
                        color: daemonService.isRunning ? Colors.teal : Colors.red,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Background Tracker Daemon',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: (daemonService.isRunning
                                          ? Colors.green
                                          : Colors.red)
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: daemonService.isRunning
                                        ? Colors.green
                                        : Colors.red,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: daemonService.isRunning
                                            ? Colors.green
                                            : Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      daemonService.isRunning
                                          ? 'RUNNING'
                                          : 'STOPPED',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                        color: daemonService.isRunning
                                            ? Colors.green.shade800
                                            : Colors.red.shade800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            daemonService.isRunning
                                ? 'The background daemon is actively tracking your screen time and enforcing focus mode & app limits.'
                                : 'The background daemon is inactive. Screen time tracking, daily limits, and focus mode blocking are currently paused.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Action Buttons
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    if (daemonService.isLoading)
                      const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      )
                    else if (daemonService.isRunning) ...[
                      // Stop button
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => daemonService.stopDaemon(),
                        icon: const Icon(Icons.stop_rounded, size: 20),
                        label: const Text('Stop Daemon'),
                      ),
                      // Restart button
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => daemonService.restartDaemon(),
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        label: const Text('Restart Daemon'),
                      ),
                    ] else ...[
                      // Start button
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => daemonService.startDaemon(enableAutostart: false),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Start Daemon (For Now)'),
                      ),
                      // Start and enable autostart
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => daemonService.startDaemon(enableAutostart: true),
                        icon: const Icon(Icons.all_inclusive_rounded, size: 20),
                        label: const Text('Start & Enable Autostart'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Autostart & System Settings Card ─────────────────────────────
            _sectionCard(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionHeader('System Startup'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.power_settings_new_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                  ),
                  title: const Text(
                    'Autostart Daemon on PC Boot',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Enable systemd user service so ScreenGuard tracking starts automatically whenever your computer turns on.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: daemonService.isAutostartEnabled,
                  onChanged: daemonService.isLoading
                      ? null
                      : (val) => daemonService.setAutostart(val),
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.restore_outlined),
                  title: const Text(
                    'Reset First-Run Setup Preference',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    'Show the setup prompt dialog next time ScreenGuard opens without an active daemon.',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  trailing: OutlinedButton(
                    onPressed: () {
                      widget.db.setSetting('daemon_initial_choice', '');
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Initial setup preference reset.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    child: const Text('Reset'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Crash Reports & Diagnostics Card ───────────────────────────
            _sectionCard(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionHeader('Crash Reports & Diagnostics'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.cloud_upload_outlined),
                  title: const Text(
                    'Send Anonymous Crash Reports',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Automatically transmit error traces and version info to the developer via Sentry. Strictly anonymous — no personal or screen time data is ever collected.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _crashReportingEnabled,
                  onChanged: (val) {
                    setState(() => _crashReportingEnabled = val);
                    final reporter = CrashReporter();
                    reporter.setReportingEnabled(val);
                  },
                ),
                const Divider(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Developer Connection Test',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'For ScreenGuard developers and contributors: sends a test ping to verify the error-telemetry pipeline reaches the developer dashboard. Regular users can safely ignore this.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _isSendingTestCrash
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : OutlinedButton.icon(
                            onPressed: _crashReportingEnabled
                                ? () async {
                                    setState(() => _isSendingTestCrash = true);
                                    final reporter = CrashReporter();
                                    final ok = await reporter.sendToSentry(
                                      level: 'info',
                                      source: 'gui',
                                      message: 'Manual test ping from ScreenGuard Settings',
                                    );
                                    if (mounted) {
                                      setState(() => _isSendingTestCrash = false);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            ok
                                                ? 'Diagnostic ping delivered to developer Sentry dashboard!'
                                                : 'Failed to deliver ping. Check your internet connection.',
                                          ),
                                          backgroundColor: ok ? Colors.teal : Colors.red,
                                        ),
                                      );
                                    }
                                  }
                                : null,
                            icon: const Icon(Icons.send_rounded, size: 16),
                            label: const Text('Send Test Ping'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                  ],
                ),
                const Divider(height: 24),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (_crashCount > 0 ? Colors.red : Colors.green)
                          .withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _crashCount > 0
                          ? Icons.bug_report_outlined
                          : Icons.check_circle_outline,
                      color: _crashCount > 0 ? Colors.red : Colors.green,
                      size: 20,
                    ),
                  ),
                  title: Text(
                    _crashCount > 0
                        ? '$_crashCount local crash ${_crashCount == 1 ? 'report' : 'reports'} stored'
                        : 'No local crash reports',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: Text(
                    _crashCount > 0
                        ? 'View details, stack traces, and report issues on GitHub'
                        : 'Everything is running smoothly',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: _crashCount > 0
                      ? FilledButton.tonal(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const CrashReportsScreen(),
                              ),
                            ).then((_) {
                              final reporter = CrashReporter();
                              setState(() {
                                _crashCount = reporter.getCrashCount();
                              });
                            });
                          },
                          child: const Text('View Reports'),
                        )
                      : null,
                ),
              ],
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 4: Updates
  // ────────────────────────────────────────────────────────────────────────────

  static const _repoUrl =
      'https://github.com/adityakrishnan005-a11y/ScreenGuard';

  Future<void> _openUrl(String url) async {
    try {
      await Process.run('xdg-open', [url]);
    } catch (_) {
      if (mounted) _snack('Could not open browser.');
    }
  }

  Widget _buildUpdatesTab() {
    final hasUpdate = _updateChecker.hasUpdate;
    final latestVersion = _updateChecker.lastKnownVersion;
    final currentVersion = _updateChecker.currentVersion;
    final lastCheck = _updateChecker.lastCheckTime;
    final changelog = _updateChecker.lastChangelog;
    final releaseUrl = _updateChecker.lastKnownVersionUrl;
    final isPrerelease = _updateChecker.isPrerelease;

    // Format last-checked time
    String lastCheckStr = 'Never';
    if (lastCheck.isNotEmpty) {
      try {
        final dt = DateTime.parse(lastCheck);
        final diff = DateTime.now().difference(dt);
        if (diff.inMinutes < 60) {
          lastCheckStr = '${diff.inMinutes} minutes ago';
        } else if (diff.inHours < 24) {
          lastCheckStr = '${diff.inHours} hours ago';
        } else {
          lastCheckStr = '${diff.inDays} days ago';
        }
      } catch (_) {}
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // ── Update Status Card ──────────────────────────────────────────
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (hasUpdate ? Colors.green : Theme.of(context).colorScheme.primary)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        hasUpdate
                            ? Icons.system_update_alt_rounded
                            : Icons.check_circle_outline_rounded,
                        color: hasUpdate ? Colors.green : Theme.of(context).colorScheme.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                hasUpdate ? 'Update Available' : 'ScreenGuard is up to date',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (hasUpdate && isPrerelease) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.orange.shade300),
                                  ),
                                  child: Text(
                                    'BETA',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.orange.shade800,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            hasUpdate
                                ? 'v$latestVersion is available (current: v$currentVersion)'
                                : 'v$currentVersion — Last checked: $lastCheckStr',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // Changelog snippet
                if (hasUpdate && changelog.isNotEmpty) ...[
                  Text(
                    'What\'s new in v$latestVersion',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      changelog,
                      style: const TextStyle(fontSize: 12.5),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Action buttons
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    // Check Now
                    if (_isCheckingUpdate)
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _checkUpdatesEnabled
                            ? () async {
                                setState(() => _isCheckingUpdate = true);
                                await _updateChecker.checkForUpdates();
                                if (mounted) {
                                  setState(() {
                                    _isCheckingUpdate = false;
                                    _checkUpdatesEnabled = _updateChecker.checkUpdatesEnabled;
                                    _includeBeta = _updateChecker.includeBeta;
                                    _checkFrequency = _updateChecker.checkFrequency;
                                  });
                                }
                              }
                            : null,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Check Now'),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),

                    // Download & Install
                    if (hasUpdate) ...[
                      if (_isInstallingUpdate)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      else
                        FilledButton.icon(
                          onPressed: () async {
                            // Set expectations BEFORE the sweep closes the
                            // GUI: the installer announces and reopens, but
                            // the user should not be surprised by the
                            // disappearing window.
                            final proceed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Update ScreenGuard'),
                                content: const Text(
                                  'ScreenGuard will close itself, install a new version in its own systemd service, and reopen automatically.\n\n'
                                  'If nothing reopens, launch it from the applications menu.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Update now'),
                                  ),
                                ],
                              ),
                            );
                            if (proceed != true) return;
                            setState(() => _isInstallingUpdate = true);
                            final result = await _updateChecker
                                .downloadAndInstall(latestVersion);
                            if (mounted) {
                              setState(() => _isInstallingUpdate = false);
                              if (result.success) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      result.note.isEmpty
                                          ? 'Update installed! Restart ScreenGuard to use the new version.'
                                          : '${result.note} restart ScreenGuard to use the new version.',
                                    ),
                                    duration: const Duration(seconds: 5),
                                  ),
                                );
                              } else if (result.note.isNotEmpty) {
                                await showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('One manual step needed'),
                                    content: SingleChildScrollView(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'Automatic installation was not possible. Run this in a terminal (select the text to copy):',
                                            style: TextStyle(fontSize: 13),
                                          ),
                                          const SizedBox(height: 10),
                                          SelectableText(
                                            result.note,
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  ),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Installation failed. Try downloading manually from GitHub.',
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text('Install v$latestVersion'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),

                      // View release on GitHub
                      if (releaseUrl.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () {
                            try {
                              Process.run('xdg-open', [releaseUrl]);
                            } catch (_) {}
                          },
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('View Release'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),

                      // Dismiss
                      TextButton(
                        onPressed: () {
                          _updateChecker.dismissedVersion = latestVersion;
                          setState(() {});
                        },
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ],
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Update Preferences Card ─────────────────────────────────────
            _sectionCard(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionHeader('Update Preferences'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.update_outlined),
                  title: const Text(
                    'Check for Updates Automatically',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Notify when a new version of ScreenGuard is available',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _checkUpdatesEnabled,
                  onChanged: (val) {
                    setState(() => _checkUpdatesEnabled = val);
                    _updateChecker.checkUpdatesEnabled = val;
                  },
                ),
                const Divider(height: 1),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _checkUpdatesEnabled ? 1.0 : 0.4,
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule_outlined),
                        title: const Text(
                          'Check Frequency',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _checkFrequency,
                            borderRadius: BorderRadius.circular(12),
                            items: const [
                              DropdownMenuItem(value: 'daily', child: Text('Daily')),
                              DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                              DropdownMenuItem(value: 'never', child: Text('Never')),
                            ],
                            onChanged: _checkUpdatesEnabled
                                ? (val) {
                                    if (val != null) {
                                      setState(() => _checkFrequency = val);
                                      _updateChecker.checkFrequency = val;
                                    }
                                  }
                                : null,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.science_outlined),
                        title: const Text(
                          'Include Beta Versions',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        subtitle: const Text(
                          'Get notified about pre-release builds for early access to new features',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _includeBeta,
                        onChanged: _checkUpdatesEnabled
                            ? (val) {
                                setState(() => _includeBeta = val);
                                _updateChecker.includeBeta = val;
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ── About ScreenGuard ──────────────────────────────────────
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                _sectionHeader('About'),
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/icons/screenguard.png',
                        width: 48,
                        height: 48,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.shield_rounded,
                          size: 48,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ScreenGuard ${_updateChecker.currentVersion}',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'by Aditya Krishnan',
                            style: TextStyle(fontSize: 12.5),
                          ),
                          Text(
                            'GPLv3 • free software, your data never leaves this PC',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _openUrl(_repoUrl),
                      icon: const Icon(Icons.code_rounded, size: 18),
                      label: const Text('GitHub'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _openUrl(_repoUrl),
                      icon: const Icon(Icons.star_outline_rounded, size: 18),
                      label: const Text('Star'),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 5: Data & Storage
  // ────────────────────────────────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmtDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  DateTime _normDay(DateTime d) => DateTime(d.year, d.month, d.day);

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final first = _dataOldest ?? DateTime(now.year - 1, 1, 1);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(first.year, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _dataRange,
      helpText: 'Select date range to delete',
    );
    if (picked != null && mounted) {
      setState(() => _dataRange = picked);
    }
  }

  Future<void> _pickSingleDay() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime((_dataOldest ?? now).year, 1, 1),
      lastDate: today,
      initialDate: today,
      helpText: 'Select a date to delete',
    );
    if (picked != null && mounted) {
      setState(() => _dataDays.add(_normDay(picked)));
    }
  }

  Future<bool> _confirmDelete(String title, String body,
      {String action = 'Delete'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteRange() async {
    final range = _dataRange;
    if (range == null) return;
    final label = '${_fmtDay(range.start)} → ${_fmtDay(range.end)}';
    final ok = await _confirmDelete(
      'Delete history in range?',
      'This permanently deletes usage history from $label.\n'
      'App limits, block-list and settings are kept.',
    );
    if (!ok) return;
    setState(() => _dataBusy = true);
    int n = 0;
    try {
      n = widget.db.deleteSessionsInRange(range.start, range.end);
    } catch (e) {
      _snack('Delete failed: $e', error: true);
    }
    if (mounted) {
      setState(() {
        _dataBusy = false;
        _dataRange = null;
      });
      _refreshDataStats();
      _snack('Deleted history for $label ($n rows).');
    }
  }

  Future<void> _deleteDays() async {
    if (_dataDays.isEmpty) return;
    final sorted = _dataDays.toList()..sort();
    final label = sorted.map(_fmtDay).join(', ');
    final ok = await _confirmDelete(
      'Delete ${sorted.length} day${sorted.length == 1 ? '' : 's'}?',
      'This permanently deletes usage history for:\n$label\n'
      'App limits, block-list and settings are kept.',
    );
    if (!ok) return;
    setState(() => _dataBusy = true);
    int n = 0;
    try {
      n = widget.db.deleteSessionsOnDates(sorted);
    } catch (e) {
      _snack('Delete failed: $e', error: true);
    }
    if (mounted) {
      setState(() {
        _dataBusy = false;
        _dataDays.clear();
      });
      _refreshDataStats();
      _snack('Deleted $n rows for selected dates.');
    }
  }

  Future<void> _deleteAll() async {
    final ok = await _confirmDelete(
      'Delete ALL usage history?',
      'This permanently deletes every recorded session and focus session.\n'
      'App limits, block-list and settings are kept.\n'
      'This cannot be undone.',
      action: 'Delete everything',
    );
    if (!ok) return;
    setState(() => _dataBusy = true);
    int n = 0;
    try {
      n = widget.db.clearAllUsageData();
    } catch (e) {
      _snack('Delete failed: $e', error: true);
    }
    if (mounted) {
      setState(() {
        _dataBusy = false;
        _dataRange = null;
        _dataDays.clear();
      });
      _refreshDataStats();
      _snack('Cleared all usage history ($n rows).');
    }
  }

  Widget _buildDataTab() {
    final daemonService = Provider.of<DaemonService>(context);
    final sortedDays = _dataDays.toList()..sort();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                _sectionHeader('Stored Usage Data'),
                if (_dataLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.storage_outlined),
                    title: Text(
                      '${_fmtBytes(_dataFileBytes)} • $_dataSessionCount sessions',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _dataOldest == null
                          ? 'No history recorded yet.\n${widget.db.path}'
                          : '${_fmtDay(_dataOldest!)} → ${_fmtDay(_dataNewest!)}\n${widget.db.path}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      tooltip: 'Refresh',
                      onPressed: _dataBusy ? null : _refreshDataStats,
                      icon: const Icon(Icons.refresh_outlined),
                    ),
                  ),
                  if (daemonService.isRunning)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Tracker is running — deletions apply immediately and new activity keeps being recorded.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                _sectionHeader('Delete a Date Range'),
                const Text(
                  'Pick a start and end day on the calendar. Every session in that range is removed.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _dataBusy ? null : _pickRange,
                        icon: const Icon(Icons.date_range_outlined, size: 18),
                        label: Text(
                          _dataRange == null
                              ? 'Select range'
                              : '${_fmtDay(_dataRange!.start)} → ${_fmtDay(_dataRange!.end)}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange),
                      onPressed:
                          (_dataBusy || _dataRange == null) ? null : _deleteRange,
                      child: _dataBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Delete range'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                _sectionHeader('Delete Specific Dates'),
                const Text(
                  'Add individual days, then delete exactly those days.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _dataBusy ? null : _pickSingleDay,
                  icon: const Icon(Icons.add_outlined, size: 18),
                  label: const Text('Add a date'),
                ),
                if (sortedDays.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: sortedDays
                        .map((d) => Chip(
                              label: Text(_fmtDay(d)),
                              deleteIcon: const Icon(Icons.close, size: 16),
                              onDeleted: _dataBusy
                                  ? null
                                  : () => setState(() => _dataDays.remove(d)),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange),
                      onPressed: _dataBusy ? null : _deleteDays,
                      child: Text(
                          'Delete ${sortedDays.length} day${sortedDays.length == 1 ? '' : 's'}'),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            _sectionCard(
              padding: const EdgeInsets.all(20),
              children: [
                _sectionHeader('Danger Zone'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.delete_forever_outlined,
                      color: Colors.red,
                      size: 20,
                    ),
                  ),
                  title: const Text(
                    'Clear all usage history',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Removes every session and focus session. Limits and settings are kept.',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: (_dataBusy || _dataSessionCount == 0)
                        ? null
                        : _deleteAll,
                    child: const Text('Clear all'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Shared helpers
  // ────────────────────────────────────────────────────────────────────────────

  Widget _sectionCard({required List<Widget> children, EdgeInsetsGeometry? padding}) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor.withOpacity(0.1)),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
