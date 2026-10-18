// Local persistence, financial integrity and migration tests (SQLite via FFI).
import 'package:flutter_test/flutter_test.dart';
import 'package:pehlwania_pos/data/app_database.dart';
import 'package:pehlwania_pos/data/money.dart';
import 'package:pehlwania_pos/data/repository.dart';
import 'package:pehlwania_pos/data/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/helpers.dart';

void main() {
  late Repository repo;

  setUp(() async {
    (repo, _) = await openRepo();
    await seedBasics(repo);
  });
  tearDown(() async => repo.db.close());

  group('schema & migrations', () {
    test('fresh database is created at the current schema version with integrity ok', () async {
      expect(await repo.db.getVersion(), kSchemaVersion);
      await AppDatabase.verifyIntegrity(repo.db);
      final fk = await repo.db.rawQuery('PRAGMA foreign_keys');
      expect(fk.first.values.first, 1);
    });

    test('reopening keeps data; opening with an OLDER app version is refused without changes', () async {
      final path = repo.db.path;
      await repo.applyBatch([StoreOp.put('documents', invoice('d1'))]);
      await repo.db.close();
      final again = await AppDatabase.open(databaseFactoryFfi, path);
      expect((await Repository(again).getAll('documents')).length, 1);
      await again.close();
      // pretend the file came from a newer app (schema +1): must not be downgraded
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.setVersion(kSchemaVersion + 1);
      await raw.close();
      await expectLater(AppDatabase.open(databaseFactoryFfi, path), throwsA(isA<MigrationFailure>()));
      final check = await databaseFactoryFfi.openDatabase(path);
      expect((await check.query('documents')).length, 1, reason: 'data untouched after refused open');
      await check.close();
      final fix = await databaseFactoryFfi.openDatabase(path);
      await fix.setVersion(kSchemaVersion);
      await fix.close();
      repo = Repository(await AppDatabase.open(databaseFactoryFfi, path)); // for tearDown
    });
  });

  group('persistence & round-trip', () {
    test('invoice with items + payments round-trips exactly (extra fields kept)', () async {
      final d = invoice('d1', customerId: 'c1');
      await repo.applyBatch([StoreOp.put('documents', d)]);
      final back = (await repo.get('documents', 'd1'))!;
      expect(back['no'], 'INV-0001');
      expect(back['statusLog'], d['statusLog'], reason: 'unmapped fields survive in extra');
      expect((back['items'] as List).length, 2);
      expect((back['items'] as List).first['mu'], 'in');
      expect((back['items'] as List).first['width'], 36);
      expect((back['payments'] as List).single['amount'], 5000);
      final row = (await repo.db.query('documents')).single;
      expect(row['grand_total'], 57000.0);
      final items = await repo.db.query('document_items', orderBy: 'line_no');
      expect(items.first['area_sqft'], closeTo(21, 1e-9));
      expect(items.first['line_total'], closeTo(21000, 1e-9));
    });

    test('money math matches the app: inches ÷144, feet unchanged, discount & tax', () {
      final d = invoice('x');
      final t = docTotals(d);
      expect(t.sub, 57000);
      expect(t.balance, 52000);
      d['discount'] = 1000;
      d['taxPct'] = 5;
      final t2 = docTotals(d);
      expect(t2.tax, jsRound(56000 * 0.05));
      expect(t2.grand, 56000 + 2800);
      expect(lineArea({'width': 36, 'height': 84, 'mu': 'in'}), 21);
      expect(lineArea({'width': 3, 'height': 7}), 21, reason: 'old lines without unit are feet');
    });

    test('a failing write rolls back the whole batch (atomic)', () async {
      final before = await repo.counts();
      await expectLater(
        repo.applyBatch([
          StoreOp.put('expenses', expense('e1', 500)),
          StoreOp.put('documents', invoice('d1')),
          StoreOp.put('documents', {...invoice('d2'), 'no': 'INV-0001'}), // duplicate number -> UNIQUE violation
        ]),
        throwsA(anything),
      );
      expect(await repo.counts(), before);
      expect(await repo.db.query('sync_queue', where: "entity = 'expenses'"), isEmpty);
    });

    test('invalid records are rejected with a clear message', () async {
      await expectLater(repo.applyBatch([StoreOp.put('customers', {'id': 'c9'})]), throwsA(predicate((e) => '$e'.contains('required'))));
      await expectLater(repo.applyBatch([StoreOp.put('expenses', {'id': 'e9', 'date': '2026-01-01', 'amount': 'abc'})]),
          throwsA(predicate((e) => '$e'.contains('number'))));
      await expectLater(repo.applyBatch([StoreOp.put('customers', {'name': 'no id'})]), throwsA(anything));
    });

    test('delete invoice removes items & payments, queues sheet deletions and keeps an audit record', () async {
      await repo.applyBatch([StoreOp.put('documents', invoice('d1'))]);
      await repo.db.delete('sync_queue');
      await repo.applyBatch([StoreOp.del('documents', 'd1')]);
      expect(await repo.db.query('document_items'), isEmpty);
      expect(await repo.db.query('payments'), isEmpty);
      final q = await repo.db.query('sync_queue', orderBy: 'entity');
      expect(q.map((r) => '${r['entity']}:${r['op']}').toSet(), {'documents:delete', 'document_items:delete', 'payments:delete'});
      final audit = await repo.db.query('audit_log', where: "action = 'deleted'");
      expect(audit.single['summary'], contains('"paid":5000'));
    });
  });

  group('financial integrity', () {
    test('payments are separate rows; re-saving with the same payment ID never duplicates it', () async {
      final d = invoice('d1');
      await repo.applyBatch([StoreOp.put('documents', d)]);
      final second = {'id': 'pay-2', 'amount': 12000, 'date': '2026-10-19', 'method': 'cash'};
      d['payments'] = [...d['payments'] as List, second];
      await repo.applyBatch([StoreOp.put('documents', d)]);
      await repo.applyBatch([StoreOp.put('documents', d)]); // retry / double tap
      final pays = await repo.db.query('payments', where: 'document_id = ?', whereArgs: ['d1']);
      expect(pays.length, 2);
      final back = (await repo.get('documents', 'd1'))!;
      expect(docTotals(back).balance, 57000 - 17000);
      final audit = await repo.db.query('audit_log', where: "action = 'payment_added'");
      expect(audit.length, 2);
    });

    test('changing a product rate never changes existing invoices (historical rate kept)', () async {
      await repo.applyBatch([StoreOp.put('documents', invoice('d1'))]);
      await repo.applyBatch([StoreOp.put('products', product('p1', 'Lassani door', 99999))]);
      final back = (await repo.get('documents', 'd1'))!;
      expect((back['items'] as List).first['rate'], 500);
      expect(docTotals(back).grand, 57000);
      expect(await repo.db.query('audit_log', where: "action = 'rate_changed'"), hasLength(1));
    });

    test('older lines without item/payment IDs get stable IDs on first save', () async {
      final d = invoice('d1');
      for (final it in d['items'] as List) {
        (it as Map).remove('id');
      }
      (d['payments'] as List).first.remove('id');
      await repo.applyBatch([StoreOp.put('documents', d)]);
      final back = (await repo.get('documents', 'd1'))!;
      final ids = [...(back['items'] as List).map((i) => i['id']), (back['payments'] as List).first['id']];
      expect(ids.every((i) => i is String && i.length == 36), isTrue);
      await repo.applyBatch([StoreOp.put('documents', back)]); // saving again keeps the same rows
      expect((await repo.db.query('document_items')).length, 2);
    });

    test('unchanged re-save does not queue anything for sync', () async {
      final d = invoice('d1');
      await repo.applyBatch([StoreOp.put('documents', d)]);
      await repo.db.delete('sync_queue');
      final r = await repo.applyBatch([StoreOp.put('documents', (await repo.get('documents', 'd1'))!)]);
      expect(r['queued'], 0);
    });
  });
}
