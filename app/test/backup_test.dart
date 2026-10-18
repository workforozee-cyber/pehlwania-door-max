// Backup export / validation / restore tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pehlwania_pos/backup/backup_service.dart';
import 'package:pehlwania_pos/data/money.dart';
import 'package:pehlwania_pos/data/repository.dart';

import 'support/helpers.dart';

void main() {
  late Repository repo;
  late Directory dir;
  late BackupService svc;

  setUp(() async {
    (repo, dir) = await openRepo();
    svc = BackupService(repo, safetyDir: () async => dir);
    await seedBasics(repo);
    await repo.applyBatch([
      StoreOp.put('documents', invoice('d1', customerId: 'c1')),
      StoreOp.put('documents', {...invoice('d2', no: 'INV-0002'), 'payments': <Map<String, dynamic>>[]}),
      StoreOp.put('expenses', expense('e1', 1500)),
      StoreOp.put('fixedexpenses', {'id': 'f1', 'name': 'Shop rent', 'amount': 40000, 'active': true, 'startMonth': '2026-01'}),
      StoreOp.put('gallery', {'id': 'g1', 'title': 'Door', 'img': 'data:image/jpeg;base64,AAAA', 'seeded': true}),
    ]);
  });
  tearDown(() async => repo.db.close());

  test('backup v3 contains every store, correct counts, totals and a valid checksum', () async {
    final text = await svc.buildBackupText();
    final j = jsonDecode(text) as Map;
    expect(j['format'], kBackupFormat);
    expect(j['formatVersion'], 3);
    final payload = jsonDecode(j['payload'] as String) as Map;
    expect((payload['documents'] as List).length, 2);
    expect((payload['fixedexpenses'] as List).length, 1);
    expect(j['counts']['documents'], 2);
    expect(j['totals']['invoiceGrand'], 114000);
    expect(j['totals']['payments'], 5000);
    final v = validateBackupText(text);
    expect(v.ok, isTrue, reason: v.errors.join(';'));
    expect(text.contains('ya29.'), isFalse, reason: 'no tokens in backups');
  });

  test('corrupted, edited and unsupported files are rejected before anything changes', () async {
    final text = await svc.buildBackupText();
    final j = jsonDecode(text) as Map<String, dynamic>;
    final edited = {...j, 'payload': (j['payload'] as String).replaceFirst('Ali Khan', 'Someone Else')};
    expect(validateBackupText(jsonEncode(edited)).errors.first, contains('Checksum mismatch'));
    expect(validateBackupText(jsonEncode({...j, 'formatVersion': 9})).errors.first, contains('newer app version'));
    expect(validateBackupText(text.substring(0, text.length ~/ 2)).ok, isFalse, reason: 'truncated file');
    expect(validateBackupText('{"hello":1}').ok, isFalse);
    // duplicate IDs inside a valid-checksum payload
    final p = jsonDecode(j['payload'] as String) as Map<String, dynamic>;
    (p['customers'] as List).add((p['customers'] as List).first);
    final payload = jsonEncode(p);
    final dup = {...j, 'payload': payload, 'payloadSha256': sha256Hex(payload)};
    expect(validateBackupText(jsonEncode(dup)).errors.join(), contains('duplicate ID'));
  });

  test('full restore replaces everything, verifies, and makes a safety backup first', () async {
    final text = await svc.buildBackupText();
    // change data after the backup
    await repo.applyBatch([StoreOp.del('documents', 'd1'), StoreOp.put('expenses', expense('e2', 77))]);
    final r = await svc.restore(validateBackupText(text));
    expect(r['ok'], isTrue);
    final docs = await repo.getAll('documents');
    expect(docs.length, 2);
    final d1 = docs.firstWhere((d) => d['id'] == 'd1');
    expect(docTotals(d1).balance, 52000);
    expect((d1['items'] as List).first['rate'], 500, reason: 'historical rate restored');
    expect((await repo.getAll('expenses')).map((e) => e['id']), ['e1'], reason: 'replace-all policy');
    final safety = Directory('${dir.path}/safety-backups').listSync();
    expect(safety, hasLength(1));
    expect(validateBackupText(File(safety.first.path).readAsStringSync()).counts['expenses'], 2,
        reason: 'safety backup holds the data from just before the restore');
    // sync metadata reset: every record pending again, nothing marked synced
    final pending = await repo.db.rawQuery("SELECT COUNT(*) AS n FROM sync_queue WHERE status = 'pending'");
    expect(pending.first['n'], greaterThan(0));
    expect(await repo.db.query('record_sync'), isEmpty);
  });

  test('a restore that fails half-way leaves the previous data intact', () async {
    final text = await svc.buildBackupText();
    final j = jsonDecode(text) as Map<String, dynamic>;
    final p = jsonDecode(j['payload'] as String) as Map<String, dynamic>;
    // two invoices with the same number pass validation but violate the database's UNIQUE rule
    (p['documents'] as List)[1]['no'] = 'INV-0001';
    final payload = jsonEncode(p);
    final bad = jsonEncode({...j, 'payload': payload, 'payloadSha256': sha256Hex(payload)});
    final v = validateBackupText(bad);
    expect(v.ok, isTrue);
    await repo.applyBatch([StoreOp.put('expenses', expense('keep-me', 10))]);
    await expectLater(svc.restore(v), throwsA(predicate((e) => '$e'.contains('undone') || '$e'.contains('failed'))));
    expect((await repo.getAll('expenses')).map((e) => e['id']).toSet(), {'e1', 'keep-me'});
    expect((await repo.getAll('documents')).length, 2);
  });

  test('original desktop (v2) backup files restore, older items get stable IDs', () async {
    final legacy = {
      '_app': 'PehlwaniaDoorMaxPOS', '_version': 2, 'exportedAt': '2026-07-20T10:00:00.000Z',
      'settings': [settingsApp()],
      'users': [{'id': 'u1', 'username': 'admin', 'name': 'Owner', 'pass': 'h', 'role': 'admin', 'perms': {}, 'active': true}],
      'customers': [customer('lc1', 'Old Customer')],
      'products': [product('lp1', 'Lassani door', 15000)],
      'documents': [
        {
          'id': 'ld1', 'type': 'invoice', 'no': 'INV-0007', 'date': '2026-07-01', 'customerId': '', 'customerName': 'Walk-in',
          'branchId': 'b1', 'discount': 0, 'taxPct': 0, 'orderStatus': 'pending', '_stockApplied': true, 'createdAt': 1,
          'items': [{'desc': 'Lassani door', 'width': '', 'height': '', 'qty': 2, 'unit': 'piece', 'rate': 15000, 'basis': 'piece', 'productId': 'lp1'}],
          'payments': [{'amount': 10000, 'date': '2026-07-01T09:00:00.000Z', 'method': 'advance'}],
        }
      ],
      'counters': [{'id': 'invoice', 'n': 7}],
      'suppliers': [], 'purchases': [], 'expenses': [], 'stockmoves': [], 'gallery': [],
    };
    final v = validateBackupText(jsonEncode(legacy));
    expect(v.ok, isTrue, reason: v.errors.join(';'));
    expect(v.warnings.first, contains('Older backup format'));
    await svc.restore(v);
    final d = (await repo.get('documents', 'ld1'))!;
    expect(docTotals(d).grand, 30000);
    expect(docTotals(d).balance, 20000);
    expect(((d['items'] as List).first['id'] as String).length, 36);
    expect(((d['payments'] as List).first['id'] as String).length, 36);
    expect(d.containsKey('customerId'), isFalse, reason: 'walk-in has no customer link');
    expect((await repo.get('counters', 'invoice'))!['n'], 7);
  });

  test('backup status keeps the last success when a later attempt fails', () async {
    await svc.recordSuccess(fileName: 'a.json', location: 'Downloads', sizeBytes: 100, counts: {'documents': 2});
    await svc.recordFailure('Disk full');
    final st = await svc.status();
    expect(st['fileName'], 'a.json');
    expect(st['lastSuccessAt'], isNotNull);
    expect(st['lastResult'], 'failed');
    expect(st['lastError'], 'Disk full');
  });
}
