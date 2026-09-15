import 'package:flutter/material.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/sound_service.dart';

class SettingsScreen extends StatefulWidget {
  final DatabaseService db;
  const SettingsScreen({super.key, required this.db});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // ── Tab 1: Notifications & Sounds ──────────────────────────────────────────
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

  bool _isPlayingTest = false;

  // ── Tab 2: Daily Limits & App Limits / Pomodoro ────────────────────────────
  late bool _pomodoroLoopEnabled;
  late int _pomodoroCycles;
  late int _pomodoroBreakMinutes;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _loadSettings() {
    // Tab 1
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

    // Tab 2
    _pomodoroLoopEnabled = widget.db.isPomodoroLoopEnabled();
    _pomodoroCycles = widget.db.getPomodoroCyclesCount();
    _pomodoroBreakMinutes = widget.db.getPomodoroBreakMinutes();
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
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.notifications_outlined), text: 'Notifications & Sounds'),
            Tab(icon: Icon(Icons.tune_outlined), text: 'Daily Limits & App Limits'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildNotificationsTab(),
          _buildLimitsTab(),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // TAB 1: Notifications & Sounds
  // ────────────────────────────────────────────────────────────────────────────

  Widget _buildNotificationsTab() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            _buildMasterCard(),
            const SizedBox(height: 16),
            _buildSoundSelectionCard(),
            const SizedBox(height: 16),
            _buildEventAlertsCard(),
            const SizedBox(height: 32),
          ],
        ),
      ),
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
