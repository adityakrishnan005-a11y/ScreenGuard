import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/utils/format.dart';

class AppLimitDialog extends StatefulWidget {
  final String app;
  final String appName;
  final int currentLimitMs;

  const AppLimitDialog({
    super.key,
    required this.app,
    required this.appName,
    this.currentLimitMs = 0,
  });

  @override
  State<AppLimitDialog> createState() => _AppLimitDialogState();
}

class _AppLimitDialogState extends State<AppLimitDialog> {
  late int _selectedMs;
  late TextEditingController _customController;
  bool _isCustom = false;

  @override
  void initState() {
    super.initState();
    _selectedMs = widget.currentLimitMs == 0 ? 30 * 60 * 1000 : widget.currentLimitMs;
    final initialMinutes = (_selectedMs / (60 * 1000)).round();
    _customController = TextEditingController(text: initialMinutes.toString());
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _onCustomChanged(String val) {
    final mins = int.tryParse(val.trim());
    if (mins != null && mins > 0) {
      setState(() {
        _selectedMs = mins * 60 * 1000;
        _isCustom = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = [
      {'label': '15m', 'ms': 15 * 60 * 1000},
      {'label': '30m', 'ms': 30 * 60 * 1000},
      {'label': '45m', 'ms': 45 * 60 * 1000},
      {'label': '1 hour', 'ms': 60 * 60 * 1000},
      {'label': '2 hours', 'ms': 120 * 60 * 1000},
    ];

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.timer_outlined, color: Colors.teal),
          const SizedBox(width: 8),
          Expanded(child: Text('Daily Limit: ${widget.appName}')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set a daily screen time limit for this app. ScreenGuard will notify you and minimize the app when time expires.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text('Presets:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets.map((p) {
                final ms = p['ms'] as int;
                final selected = !_isCustom && _selectedMs == ms;
                return ChoiceChip(
                  label: Text(p['label'] as String),
                  selected: selected,
                  onSelected: (_) {
                    setState(() {
                      _selectedMs = ms;
                      _isCustom = false;
                      _customController.text = (ms / (60 * 1000)).round().toString();
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            const Text('Or Enter Custom Minutes:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _customController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                labelText: 'Custom Time (Minutes)',
                suffixText: 'minutes',
                prefixIcon: Icon(Icons.edit_calendar_rounded, size: 20),
              ),
              onChanged: _onCustomChanged,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Selected Quota:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  formatDuration(_selectedMs),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16, color: Colors.teal),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (widget.currentLimitMs > 0)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              final db = Provider.of<DatabaseService>(context, listen: false);
              db.deleteAppLimit(widget.app);
              Navigator.of(context).pop();
            },
            child: const Text('Remove Limit'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final db = Provider.of<DatabaseService>(context, listen: false);
            db.setAppLimit(widget.app, _selectedMs);
            Navigator.of(context).pop();
          },
          child: const Text('Save Limit'),
        ),
      ],
    );
  }
}
