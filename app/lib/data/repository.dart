import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'money.dart';
import 'schema.dart';
import 'store_defs.dart';

const _uuid = Uuid();

/// A write operation coming from the UI: put / del / clear on a store.
class StoreOp {
  final String type; // put | del | clear
  final String store;
  final Map<String, dynamic>? value;
  final String? id;
  StoreOp.put(this.store, Map<String, dynamic> v)
      : type = 'put',
        value = v,
        id = v['id'] as String?;
  StoreOp.del(this.store, this.id)
      : type = 'del',
        value = null;
  StoreOp.clear(this.store)
      : type = 'clear',
        value = null,
        id = null;

  factory StoreOp.fromJson(Map m) {
    final t = m['t'], s = m['s'];
    if (s is! String || !kStoreByName.containsKey(s)) throw DataError('Unknown data store: $s');
    switch (t) {
      case 'put':
        final v = m['v'];
        if (v is! Map) throw DataError('$s: record missing');
        return StoreOp.put(s, Map<String, dynamic>.from(v));
      case 'del':
        return StoreOp.del(s, m['id']?.toString());
      case 'clear':
        return StoreOp.clear(s);
    }
    throw DataError('Unknown operation: $t');
  }
}

/// All local business data access. SQLite is the source of truth.
class Repository {
  final Database db;
  Repository(this.db);

  bool _quiet = false; // no per-record audit rows while restoring

  /// Set by the sync service: true once a spreadsheet is configured.
  bool Function() syncConfigured = () => false;

  // ---------------------------------------------------------------- reads
  Future<List<Map<String, dynamic>>> getAll(String store, {DatabaseExecutor? ex}) async {
    final e = ex ?? db;
    final def = kStoreByName[store] ?? (throw DataError('Unknown data store: $store'));
    if (def.wholeJson) {
      final rows = await e.query(def.table, orderBy: 'id');
      return rows.map((r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String) as Map)).toList();
    }
    final rows = await e.query(def.table, orderBy: 'rowid');
    final out = rows.map((r) => decodeRow(def.cols, r)).toList();
    if (def.children.isNotEmpty && out.isNotEmpty) {
      for (final child in def.children) {
        final crow = await e.query(child.table, orderBy: '${child.parentColumn}, ${_childOrder(child)}');
        final byParent = <String, List<Map<String, dynamic>>>{};
        for (final r in crow) {
          byParent.putIfAbsent(r[child.parentColumn] as String, () => []).add(decodeRow(child.cols, r));
        }
        for (final rec in out) {
          rec[child.key] = byParent[rec['id']] ?? <Map<String, dynamic>>[];
        }
      }
    }
    return out;
  }

  String _childOrder(ChildDef c) => c.cols.any((x) => x.column == 'line_no') ? 'line_no, rowid' : 'rowid';

  Future<Map<String, dynamic>?> get(String store, String id, {DatabaseExecutor? ex}) async {
    final e = ex ?? db;
    final def = kStoreByName[store] ?? (throw DataError('Unknown data store: $store'));
    final rows = await e.query(def.table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    if (def.wholeJson) return Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String) as Map);
    final rec = decodeRow(def.cols, rows.first);
    for (final child in def.children) {
      final crow = await e.query(child.table,
          where: '${child.parentColumn} = ?', whereArgs: [id], orderBy: _childOrder(child));
      rec[child.key] = crow.map((r) => decodeRow(child.cols, r)).toList();
    }
    return rec;
  }

  // --------------------------------------------------------------- writes
  /// Applies all [ops] in ONE transaction. Either everything is saved or nothing.
  /// Returns info for the UI ("saved on this device · sync pending").
  Future<Map<String, Object?>> applyBatch(List<StoreOp> ops) async {
    var queued = 0;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final op in ops) {
        switch (op.type) {
          case 'put':
            queued += await _put(txn, op.store, op.value!, now);
          case 'del':
            if (op.id != null) queued += await _delete(txn, op.store, op.id!, now);
          case 'clear':
            final def = kStoreByName[op.store]!;
            final ids = await txn.query(def.table, columns: ['id']);
            for (final r in ids) {
              queued += await _delete(txn, op.store, r['id'] as String, now);
            }
        }
      }
    });
    return {'ok': true, 'queued': queued, 'syncConfigured': syncConfigured()};
  }

  Future<int> _put(Transaction txn, String store, Map<String, dynamic> rec, int now) async {
    final def = kStoreByName[store]!;
    final ctx = '$store ${rec['no'] ?? rec['name'] ?? rec['id'] ?? ''}'.trim();
    final id = rec['id'];
    if (id is! String || id.isEmpty) throw DataError('$ctx: record has no ID');

    if (def.wholeJson) {
      await _upsert(txn, def.table, id, {'id': id, 'data': jsonEncode(rec), 'updated_at': now});
      return 0;
    }

    // normalise: children must be lists; give children stable IDs
    final childKeys = def.children.map((c) => c.key).toSet();
    for (final child in def.children) {
      final list = rec[child.key];
      if (list != null && list is! List) throw DataError('$ctx: ${child.key} must be a list');
      final items = <Map<String, dynamic>>[];
      var line = 0;
      for (final it in (list as List? ?? const [])) {
        if (it is! Map) throw DataError('$ctx: invalid ${child.key} entry');
        final m = Map<String, dynamic>.from(it);
        if (m['id'] is! String || (m['id'] as String).isEmpty) m['id'] = _uuid.v4();
        if (child.cols.any((c) => c.key == 'line') && m['line'] == null) m['line'] = ++line;
        items.add(m);
      }
      rec[child.key] = items;
    }

    final row = encodeRow(def.cols, rec, skipKeys: childKeys, ctx: ctx, table: def.table)
      ..addAll(computedColumns(def, rec));
    final old = await txn.query(def.table, where: 'id = ?', whereArgs: [id], limit: 1);
    final oldRow = old.isEmpty ? null : old.first;
    var changed = oldRow == null || !_sameRow(oldRow, row);
    if (changed) await _upsert(txn, def.table, id, row, exists: oldRow != null);

    var queued = 0;
    // children: upsert changed, delete removed (with sync + audit)
    for (final child in def.children) {
      final existing = await txn.query(child.table, where: '${child.parentColumn} = ?', whereArgs: [id]);
      final byId = {for (final r in existing) r['id'] as String: r};
      final keep = <String>{};
      for (final it in (rec[child.key] as List).cast<Map<String, dynamic>>()) {
        final cid = it['id'] as String;
        if (keep.contains(cid)) throw DataError('$ctx: duplicate ${child.key} ID $cid');
        keep.add(cid);
        final crow = encodeRow(child.cols, it, ctx: '$ctx ${child.key}', table: child.table)
          ..[child.parentColumn] = id
          ..addAll(computedChildColumns(child, it));
        final prev = byId[cid];
        if (prev != null && prev[child.parentColumn] != id) {
          throw DataError('$ctx: ${child.key} ID $cid already belongs to another record');
        }
        if (prev == null) {
          // an ID used by another parent would violate the primary key
          final clash = await txn.query(child.table, columns: ['id'], where: 'id = ?', whereArgs: [cid], limit: 1);
          if (clash.isNotEmpty) throw DataError('$ctx: ${child.key} ID $cid already belongs to another record');
        }
        if (prev == null || !_sameRow(prev, crow)) {
          await _upsert(txn, child.table, cid, crow, exists: prev != null);
          changed = true;
          if (child.entity.isNotEmpty) {
            await _enqueue(txn, child.entity, cid, 'upsert', now);
            queued++;
          }
          if (child.table == 'payments' || child.table == 'purchase_payments') {
            await _audit(txn, child.table, cid, prev == null ? 'payment_added' : 'payment_changed',
                {'parent': id, 'no': rec['no'], 'amount': it['amount'], if (prev != null) 'previous': prev['amount']});
          }
        }
      }
      for (final r in existing) {
        final cid = r['id'] as String;
        if (keep.contains(cid)) continue;
        await txn.delete(child.table, where: 'id = ?', whereArgs: [cid]);
        changed = true;
        if (child.entity.isNotEmpty) {
          await _enqueue(txn, child.entity, cid, 'delete', now);
          queued++;
        }
        if (child.table == 'payments' || child.table == 'purchase_payments') {
          await _audit(txn, child.table, cid, 'payment_removed', {'parent': id, 'no': rec['no'], 'amount': r['amount']});
        }
      }
    }

    if (changed) {
      if (def.entity.isNotEmpty) {
        await _enqueue(txn, def.entity, id, 'upsert', now);
        queued++;
      }
      if (store == 'documents' && oldRow == null) {
        await _audit(txn, store, id, 'created', {'no': rec['no'], 'type': rec['type'], 'grand': row['grand_total']});
      } else if (store == 'documents' && oldRow != null && oldRow['grand_total'] != row['grand_total']) {
        await _audit(txn, store, id, 'total_changed', {'no': rec['no'], 'from': oldRow['grand_total'], 'to': row['grand_total']});
      }
      if (store == 'products' && oldRow != null && oldRow['price'] != row['price']) {
        await _audit(txn, store, id, 'rate_changed', {'name': rec['name'], 'from': oldRow['price'], 'to': row['price']});
      }
    }
    return queued;
  }

  Future<int> _delete(Transaction txn, String store, String id, int now) async {
    final def = kStoreByName[store]!;
    final old = await get(store, id, ex: txn);
    if (old == null) return 0;
    var queued = 0;
    for (final child in def.children) {
      final kids = await txn.query(child.table, columns: ['id'], where: '${child.parentColumn} = ?', whereArgs: [id]);
      if (child.entity.isNotEmpty) {
        for (final k in kids) {
          await _enqueue(txn, child.entity, k['id'] as String, 'delete', now);
          queued++;
        }
      }
      await txn.delete(child.table, where: '${child.parentColumn} = ?', whereArgs: [id]);
    }
    await txn.delete(def.table, where: 'id = ?', whereArgs: [id]);
    if (def.entity.isNotEmpty) {
      await _enqueue(txn, def.entity, id, 'delete', now);
      queued++;
    }
    if (store == 'documents' || store == 'purchases') {
      final t = store == 'documents' ? docTotals(old) : purchTotals(old);
      await _audit(txn, store, id, 'deleted', {'no': old['no'], 'grand': t.grand, 'paid': t.paid, 'payments': old['payments']});
    } else if (store == 'expenses' || store == 'fixedexpenses' || store == 'products' || store == 'customers') {
      await _audit(txn, store, id, 'deleted', {'name': old['name'] ?? old['category'], 'amount': old['amount'] ?? old['price']});
    }
    return queued;
  }

  Future<void> _upsert(DatabaseExecutor e, String table, String id, Map<String, Object?> row, {bool? exists}) async {
    final has = exists ?? (await e.query(table, columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1)).isNotEmpty;
    if (has) {
      await e.update(table, row, where: 'id = ?', whereArgs: [id]);
    } else {
      await e.insert(table, row);
    }
  }

  bool _sameRow(Map<String, Object?> oldRow, Map<String, Object?> newRow) {
    for (final k in newRow.keys) {
      final a = oldRow[k], b = newRow[k];
      if (a is num && b is num) {
        if (a.toDouble() != b.toDouble()) return false;
      } else if (a != b) {
        return false;
      }
    }
    return true;
  }

  // ------------------------------------------------------- sync queue
  /// One pending operation per record; a newer change replaces the older one.
  Future<void> _enqueue(DatabaseExecutor e, String entity, String recordId, String op, int now) async {
    await e.rawInsert('''INSERT INTO sync_queue(entity, record_id, op_id, op, local_modified, status, attempts, next_attempt_at, created_at)
      VALUES(?, ?, ?, ?, ?, 'pending', 0, 0, ?)
      ON CONFLICT(entity, record_id) DO UPDATE SET
        op_id = excluded.op_id, op = excluded.op, local_modified = excluded.local_modified,
        status = 'pending', attempts = 0, next_attempt_at = 0, last_error = NULL, remote_hash = NULL''',
        [entity, recordId, _uuid.v4(), op, now, now]);
  }

  Future<void> enqueueAll(DatabaseExecutor e) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final def in kStores) {
      if (def.entity.isNotEmpty) {
        for (final r in await e.query(def.table, columns: ['id'])) {
          await _enqueue(e, def.entity, r['id'] as String, 'upsert', now);
        }
      }
      for (final c in def.children) {
        if (c.entity.isEmpty) continue;
        for (final r in await e.query(c.table, columns: ['id'])) {
          await _enqueue(e, c.entity, r['id'] as String, 'upsert', now);
        }
      }
    }
  }

  Future<void> _audit(DatabaseExecutor e, String entity, String? id, String action, Map<String, Object?> summary) async {
    if (_quiet && entity != 'database') return;
    await e.insert('audit_log', {
      'at': DateTime.now().toIso8601String(),
      'entity': entity,
      'record_id': id,
      'action': action,
      'summary': jsonEncode(summary),
    });
  }

  // ------------------------------------------------- whole dataset (backup)
  /// A consistent snapshot of every store (read inside one transaction).
  Future<Map<String, List<Map<String, dynamic>>>> exportData() async {
    final out = <String, List<Map<String, dynamic>>>{};
    await db.transaction((txn) async {
      for (final s in kStoreNames) {
        out[s] = await getAll(s, ex: txn);
      }
    });
    return out;
  }

  /// Replace ALL business data with [data] (already validated). Runs in the
  /// caller's transaction so a failure leaves the previous data untouched.
  Future<void> replaceAllIn(Transaction txn, Map<String, List<Map<String, dynamic>>> data) async {
    for (final t in kBusinessTables.reversed) {
      await txn.delete(t);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _quiet = true;
    try {
      for (final s in kStoreNames) {
        for (final rec in data[s] ?? const <Map<String, dynamic>>[]) {
          await _put(txn, s, Map<String, dynamic>.from(rec), now);
        }
      }
    } finally {
      _quiet = false;
    }
    // sync metadata from before the restore no longer describes this data:
    // everything is uploaded again and matched by ID (never marked synced falsely)
    await txn.delete('sync_queue');
    await txn.delete('record_sync');
    await enqueueAll(txn);
    await _audit(txn, 'database', null, 'restored', {
      for (final s in kStoreNames) s: (data[s] ?? const []).length,
    });
  }

  Future<void> wipe() async {
    await db.transaction((txn) async {
      final data = <String, List<Map<String, dynamic>>>{};
      await replaceAllIn(txn, data);
      await _audit(txn, 'database', null, 'erased', {});
    });
  }

  Future<Map<String, int>> counts({DatabaseExecutor? ex}) async {
    final e = ex ?? db;
    final out = <String, int>{};
    for (final def in kStores) {
      final r = await e.rawQuery('SELECT COUNT(*) AS n FROM ${def.table}');
      out[def.store] = (r.first['n'] as int?) ?? 0;
    }
    return out;
  }

  // ------------------------------------------------------------- kv store
  Future<String?> kvGet(String key, {DatabaseExecutor? ex}) async {
    final r = await (ex ?? db).query('kv', where: 'key = ?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> kvSet(String key, String? value, {DatabaseExecutor? ex}) async {
    final e = ex ?? db;
    if (value == null) {
      await e.delete('kv', where: 'key = ?', whereArgs: [key]);
    } else {
      await e.rawInsert('INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
    }
  }

  Future<Map<String, dynamic>> kvJson(String key) async {
    final s = await kvGet(key);
    if (s == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> kvSetJson(String key, Map<String, dynamic> value) => kvSet(key, jsonEncode(value));
}
