// SQLite -> Google Sheets synchronisation.
//
// Order of operations for every business change (see Repository.applyBatch):
//   validate -> save in SQLite -> commit -> record a pending sync operation.
// This service later pushes pending operations. An operation is removed from the
// queue ("synced") ONLY after Google confirms the rows were written.
//
// Guarantees and limits (Google Sheets is not a database):
//  * Rows are matched by the record ID in column A, re-read on every run, so a
//    retry after a lost response updates the row instead of appending a duplicate.
//  * Deleted records are marked Deleted=TRUE, never removed (row numbers stay stable).
//  * A row edited by hand in the sheet since the app last wrote it is a conflict.
//    For orders, items and payments the app never overwrites it automatically;
//    for other tabs the phone's version wins and the event is logged.
//  * Sync is one-way (phone -> sheet). Edits made in the sheet are not imported.
//  * Two phones writing the SAME new record at the same moment cannot be fully
//    serialised by Sheets; IDs are generated per device so this needs the same
//    record to exist on both phones (only possible after restoring one backup on two phones).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common/sqlite_api.dart';

import '../data/repository.dart';
import 'google_api.dart';
import 'google_auth.dart';
import 'sheets_schema.dart';

class SyncService {
  final Repository repo;
  final GoogleAuth auth;
  final http.Client Function() httpClient;
  final Future<bool> Function() isOnline;
  final String deviceName;
  void Function(Map<String, Object?> status)? onStatus;

  SyncService(this.repo, this.auth,
      {required this.httpClient, required this.isOnline, this.deviceName = 'Android', this.onStatus});

  String? _token;
  Future<Map<String, dynamic>>? _running;
  Timer? _debounce;
  Map<String, dynamic> _config = {};
  final _rand = Random();

  bool get configured => _config['accountEmail'] != null && _config['spreadsheetId'] != null;

  Future<void> init() async {
    _config = await repo.kvJson('sync.config');
    repo.syncConfigured = () => configured;
  }

  GoogleApi _api() => GoogleApi(httpClient(), () async {
        _token ??= await auth.accessToken(interactive: false);
        return _token!;
      });

  // ------------------------------------------------------------ state
  Future<Map<String, dynamic>> _state() => repo.kvJson('sync.state');
  Future<void> _setState(Map<String, dynamic> patch) async {
    final s = await _state();
    s.addAll(patch);
    await repo.kvSetJson('sync.state', s);
  }

  Future<void> _saveConfig() => repo.kvSetJson('sync.config', _config);

  Future<void> _log(String event, {String? entity, String? recordId, String? result, String? message}) async {
    await repo.db.insert('sync_log', {
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': event, 'entity': entity, 'record_id': recordId, 'result': result,
      'message': message == null ? null : _sanitize(message),
    });
    // keep the local log bounded
    await repo.db.rawDelete('DELETE FROM sync_log WHERE id NOT IN (SELECT id FROM sync_log ORDER BY id DESC LIMIT 2000)');
  }

  /// Never log tokens or long payloads.
  String _sanitize(String m) {
    var s = m.replaceAll(RegExp(r'ya29\.[0-9A-Za-z\-_\.]+'), '[token]').replaceAll(RegExp(r'Bearer\s+\S+'), 'Bearer [token]');
    if (s.length > 300) s = '${s.substring(0, 300)}…';
    return s;
  }

  Future<Map<String, Object?>> status() async {
    final st = await _state();
    Future<int> count(String w) async =>
        (await repo.db.rawQuery('SELECT COUNT(*) AS n FROM sync_queue WHERE $w')).first['n'] as int? ?? 0;
    final errs = await repo.db.query('sync_log',
        where: "result IN ('failed','conflict','error')", orderBy: 'id DESC', limit: 5);
    final info = await auth.signingInfo();
    var state = st['state'] as String? ?? 'not_connected';
    if (_running != null) state = 'syncing';
    if (_config['accountEmail'] == null && state != 'not_configured') state = 'not_connected';
    if (_config['accountEmail'] != null && _config['spreadsheetId'] == null) state = 'no_spreadsheet';
    return {
      'state': state,
      'accountEmail': _config['accountEmail'],
      'spreadsheetId': _config['spreadsheetId'],
      'spreadsheetTitle': _config['spreadsheetTitle'],
      'spreadsheetUrl': _config['spreadsheetUrl'],
      'online': await isOnline(),
      'lastSuccessAt': st['lastSuccessAt'],
      'lastRunAt': st['lastRunAt'],
      'lastError': st['lastError'],
      'pending': await count("status = 'pending'"),
      'failed': await count("status = 'failed'"),
      'conflicts': await count("status = 'conflict'"),
      'recentErrors': errs.map((e) => {'at': e['at'], 'message': '${e['event']}: ${e['message'] ?? ''}'}).toList(),
      'packageName': info['packageName'],
      'sha1': info['sha1'],
    };
  }

  // --------------------------------------------------------- account
  Future<Map<String, Object?>> connect() async {
    try {
      _token = await auth.accessToken(interactive: true);
      final about = await _api().about();
      final email = ((about['user'] as Map?)?['emailAddress'] ?? '').toString();
      if (email.isEmpty) throw ApiError(500, 'Could not read the Google account');
      if (_config['accountEmail'] != null && _config['accountEmail'] != email) {
        await _log('account_changed', message: 'Account changed; spreadsheet access will be re-checked');
      }
      _config['accountEmail'] = email;
      await _saveConfig();
      await _setState({'state': _config['spreadsheetId'] == null ? 'no_spreadsheet' : 'ok', 'lastError': null});
      await _log('connected', result: 'ok', message: email);
      if (_config['spreadsheetId'] != null) unawaited(syncNow());
      return {'message': 'Connected as $email'};
    } on AuthFailure catch (e) {
      await _setState({'state': e.code == 'NOT_CONFIGURED' ? 'not_configured' : 'auth_error', 'lastError': e.message});
      await _log('connect', result: 'error', message: e.message);
      rethrow;
    }
  }

  Future<Map<String, Object?>> disconnect() async {
    final t = _token;
    _token = null;
    if (t != null) await auth.clearToken(t);
    _config.remove('accountEmail');
    await _saveConfig();
    await _setState({'state': 'not_connected', 'lastError': null});
    await _log('disconnected', result: 'ok', message: 'Data on the phone and pending changes were kept');
    return {'message': 'Disconnected. Your data stays on this phone.'};
  }

  Future<Map<String, Object?>> createSpreadsheet() async {
    _requireAccount();
    final api = _api();
    final res = await _guard(() => api.createSpreadsheet(
        'Pehlwania Door Max — Business Records', [...kTabs.map((t) => t.title), kSyncLogTab]));
    await _switchTo(res['spreadsheetId'] as String, (res['properties'] as Map?)?['title']?.toString(), res['spreadsheetUrl']?.toString());
    await _log('spreadsheet_created', result: 'ok', message: _config['spreadsheetTitle']?.toString());
    final r = await syncNow();
    return {'message': 'Spreadsheet created. ${r['message'] ?? ''}'};
  }

  Future<Map<String, Object?>> useSpreadsheet(String id) async {
    _requireAccount();
    final api = _api();
    final ss = await _guard(() => api.getSpreadsheet(id));
    await _switchTo(id, (ss['properties'] as Map?)?['title']?.toString(), ss['spreadsheetUrl']?.toString());
    await _log('spreadsheet_selected', result: 'ok', message: _config['spreadsheetTitle']?.toString());
    final r = await syncNow();
    return {'message': 'Spreadsheet connected. ${r['message'] ?? ''}'};
  }

  void _requireAccount() {
    if (_config['accountEmail'] == null) throw StateError('Connect a Google account first.');
  }

  /// A different spreadsheet: what was written to the old one says nothing about
  /// the new one. Upload everything again, matched by ID (existing rows updated).
  Future<void> _switchTo(String id, String? title, String? url) async {
    final changed = _config['spreadsheetId'] != id;
    _config['spreadsheetId'] = id;
    _config['spreadsheetTitle'] = title ?? id;
    _config['spreadsheetUrl'] = url ?? 'https://docs.google.com/spreadsheets/d/$id';
    await _saveConfig();
    if (changed) {
      await repo.db.transaction((txn) async {
        await txn.delete('record_sync');
        await repo.enqueueAll(txn);
      });
    }
  }

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on ApiError catch (e) {
      if (e.isAuth && _token != null) {
        await auth.clearToken(_token!);
        _token = null;
        return await f();
      }
      rethrow;
    }
  }

  // ------------------------------------------------------------ sync
  /// Called after local changes: waits a little so several saves go together.
  void scheduleSoon([Duration delay = const Duration(seconds: 20)]) {
    if (!configured) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(syncNow().catchError((_) => <String, dynamic>{})));
  }

  Future<Map<String, dynamic>> syncNow() {
    // only one sync at a time; concurrent callers share the running one
    final running = _running;
    if (running != null) return running;
    final f = _runGuarded();
    _running = f;
    return f.whenComplete(() => _running = null);
  }

  Future<Map<String, dynamic>> _runGuarded() async {
    if (_config['accountEmail'] == null) return {'message': 'Google account not connected — changes are kept on this phone.'};
    if (_config['spreadsheetId'] == null) return {'message': 'Choose a spreadsheet first.'};
    if (!await isOnline()) {
      await _setState({'lastError': 'Offline — changes are saved on this phone and will sync when internet returns.'});
      return {'message': 'Offline. Changes are saved on this phone and will sync later.'};
    }
    await _setState({'lastRunAt': DateTime.now().toUtc().toIso8601String()});
    var retriedAuth = false;
    while (true) {
      try {
        final r = await _run();
        _notify(r);
        return r;
      } on AuthFailure catch (e) {
        await _setState({'state': e.code == 'NOT_CONFIGURED' ? 'not_configured' : 'auth_error', 'lastError': e.message});
        await _log('sync', result: 'error', message: e.message);
        _notify({'event': 'failed', 'message': e.message});
        return {'message': e.message};
      } on ApiError catch (e) {
        if (e.isAuth && !retriedAuth) {
          retriedAuth = true;
          if (_token != null) await auth.clearToken(_token!);
          _token = null;
          continue; // one fresh token, then try again
        }
        final state = e.isAuth
            ? 'auth_error'
            : e.isNotFound
                ? 'spreadsheet_missing'
                : e.isPermission
                    ? 'permission_error'
                    : 'error';
        final msg = switch (state) {
          'auth_error' => 'Google sign-in expired or was revoked. Tap Connect Google Account.',
          'spreadsheet_missing' => 'The spreadsheet was deleted or cannot be found. Your data is safe on this phone; choose or create a spreadsheet.',
          'permission_error' => 'This Google account no longer has edit access to the spreadsheet. Your data is safe on this phone.',
          _ => e.isNetwork ? 'Network problem — will retry automatically.' : e.toString(),
        };
        await _setState({'state': state, 'lastError': msg});
        await _log('sync', result: 'error', message: '$msg (${e.status})');
        _notify({'event': 'failed', 'message': msg});
        return {'message': msg};
      }
    }
  }

  void _notify(Map<String, Object?> s) {
    try {
      onStatus?.call(s);
    } catch (_) {}
  }

  String _hash(List<Object?> row, int width) => sha1.convert(utf8.encode(jsonEncode(normRow(row, width)))).toString();

  Future<Map<String, dynamic>> _run() async {
    final sid = _config['spreadsheetId'] as String;
    final api = _api();
    await _log('sync_started');

    // 1. spreadsheet exists & tabs/headers are right
    final ss = await api.getSpreadsheet(sid);
    final titles = ((ss['sheets'] as List?) ?? const [])
        .map((s) => ((s as Map)['properties'] as Map)['title'].toString())
        .toSet();
    final allTabs = [...kTabs.map((t) => MapEntry(t.title, t.headers)), const MapEntry(kSyncLogTab, kSyncLogHeaders)];
    final missing = allTabs.where((t) => !titles.contains(t.key)).map((t) => t.key).toList();
    if (missing.isNotEmpty) {
      await api.addSheets(sid, missing);
      await _log('tabs_created', result: 'ok', message: missing.join(', '));
    }
    final heads = await api.batchGet(sid, [for (final t in allTabs) '${quoteTab(t.key)}!1:1']);
    final headerWrites = <MapEntry<String, List<Object?>>>[];
    final badSchema = <String>{};
    for (var i = 0; i < allTabs.length; i++) {
      final t = allTabs[i];
      final got = heads[i].isEmpty ? const <Object?>[] : heads[i].first;
      if (got.every((c) => normCell(c).isEmpty)) {
        headerWrites.add(MapEntry('${quoteTab(t.key)}!A1', List<Object?>.from(t.value)));
      } else if (normRow(got, t.value.length).join('\u0001') != t.value.join('\u0001')) {
        badSchema.add(t.key);
      }
    }
    if (headerWrites.isNotEmpty) await api.batchUpdate(sid, headerWrites);
    for (final b in badSchema) {
      await _log('schema_error', result: 'error', message: 'Columns in tab "$b" were changed; that tab is not updated until the header row is restored');
    }

    // 2. pending operations
    final now = DateTime.now().millisecondsSinceEpoch;
    final ops = await repo.db.query('sync_queue',
        where: "(status != 'conflict' OR force = 1) AND next_attempt_at <= ?",
        whereArgs: [now], orderBy: 'local_modified', limit: 2000);
    var done = 0, failed = 0, conflicts = 0;
    final logRows = <List<Object?>>[];
    final rb = RowBuilder(repo.db);

    for (final tab in kTabs) {
      final tops = ops.where((o) => o['entity'] == tab.entity).toList();
      if (tops.isEmpty) continue;
      if (badSchema.contains(tab.title)) {
        await _markFailed(tops, 'Columns in tab "${tab.title}" were changed in the spreadsheet', null);
        failed += tops.length;
        continue;
      }
      final width = tab.headers.length;
      final lastCol = colLetter(width);
      // re-read the ID column every run (row numbers are never stored)
      final idCol = (await api.batchGet(sid, ['${quoteTab(tab.title)}!A2:A'])).first;
      final idRow = <String, int>{};
      for (var i = 0; i < idCol.length; i++) {
        final v = idCol[i].isEmpty ? '' : normCell(idCol[i].first);
        if (v.isNotEmpty) idRow.putIfAbsent(v, () => i + 2);
      }
      final updates = <MapEntry<String, List<Object?>>>[];
      final appends = <List<Object?>>[];
      final doneOps = <_Done>[];
      final needRemote = <_Pending>[];
      final nowIso = DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
      final delCol = colLetter(tab.deletedCol + 1), delAtCol = colLetter(tab.deletedCol + 2);

      for (final op in tops) {
        final id = op['record_id'] as String;
        List<Object?>? row;
        if (op['op'] == 'upsert') row = await rb.build(tab.entity, id);
        if (row == null) {
          // deleted locally: mark the sheet row as deleted (never remove rows)
          final r = idRow[id];
          if (r != null) updates.add(MapEntry('${quoteTab(tab.title)}!$delCol$r:$delAtCol$r', [true, nowIso]));
          doneOps.add(_Done(op, null));
          continue;
        }
        final h = _hash(row, width);
        final r = idRow[id];
        if (r == null) {
          appends.add(row);
          idRow[id] = -1;
          doneOps.add(_Done(op, h));
        } else if (r == -1) {
          doneOps.add(_Done(op, h)); // same record twice in one batch (should not happen)
        } else {
          needRemote.add(_Pending(op, row, h, r));
        }
      }

      if (needRemote.isNotEmpty) {
        final remote = await api.batchGet(sid, [for (final p in needRemote) '${quoteTab(tab.title)}!A${p.row}:$lastCol${p.row}']);
        final last = <String, String?>{};
        for (final rs in await repo.db.query('record_sync', where: 'entity = ?', whereArgs: [tab.entity])) {
          last[rs['record_id'] as String] = rs['last_pushed_hash'] as String?;
        }
        for (var i = 0; i < needRemote.length; i++) {
          final p = needRemote[i];
          final remoteRow = remote[i].isEmpty ? const <Object?>[] : remote[i].first;
          final remoteHash = _hash(remoteRow, width);
          final id = p.op['record_id'] as String;
          final lastHash = last[id];
          final forced = p.op['force'] == 1;
          if (remoteHash == p.hash) {
            doneOps.add(_Done(p.op, p.hash)); // already identical
          } else if (lastHash != null && remoteHash != lastHash && !forced) {
            if (tab.financial) {
              await repo.db.update('sync_queue', {
                'status': 'conflict', 'remote_hash': remoteHash,
                'last_error': 'Row was edited in the spreadsheet after the app last wrote it',
              }, where: 'entity = ? AND record_id = ?', whereArgs: [tab.entity, id]);
              conflicts++;
              await _log('conflict', entity: tab.entity, recordId: id, result: 'conflict',
                  message: 'Edited in sheet; not overwritten (financial record)');
              logRows.add([nowIso, deviceName, 'conflict', tab.title, id, 'conflict', 'Edited in sheet; kept until resolved']);
            } else {
              updates.add(MapEntry('${quoteTab(tab.title)}!A${p.row}', p.values));
              doneOps.add(_Done(p.op, p.hash));
              await _log('conflict_overwritten', entity: tab.entity, recordId: id, result: 'ok',
                  message: 'Sheet edit replaced by phone data (phone is the source of truth)');
              logRows.add([nowIso, deviceName, 'conflict', tab.title, id, 'phone version kept', 'Sheet edit replaced']);
            }
          } else {
            updates.add(MapEntry('${quoteTab(tab.title)}!A${p.row}', p.values));
            doneOps.add(_Done(p.op, p.hash));
          }
        }
      }

      try {
        if (updates.isNotEmpty) {
          final n = await api.batchUpdate(sid, updates);
          if (n < updates.length) throw ApiError(500, 'Google confirmed only $n of ${updates.length} row updates');
        }
        if (appends.isNotEmpty) {
          final n = await api.append(sid, tab.title, appends);
          if (n != appends.length) throw ApiError(500, 'Google confirmed $n of ${appends.length} new rows');
        }
        await _markDone(tab.entity, doneOps);
        done += doneOps.length;
      } on ApiError catch (e) {
        if (e.isAuth || e.isNotFound || e.isPermission) rethrow;
        final pendingOps = doneOps.map((d) => d.op).toList();
        await _markFailed(pendingOps, e.toString(), e.retryAfter);
        failed += pendingOps.length;
        await _log('write_failed', entity: tab.entity, result: 'failed', message: e.toString());
        logRows.add([nowIso, deviceName, 'write failed', tab.title, '', 'will retry', _sanitize(e.toString())]);
        if (e.isRateLimit) break; // stop hammering; back off
      }
    }

    final summary = '$done synced, $failed failed, $conflicts conflicts';
    logRows.insert(0, [
      DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' '),
      deviceName, 'sync', '', '', failed == 0 && conflicts == 0 ? 'ok' : 'partial', summary
    ]);
    if (done > 0 || failed > 0 || conflicts > 0) {
      try {
        if (!badSchema.contains(kSyncLogTab)) await api.append(sid, kSyncLogTab, logRows.take(25).toList());
      } catch (_) {/* the app keeps working if the Sync Log tab is unavailable */}
    }
    await _log('sync_finished', result: failed == 0 && conflicts == 0 ? 'ok' : 'partial', message: summary);
    final remaining = (await repo.db.rawQuery("SELECT COUNT(*) AS n FROM sync_queue WHERE status = 'pending'")).first['n'] as int? ?? 0;
    if (failed == 0 && conflicts == 0 && badSchema.isEmpty) {
      await _setState({'state': 'ok', 'lastSuccessAt': DateTime.now().toUtc().toIso8601String(), 'lastError': null});
    } else {
      await _setState({
        'state': 'error',
        'lastError': badSchema.isNotEmpty
            ? 'Columns were changed in tab(s): ${badSchema.join(', ')}. Restore the header row (see Sync log).'
            : conflicts > 0
                ? '$conflicts record(s) were edited in the spreadsheet — tap Resolve conflicts.'
                : '$failed change(s) could not be written; they will be retried.',
      });
    }
    return {
      'event': failed == 0 && conflicts == 0 ? 'synced' : 'failed',
      'count': done,
      'failed': failed,
      'conflicts': conflicts,
      'remaining': remaining,
      'message': done == 0 && failed == 0 && conflicts == 0 ? 'Everything is already up to date.' : 'Sync finished: $summary.',
    };
  }

  Future<void> _markDone(String entity, List<_Done> list) async {
    final at = DateTime.now().toUtc().toIso8601String();
    await repo.db.transaction((txn) async {
      for (final d in list) {
        final id = d.op['record_id'] as String;
        // only remove the queue entry if the record did not change again meanwhile
        await txn.delete('sync_queue',
            where: 'entity = ? AND record_id = ? AND op_id = ?', whereArgs: [entity, id, d.op['op_id']]);
        if (d.hash == null) {
          await txn.delete('record_sync', where: 'entity = ? AND record_id = ?', whereArgs: [entity, id]);
        } else {
          await txn.rawInsert('''INSERT INTO record_sync(entity, record_id, last_pushed_hash, last_synced_at) VALUES(?,?,?,?)
            ON CONFLICT(entity, record_id) DO UPDATE SET last_pushed_hash = excluded.last_pushed_hash, last_synced_at = excluded.last_synced_at''',
              [entity, id, d.hash, at]);
        }
      }
    });
  }

  /// Bounded exponential backoff with jitter (30 s, 1 min, 2 min … max 6 h).
  Duration backoff(int attempts, [Duration? retryAfter]) {
    final base = 30 * pow(2, max(0, attempts - 1)).toInt();
    final capped = min(base, 6 * 3600);
    final jitter = (capped * (0.8 + _rand.nextDouble() * 0.4)).round();
    final d = Duration(seconds: jitter);
    return retryAfter != null && retryAfter > d ? retryAfter : d;
  }

  Future<void> _markFailed(List<Map<String, Object?>> ops, String error, Duration? retryAfter) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.db.transaction((txn) async {
      for (final op in ops) {
        final attempts = ((op['attempts'] as int?) ?? 0) + 1;
        await txn.update('sync_queue', {
          'status': 'failed',
          'attempts': attempts,
          'next_attempt_at': now + backoff(attempts, retryAfter).inMilliseconds,
          'last_error': _sanitize(error),
        }, where: 'entity = ? AND record_id = ? AND op_id = ?', whereArgs: [op['entity'], op['record_id'], op['op_id']]);
      }
    });
  }

  Future<Map<String, Object?>> retryFailed() async {
    await repo.db.rawUpdate("UPDATE sync_queue SET next_attempt_at = 0, status = 'pending' WHERE status = 'failed'");
    final r = await syncNow();
    return {'message': r['message']};
  }

  Future<List<Map<String, Object?>>> conflicts() async {
    final rows = await repo.db.query('sync_queue', where: "status = 'conflict'");
    final out = <Map<String, Object?>>[];
    for (final r in rows) {
      String? label;
      final e = r['entity'], id = r['record_id'];
      if (e == 'documents') {
        label = (await repo.db.query('documents', columns: ['no'], where: 'id = ?', whereArgs: [id])).firstOrNull?['no'] as String?;
      } else if (e == 'payments') {
        final p = await repo.db.rawQuery(
            'SELECT d.no, p.amount FROM payments p JOIN documents d ON d.id = p.document_id WHERE p.id = ?', [id]);
        if (p.isNotEmpty) label = 'Payment ${p.first['amount']} on ${p.first['no']}';
      } else if (e == 'document_items') {
        final p = await repo.db.rawQuery(
            'SELECT d.no, i.description FROM document_items i JOIN documents d ON d.id = i.document_id WHERE i.id = ?', [id]);
        if (p.isNotEmpty) label = '${p.first['no']}: ${p.first['description']}';
      }
      out.add({'entity': kTabByEntity[e]?.title ?? e, 'recordId': id, 'label': label ?? id, 'message': r['last_error']});
    }
    return out;
  }

  /// useDevice: overwrite the sheet rows with phone data.
  /// keepSheet: accept the sheet rows as they are (the next phone edit will overwrite).
  Future<Map<String, Object?>> resolveConflicts(String mode) async {
    final rows = await repo.db.query('sync_queue', where: "status = 'conflict'");
    if (mode == 'useDevice') {
      await repo.db.rawUpdate("UPDATE sync_queue SET force = 1, next_attempt_at = 0 WHERE status = 'conflict'");
      await _log('conflicts_resolved', result: 'ok', message: '${rows.length} set to use phone data');
      final r = await syncNow();
      return {'message': r['message']};
    }
    final at = DateTime.now().toUtc().toIso8601String();
    await repo.db.transaction((txn) async {
      for (final r in rows) {
        await txn.rawInsert('''INSERT INTO record_sync(entity, record_id, last_pushed_hash, last_synced_at) VALUES(?,?,?,?)
          ON CONFLICT(entity, record_id) DO UPDATE SET last_pushed_hash = excluded.last_pushed_hash, last_synced_at = excluded.last_synced_at''',
            [r['entity'], r['record_id'], r['remote_hash'], at]);
        await txn.delete('sync_queue', where: 'entity = ? AND record_id = ?', whereArgs: [r['entity'], r['record_id']]);
      }
    });
    await _log('conflicts_resolved', result: 'ok', message: '${rows.length} kept as in the spreadsheet');
    return {'message': 'Kept the spreadsheet rows as they are.'};
  }

  Future<List<Map<String, Object?>>> log({int limit = 150}) async {
    final rows = await repo.db.query('sync_log', orderBy: 'id DESC', limit: limit);
    return rows
        .map((r) => {'at': r['at'], 'event': r['event'], 'entity': r['entity'], 'recordId': r['record_id'], 'result': r['result'], 'message': r['message']})
        .toList();
  }

  /// Token for Drive backups (same Google account).
  Future<GoogleApi> driveApi({bool interactive = false}) async {
    _requireAccount();
    _token ??= await auth.accessToken(interactive: interactive);
    return _api();
  }

  Future<T> withAuthRetry<T>(Future<T> Function(GoogleApi api) f) => _guard(() async => f(await driveApi()));
}

class _Done {
  final Map<String, Object?> op;
  final String? hash;
  _Done(this.op, this.hash);
}

class _Pending {
  final Map<String, Object?> op;
  final List<Object?> values;
  final String hash;
  final int row;
  _Pending(this.op, this.values, this.hash, this.row);
}

// Used by tests and the bridge.
typedef Db = Database;
