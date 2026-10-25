import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/utils/format.dart';

class DailyGoalDialog extends StatefulWidget {
  final int currentGoalMs;

  const DailyGoalDialog({
    super.key,
    required this.currentGoalMs,
  });

  @override
  State<DailyGoalDialog> createState() => _DailyGoalDialogState();
}

class _DailyGoalDialogState extends State<DailyGoalDialog> {
  late int _selectedMs;
  late TextEditingController _hoursController;
  late TextEditingController _minutesController;
  bool _isCustom = false;

  @override
  void initState() {
    super.initState();
    _selectedMs = widget.currentGoalMs <= 0 ? 8 * 3600 * 1000 : widget.currentGoalMs;
    final totalMinutes = (_selectedMs / (60 * 1000)).round();
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;

    _hoursController = TextEditingController(text: hours.toString());
    _minutesController = TextEditingController(text: mins.toString());
  }

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  void _onCustomChanged() {
    final h = int.tryParse(_hoursController.text.trim()) ?? 0;
    final m = int.tryParse(_minutesController.text.trim()) ?? 0;
    final totalMs = (h * 3600 + m * 60) * 1000;
    if (totalMs > 0) {
      setState(() {
        _selectedMs = totalMs;
        _isCustom = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = [
      {'label': '2h', 'ms': 2 * 3600 * 1000},
      {'label': '4h', 'ms': 4 * 3600 * 1000},
      {'label': '6h', 'ms': 6 * 3600 * 1000},
      {'label': '8h', 'ms': 8 * 3600 * 1000},
      {'label': '10h', 'ms': 10 * 3600 * 1000},
      {'label': '12h', 'ms': 12 * 3600 * 1000},
    ];

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.flag_outlined, color: Colors.teal),
          SizedBox(width: 8),
          Text('Set Daily Goal'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set your target daily screen time limit. The dashboard progress bar will reflect your daily usage against this goal.',
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
                      final totalMinutes = (ms / (60 * 1000)).round();
                      _hoursController.text = (totalMinutes ~/ 60).toString();
                      _minutesController.text = (totalMinutes % 60).toString();
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            const Text('Or Enter Custom Time:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hoursController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      labelText: 'Hours',
                      suffixText: 'hrs',
                    ),
                    onChanged: (_) => _onCustomChanged(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _minutesController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      labelText: 'Minutes',
                      suffixText: 'mins',
                    ),
                    onChanged: (_) => _onCustomChanged(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Selected Goal:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  formatDuration(_selectedMs),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.teal),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (widget.currentGoalMs > 0)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              final db = Provider.of<DatabaseService>(context, listen: false);
              db.setDailyGoalMs(0);
              Navigator.of(context).pop(true);
            },
            child: const Text('Remove Goal'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final db = Provider.of<DatabaseService>(context, listen: false);
            db.setDailyGoalMs(_selectedMs);
            Navigator.of(context).pop(true);
          },
          child: const Text('Save Goal'),
        ),
      ],
    );
  }
}
