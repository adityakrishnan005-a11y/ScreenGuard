import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/tracker.dart';

void main() async {
  final db = DatabaseService();
  final resolver = AppResolver();
  final tracker = Tracker(db: db, resolver: resolver);
  await tracker.run();
}
