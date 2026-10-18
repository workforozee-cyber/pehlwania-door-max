import 'package:sqflite_common/sqlite_api.dart';

import 'schema.dart';

class MigrationFailure implements Exception {
  final String message;
  MigrationFailure(this.message);
  @override
  String toString() => 'Database upgrade failed: $message';
}

/// Opens (and creates/upgrades) the business database.
///
/// The [factory] is `databaseFactory` from sqflite on Android and
/// `databaseFactoryFfi` in tests.
class AppDatabase {
  static const fileName = 'pehlwania_pos.db';

  static Future<Database> open(DatabaseFactory factory, String path, {int version = kSchemaVersion}) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, v) async => _migrate(db, 0, v),
        onUpgrade: (db, oldV, newV) async => _migrate(db, oldV, newV),
        onDowngrade: (db, oldV, newV) async {
          // An older app version must never touch a newer database.
          throw MigrationFailure(
              'This database was created by a newer app version (schema $oldV). Install the latest app; your data has not been changed.');
        },
      ),
    );
    await verifyIntegrity(db);
    return db;
  }

  /// Runs inside the open transaction created by sqflite: all-or-nothing.
  static Future<void> _migrate(Database db, int from, int to) async {
    for (var v = from + 1; v <= to; v++) {
      final steps = kMigrations[v];
      if (steps == null) throw MigrationFailure('No migration defined for version $v');
      for (final sql in steps) {
        await db.execute(sql);
      }
    }
    final fk = await db.rawQuery('PRAGMA foreign_key_check');
    if (fk.isNotEmpty) {
      throw MigrationFailure('Relationship check failed after upgrade (${fk.length} problems)');
    }
  }

  static Future<void> verifyIntegrity(Database db) async {
    final r = await db.rawQuery('PRAGMA quick_check');
    final msg = r.isEmpty ? 'no result' : r.first.values.first.toString();
    if (msg != 'ok') throw MigrationFailure('Database integrity check failed: $msg');
  }
}
