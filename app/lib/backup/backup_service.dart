// Complete, restorable backups (independent of Google Sheets / Drive).
//
// File format v3 (same as the desktop app writes):
// {
//   "format": "pehlwania-pos-backup", "formatVersion": 3, "app": "PehlwaniaDoorMaxPOS",
//   "appVersion": "...", "source": "android", "createdAt": ISO-8601, "schemaVersion": N,
//   "counts": {store: n}, "totals": {"invoiceGrand": x, "payments": y},
//   "payloadSha256": "<hex>", "payload": "<exact JSON text of {store: [records]}>"
// }
// The original desktop app's v2 files ({_app, _version:2, store: [...]}) are accepted too.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../data/money.dart';
import '../data/repository.dart';
import '../data/schema.dart';
import '../data/store_defs.dart';

const kBackupFormat = 'pehlwania-pos-backup';
const kBackupVersion = 3;
const kAppVersion = '3.0.0';

class BackupValidation {
  final bool ok;
  final List<String> errors;
  final List<String> warnings;
  final String format;
  final String createdAt;
  final Map<String, int> counts;
  final Map<String, List<Map<String, dynamic>>>? data;
  BackupValidation(this.ok, this.errors, this.warnings, this.format, this.createdAt, this.counts, this.data);

  Map<String, Object?> toJson() => {
        'ok': ok, 'errors': errors, 'warnings': warnings, 'format': format,
        'createdAt': createdAt, 'counts': counts,
      };
}

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

bool _isNum(Object? v) {
  if (v == null || v == '') return true;
  if (v is num) return v.isFinite;
  if (v is bool) return true;
  return double.tryParse(v.toString().trim()) != null;
}

/// Validates a backup file's text. Never touches the database.
BackupValidation validateBackupText(String text) {
  final errors = <String>[], warnings = <String>[];
  Object? obj;
  try {
    obj = jsonDecode(text);
  } catch (e) {
    return BackupValidation(false, ['The file is not valid JSON (damaged or not a backup).'], [], '', '', {}, null);
  }
  if (obj is! Map) {
    return BackupValidation(false, ['Not a backup file (not a JSON object).'], [], '', '', {}, null);
  }
  var format = '', createdAt = '';
  Map data;
  if (obj['format'] == kBackupFormat) {
    final v = obj['formatVersion'];
    format = 'v$v';
    createdAt = (obj['createdAt'] ?? '').toString();
    if (v is! num || v < 3) return BackupValidation(false, ['Unknown backup version.'], [], format, createdAt, {}, null);
    if (v > kBackupVersion) {
      return BackupValidation(false,
          ['This backup was made by a newer app version (format $v). Please update the app first.'], [], format, createdAt, {}, null);
    }
    final payload = obj['payload'];
    if (payload is! String) return BackupValidation(false, ['Backup payload is missing.'], [], format, createdAt, {}, null);
    if (sha256Hex(payload) != obj['payloadSha256']) {
      return BackupValidation(false,
          ['Checksum mismatch — the file is damaged or was edited. It will not be restored.'], [], format, createdAt, {}, null);
    }
    try {
      final p = jsonDecode(payload);
      if (p is! Map) throw const FormatException();
      data = p;
    } catch (_) {
      return BackupValidation(false, ['Backup payload is not valid JSON.'], [], format, createdAt, {}, null);
    }
  } else if (obj['_app'] == 'PehlwaniaDoorMaxPOS') {
    format = 'v${obj['_version'] ?? 1} (original desktop app)';
    createdAt = (obj['exportedAt'] ?? '').toString();
    data = {for (final s in kStoreNames) if (obj.containsKey(s)) s: obj[s]};
    warnings.add('Older backup format without a checksum — it is checked record by record instead.');
  } else {
    return BackupValidation(false, ['This file is not a Pehlwania POS backup.'], [], '', '', {}, null);
  }

  final counts = <String, int>{};
  final ids = <String, Set<String>>{};
  final clean = <String, List<Map<String, dynamic>>>{};
  for (final s in kStoreNames) {
    final rows = data[s] ?? const [];
    if (rows is! List) {
      errors.add('"$s" is not a list.');
      continue;
    }
    final seen = <String>{};
    final list = <Map<String, dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r is! Map) {
        errors.add('$s #${i + 1} is not a record.');
        continue;
      }
      final id = r['id'];
      if (id is! String || id.trim().isEmpty) {
        errors.add('$s #${i + 1} has no ID.');
        continue;
      }
      if (seen.contains(id)) errors.add('$s: duplicate ID $id.');
      seen.add(id);
      list.add(Map<String, dynamic>.from(r));
    }
    ids[s] = seen;
    counts[s] = rows.length;
    clean[s] = list;
  }
  if (!(ids['settings']?.contains('app') ?? false)) errors.add('Business settings are missing.');

  final itemIds = <String>{}, payIds = <String>{};
  for (final d in clean['documents'] ?? const <Map<String, dynamic>>[]) {
    final tag = (d['no'] ?? d['id']).toString();
    if (d['type'] != 'invoice' && d['type'] != 'quote') errors.add('$tag: unknown document type.');
    if (d['no'] == null || d['no'] == '') errors.add('Document ${d['id']} has no number.');
    if (d['date'] == null || d['date'] == '') errors.add('$tag: date missing.');
    final items = d['items'];
    if (items is! List) {
      errors.add('$tag: items missing.');
    } else {
      for (final it in items) {
        if (it is! Map) {
          errors.add('$tag: bad item.');
          continue;
        }
        if (!_isNum(it['qty']) || !_isNum(it['rate']) || !_isNum(it['width']) || !_isNum(it['height'])) {
          errors.add('$tag: an item has a non-numeric value.');
        }
        final iid = it['id'];
        if (iid is String && iid.isNotEmpty) {
          if (itemIds.contains(iid)) errors.add('$tag: duplicate item ID $iid.');
          itemIds.add(iid);
        }
      }
    }
    final pays = d['payments'];
    if (pays != null && pays is! List) errors.add('$tag: payments are not a list.');
    for (final p in (pays is List ? pays : const [])) {
      if (p is! Map || !_isNum(p['amount']) || !(numOf(p['amount']) > 0)) errors.add('$tag: invalid payment amount.');
      if (p is Map && p['id'] is String && (p['id'] as String).isNotEmpty) {
        if (payIds.contains(p['id'])) errors.add('$tag: duplicate payment ID ${p['id']}.');
        payIds.add(p['id'] as String);
      }
    }
    if (!_isNum(d['discount']) || !_isNum(d['taxPct'])) errors.add('$tag: invalid discount or tax.');
    final cid = d['customerId'];
    if (cid is String && cid.isNotEmpty && !(ids['customers']?.contains(cid) ?? false)) {
      warnings.add('$tag: linked customer not found (the name on the bill is kept).');
    }
  }
  for (final p in clean['purchases'] ?? const <Map<String, dynamic>>[]) {
    final sid = p['supplierId'];
    if (sid is String && sid.isNotEmpty && !(ids['suppliers']?.contains(sid) ?? false)) {
      warnings.add('${p['no'] ?? p['id']}: supplier not found.');
    }
    for (final x in (p['payments'] is List ? p['payments'] as List : const [])) {
      if (x is! Map || !_isNum(x['amount']) || !(numOf(x['amount']) > 0)) errors.add('${p['no'] ?? p['id']}: invalid supplier payment.');
    }
  }
  for (final e in clean['expenses'] ?? const <Map<String, dynamic>>[]) {
    if (!_isNum(e['amount']) || numOf(e['amount']) < 0) errors.add('Expense ${e['id']}: invalid amount.');
  }
  final users = clean['users'] ?? const <Map<String, dynamic>>[];
  if (!users.any((u) => u['role'] == 'admin' && u['active'] != false)) {
    warnings.add('No active owner login in this backup — the default admin/admin login will be recreated.');
  }
  if (errors.length > 20) {
    final n = errors.length;
    errors
      ..removeRange(20, n)
      ..add('…and ${n - 20} more problems.');
  }
  return BackupValidation(errors.isEmpty, errors, warnings, format, createdAt, counts, clean);
}

class BackupService {
  final Repository repo;
  final Future<Directory> Function() safetyDir;
  BackupService(this.repo, {required this.safetyDir});

  /// Builds the complete backup file text from a consistent snapshot.
  Future<String> buildBackupText({String source = 'android'}) async {
    final data = await repo.exportData();
    final payload = jsonEncode(data);
    return jsonEncode({
      'format': kBackupFormat,
      'formatVersion': kBackupVersion,
      'app': 'PehlwaniaDoorMaxPOS',
      'appVersion': kAppVersion,
      'source': source,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'schemaVersion': kSchemaVersion,
      'counts': {for (final e in data.entries) e.key: e.value.length},
      'totals': datasetTotals(data),
      'payloadSha256': sha256Hex(payload),
      'payload': payload,
    });
  }

  static String fileNameNow([String prefix = 'PehlwaniaPOS-backup']) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix-${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}-${two(t.second)}.json';
  }

  Future<Map<String, dynamic>> status() => repo.kvJson('backup.status');

  Future<void> recordSuccess({required String fileName, String? location, required int sizeBytes, required Map<String, int> counts}) async {
    final st = await status();
    st.addAll({
      'lastSuccessAt': DateTime.now().toUtc().toIso8601String(),
      'fileName': fileName,
      'location': location ?? '',
      'sizeBytes': sizeBytes,
      'format': '$kBackupFormat v$kBackupVersion',
      'records': counts.values.fold<int>(0, (a, b) => a + b),
      'counts': counts,
      'lastResult': 'success',
      'lastError': '',
    });
    await repo.kvSetJson('backup.status', st);
  }

  /// Keeps the previous successful backup details; only the error is updated.
  Future<void> recordFailure(String error) async {
    final st = await status();
    st.addAll({'lastResult': 'failed', 'lastError': error, 'lastAttemptAt': DateTime.now().toUtc().toIso8601String()});
    await repo.kvSetJson('backup.status', st);
  }

  /// Writes a safety backup of the current data inside the app's private folder.
  Future<File> writeSafetyBackup() async {
    final dir = Directory('${(await safetyDir()).path}/safety-backups');
    await dir.create(recursive: true);
    final text = await buildBackupText(source: 'android-safety');
    final v = validateBackupText(text);
    if (!v.ok) throw StateError('Could not create a valid safety backup: ${v.errors.first}');
    final f = File('${dir.path}/${fileNameNow('PehlwaniaPOS-SAFETY-before-restore')}');
    await f.writeAsString(text, flush: true);
    // keep the newest 5
    final all = dir.listSync().whereType<File>().toList()..sort((a, b) => b.path.compareTo(a.path));
    for (final old in all.skip(5)) {
      try {
        old.deleteSync();
      } catch (_) {}
    }
    return f;
  }

  /// Full replace-all restore. Steps: safety backup → one transaction that
  /// replaces everything → verify counts, relationships and money totals.
  /// If verification fails the safety backup is restored automatically.
  Future<Map<String, Object?>> restore(BackupValidation v) async {
    if (!v.ok || v.data == null) throw StateError(v.errors.isEmpty ? 'Backup is not valid' : v.errors.first);
    final data = _prepare(v.data!);
    final expectedCounts = {for (final s in kStoreNames) s: (data[s] ?? const []).length};
    final expectedTotals = datasetTotals(data);

    final safety = await writeSafetyBackup();
    try {
      await repo.db.transaction((txn) => repo.replaceAllIn(txn, data));
      await _verify(expectedCounts, expectedTotals);
    } catch (e) {
      // put the previous data back
      try {
        final sv = validateBackupText(await safety.readAsString());
        final prev = _prepare(sv.data!);
        await repo.db.transaction((txn) => repo.replaceAllIn(txn, prev));
      } catch (e2) {
        throw StateError('Restore failed ($e) and the automatic recovery also failed ($e2). '
            'Your previous data is in the safety backup file: ${safety.path}');
      }
      throw StateError('Restore failed and was undone — your previous data is back. Reason: $e');
    }
    final st = await status();
    st['lastRestoreAt'] = DateTime.now().toUtc().toIso8601String();
    await repo.kvSetJson('backup.status', st);
    return {
      'ok': true,
      'records': expectedCounts.values.fold<int>(0, (a, b) => a + b),
      'counts': expectedCounts,
      'totals': expectedTotals,
      'safetyBackup': safety.uri.pathSegments.last,
    };
  }

  /// Gives older records stable IDs (items/payments from the original app had none).
  Map<String, List<Map<String, dynamic>>> _prepare(Map<String, List<Map<String, dynamic>>> src) {
    const uuid = Uuid();
    final out = <String, List<Map<String, dynamic>>>{};
    for (final s in kStoreNames) {
      out[s] = (src[s] ?? const <Map<String, dynamic>>[]).map((r) {
        final m = jsonDecode(jsonEncode(r)) as Map<String, dynamic>;
        if (s == 'documents' || s == 'purchases') {
          for (final k in ['items', 'payments']) {
            final l = m[k];
            if (l is List) {
              m[k] = l.map((x) {
                final mm = Map<String, dynamic>.from(x as Map);
                if (mm['id'] is! String || (mm['id'] as String).isEmpty) mm['id'] = uuid.v4();
                return mm;
              }).toList();
            } else {
              m[k] = <Map<String, dynamic>>[];
            }
          }
          if (m['customerId'] == '') m.remove('customerId');
        }
        return m;
      }).toList();
    }
    return out;
  }

  Future<void> _verify(Map<String, int> expectedCounts, Map<String, double> expectedTotals) async {
    final counts = await repo.counts();
    for (final e in expectedCounts.entries) {
      if (counts[e.key] != e.value) {
        throw StateError('Verification failed for ${e.key}: expected ${e.value}, found ${counts[e.key]}');
      }
    }
    final fk = await repo.db.rawQuery('PRAGMA foreign_key_check');
    if (fk.isNotEmpty) throw StateError('Verification failed: ${fk.length} broken relationships');
    final now = await repo.exportData();
    final t = datasetTotals(now);
    if ((t['invoiceGrand']! - expectedTotals['invoiceGrand']!).abs() > 0.01 ||
        (t['payments']! - expectedTotals['payments']!).abs() > 0.01) {
      throw StateError('Verification failed: money totals differ after restore '
          '(${t['invoiceGrand']}/${t['payments']} vs ${expectedTotals['invoiceGrand']}/${expectedTotals['payments']})');
    }
  }
}
