// Google Sheets sync tests against an in-memory fake of the Sheets API.
// (A real Google account test must be done on a phone after the Google Cloud setup.)
import 'package:flutter_test/flutter_test.dart';
import 'package:pehlwania_pos/backup/backup_service.dart';
import 'package:pehlwania_pos/backup/drive_backup.dart';
import 'package:pehlwania_pos/data/repository.dart';
import 'package:pehlwania_pos/sync/sheets_schema.dart';
import 'package:pehlwania_pos/sync/sync_service.dart';

import 'support/fake_sheets.dart';
import 'support/helpers.dart';

void main() {
  late Repository repo;
  late FakeSheets sheets;
  late FakeAuth auth;
  late SyncService sync;
  var online = true;

  Future<int> queued([String status = 'pending']) async =>
      (await repo.db.rawQuery('SELECT COUNT(*) AS n FROM sync_queue WHERE status = ?', [status])).first['n'] as int;

  setUp(() async {
    (repo, _) = await openRepo();
    await seedBasics(repo);
    sheets = FakeSheets('sheet123');
    auth = FakeAuth();
    online = true;
    sync = SyncService(repo, auth, httpClient: () => sheets.client, isOnline: () async => online, deviceName: 'Test phone');
    await sync.init();
  });
  tearDown(() async => repo.db.close());

  Future<void> connectAndCreate() async {
    await sync.connect();
    await sync.createSpreadsheet();
  }

  test('changes made offline are kept and synced when internet returns', () async {
    online = false;
    await repo.applyBatch([StoreOp.put('documents', invoice('d1', customerId: 'c1')), StoreOp.put('expenses', expense('e1', 1500))]);
    // connect requires network in real life; here we connect, then go offline
    online = true;
    await sync.connect();
    online = false;
    final r = await sync.syncNow();
    expect(r['message'], contains('Offline'));
    expect(sheets.requests, greaterThan(0)); // only the connect call
    final before = sheets.requests;
    expect(await queued(), greaterThan(0));
    online = true;
    await sync.createSpreadsheet();
    expect(sheets.requests, greaterThan(before));
    expect(await queued(), 0);
    expect(sheets.rowsFor('Orders', 'd1'), hasLength(1));
    expect(sheets.rowsFor('Daily Expenses', 'e1'), hasLength(1));
    final st = await sync.status();
    expect(st['lastSuccessAt'], isNotNull);
    expect(st['state'], 'ok');
  });

  test('creates all tabs with the documented headers; rows matched by ID', () async {
    await repo.applyBatch([StoreOp.put('documents', invoice('d1', customerId: 'c1'))]);
    await connectAndCreate();
    for (final t in kTabs) {
      expect(sheets.tab(t.title).first, t.headers, reason: t.title);
    }
    expect(sheets.tab(kSyncLogTab).first, kSyncLogHeaders);
    final order = sheets.rowsFor('Orders', 'd1').single;
    expect(order[2], 'INV-0001');
    expect(order[12], 57000); // grand total
    expect(order[13], 5000); // paid
    expect(order[14], 52000); // balance
    expect(sheets.rowsFor('Order Items', 'd1-i1').single[13], 500, reason: 'agreed rate');
    expect(sheets.rowsFor('Payments', 'd1-p1').single[6], 5000);
    expect(sheets.rowsFor('Customers', 'c1'), hasLength(1));
    expect(sheets.rowsFor('Products & Rates', 'p1'), hasLength(1));
  });

  test('lost response after append does not create duplicates on retry', () async {
    await connectAndCreate();
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    sheets.dropNextAppendResponse = true; // Google applied it, phone never heard back
    final r1 = await sync.syncNow();
    expect(r1['message'], isNotNull);
    expect(await queued() + await queued('failed'), 1, reason: 'not marked synced without confirmation');
    await sync.retryFailed();
    expect(sheets.rowsFor('Daily Expenses', 'e1'), hasLength(1), reason: 'matched by ID, updated in place');
    expect(await queued() + await queued('failed'), 0);
  });

  test('updates change the existing row; payments are one row each, never duplicated', () async {
    final d = invoice('d1');
    await repo.applyBatch([StoreOp.put('documents', d)]);
    await connectAndCreate();
    d['payments'] = [...d['payments'] as List, {'id': 'pay-2', 'amount': 12000, 'date': '2026-10-19', 'method': 'cash'}];
    await repo.applyBatch([StoreOp.put('documents', d)]);
    await sync.syncNow();
    await sync.syncNow(); // nothing new
    expect(sheets.rowsFor('Orders', 'd1'), hasLength(1));
    expect(sheets.rowsFor('Orders', 'd1').single[14], 40000);
    expect(sheets.tab('Payments').skip(1).where((r) => r.isNotEmpty && r[1] == 'd1'), hasLength(2));
  });

  test('deleted records are marked Deleted, not removed; missing sheet row never deletes local data', () async {
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500)), StoreOp.put('expenses', expense('e2', 200))]);
    await connectAndCreate();
    await repo.applyBatch([StoreOp.del('expenses', 'e1')]);
    await sync.syncNow();
    final row = sheets.rowsFor('Daily Expenses', 'e1').single;
    expect(row[8], true);
    // someone deletes e2's row in the sheet: the phone keeps e2 and re-adds it on next change
    final tab = sheets.tab('Daily Expenses');
    tab.removeWhere((r) => r.isNotEmpty && r.first == 'e2');
    await sync.syncNow();
    expect(await repo.get('expenses', 'e2'), isNotNull);
    await repo.applyBatch([StoreOp.put('expenses', {...expense('e2', 250)})]);
    await sync.syncNow();
    expect(sheets.rowsFor('Daily Expenses', 'e2'), hasLength(1));
  });

  test('a financial row edited in the sheet is a conflict and is not overwritten until resolved', () async {
    final d = invoice('d1');
    await repo.applyBatch([StoreOp.put('documents', d)]);
    await connectAndCreate();
    // accountant edits the grand total cell by hand
    final row = sheets.tab('Orders').firstWhere((r) => r.isNotEmpty && r.first == 'd1');
    row[12] = 99999.0;
    d['note'] = 'deliver Friday';
    await repo.applyBatch([StoreOp.put('documents', d)]);
    final r = await sync.syncNow();
    expect(r['conflicts'], 1);
    expect(sheets.rowsFor('Orders', 'd1').single[12], 99999, reason: 'not overwritten automatically');
    expect((await sync.conflicts()).single['label'], 'INV-0001');
    expect((await sync.status())['state'], 'error');
    await sync.resolveConflicts('useDevice');
    expect(sheets.rowsFor('Orders', 'd1').single[12], 57000);
    expect(sheets.rowsFor('Orders', 'd1').single[18], 'deliver Friday');
    expect(await queued('conflict'), 0);
  });

  test('non-financial conflict: phone wins and the event is logged', () async {
    await connectAndCreate();
    await repo.applyBatch([StoreOp.put('customers', customer('c1', 'Ali Khan'))]);
    await sync.syncNow();
    sheets.tab('Customers').firstWhere((r) => r.isNotEmpty && r.first == 'c1')[1] = 'Edited in sheet';
    await repo.applyBatch([StoreOp.put('customers', {...customer('c1', 'Ali Khan Sahib')})]);
    await sync.syncNow();
    expect(sheets.rowsFor('Customers', 'c1').single[1], 'Ali Khan Sahib');
    expect((await sync.log()).any((l) => l['event'] == 'conflict_overwritten'), isTrue);
  });

  test('rate limit (429) on write: kept for retry with backoff; last success time not updated', () async {
    await connectAndCreate();
    final firstSuccess = (await sync.status())['lastSuccessAt'];
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    sheets.failAppendWith = 429;
    final r = await sync.syncNow();
    expect(r['failed'], 1);
    expect(await queued('failed'), 1);
    final op = (await repo.db.query('sync_queue')).single;
    expect(op['attempts'], 1);
    expect(op['next_attempt_at'] as int, greaterThan(DateTime.now().millisecondsSinceEpoch + 100 * 1000),
        reason: 'Retry-After 120 s respected');
    expect((await sync.status())['lastSuccessAt'], firstSuccess);
    await sync.syncNow(); // not due yet: nothing happens
    expect(sheets.rowsFor('Daily Expenses', 'e1'), isEmpty);
    // backoff grows and is capped
    expect(sync.backoff(1).inSeconds, inInclusiveRange(24, 36));
    expect(sync.backoff(5).inSeconds, inInclusiveRange(384, 576));
    expect(sync.backoff(40).inSeconds, lessThanOrEqualTo(6 * 3600 * 1.2));
    await sync.retryFailed(); // user taps Retry failed
    expect(sheets.rowsFor('Daily Expenses', 'e1'), hasLength(1));
    expect(await queued('failed'), 0);
  });

  test('server error on the first request: nothing lost, retried next time', () async {
    await connectAndCreate();
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    sheets.failNextWith = 503;
    await sync.syncNow();
    expect(await queued(), 1);
    await sync.syncNow();
    expect(sheets.rowsFor('Daily Expenses', 'e1'), hasLength(1));
  });

  test('expired token: refreshed once automatically', () async {
    await connectAndCreate();
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    sheets.unauthorizedOnce = 1;
    await sync.syncNow();
    expect(auth.cleared, greaterThanOrEqualTo(1));
    expect(sheets.rowsFor('Daily Expenses', 'e1'), hasLength(1));
  });

  test('revoked access / deleted spreadsheet: local data and queue kept, clear status', () async {
    await connectAndCreate();
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    sheets.forbidden = true;
    await sync.syncNow();
    expect((await sync.status())['state'], 'permission_error');
    expect(await queued(), 1);
    sheets.forbidden = false;
    sheets.exists = false;
    await sync.syncNow();
    expect((await sync.status())['state'], 'spreadsheet_missing');
    expect(await queued(), 1);
    expect(await repo.get('expenses', 'e1'), isNotNull);
    // auth revoked entirely
    sheets.exists = true;
    sheets.unauthorizedOnce = 5;
    await sync.syncNow();
    expect((await sync.status())['state'], 'auth_error');
    expect(await queued(), 1);
  });

  test('switching to a different spreadsheet uploads everything again, matched by ID', () async {
    await repo.applyBatch([StoreOp.put('documents', invoice('d1'))]);
    await connectAndCreate();
    final other = FakeSheets('other456')
      ..tabs['Notes'] = [['keep me']]; // unrelated content must be preserved
    final s2 = SyncService(repo, auth, httpClient: () => other.client, isOnline: () async => true);
    await s2.init();
    await s2.useSpreadsheet('other456');
    expect(other.rowsFor('Orders', 'd1'), hasLength(1));
    expect(other.tab('Notes'), [['keep me']]);
  });

  test('after a restore nothing is duplicated in the sheet', () async {
    await repo.applyBatch([StoreOp.put('documents', invoice('d1'))]);
    await connectAndCreate();
    final dir = await (await openRepo()).$2.create();
    final backups = BackupService(repo, safetyDir: () async => dir);
    final text = await backups.buildBackupText();
    await backups.restore(validateBackupText(text));
    await sync.syncNow();
    expect(sheets.rowsFor('Orders', 'd1'), hasLength(1));
    expect(sheets.rowsFor('Payments', 'd1-p1'), hasLength(1));
  });

  test('Sync Log tab gets a summary row; tokens never appear in logs', () async {
    await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    await connectAndCreate();
    expect(sheets.tab(kSyncLogTab).length, greaterThan(1));
    final all = (await sync.log()).map((l) => '${l['message']}').join(' ');
    expect(all.contains('ya29.'), isFalse);
  });

  test('Google sign-in not configured: clear state, app keeps working', () async {
    auth.failWith = 'NOT_CONFIGURED';
    await expectLater(sync.connect(), throwsA(anything));
    expect((await sync.status())['state'], 'not_configured');
    final r = await repo.applyBatch([StoreOp.put('expenses', expense('e1', 1500))]);
    expect(r['ok'], isTrue);
  });

  test('Drive backup uploads a verified, restorable backup', () async {
    await repo.applyBatch([StoreOp.put('documents', invoice('d1'))]);
    await sync.connect();
    final dir = await (await openRepo()).$2.create();
    final backups = BackupService(repo, safetyDir: () async => dir);
    final drive = DriveBackup(repo, backups, sync);
    final r = await drive.backupNow();
    expect(r['fileName'], startsWith('PehlwaniaPOS-backup'));
    final files = await drive.list();
    expect(files, hasLength(1));
    final v = await drive.download(files.first['id'] as String);
    expect(v.ok, isTrue, reason: v.errors.join(';'));
    expect(v.counts['documents'], 1);
    expect((await drive.status())['lastSuccessAt'], isNotNull);
  });
}
