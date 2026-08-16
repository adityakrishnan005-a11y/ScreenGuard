import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/screens/dashboard.dart';

void main() {
  testWidgets('Dashboard builds with ScreenGuard title', (WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync();
    final db = DatabaseService();
    db.init(path: '${dir.path}/usage.db');
    await tester.pumpWidget(
      Provider<DatabaseService>.value(
        value: db,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.pump();
    expect(find.textContaining('ScreenGuard'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    db.close();
    dir.deleteSync(recursive: true);
  });
}
