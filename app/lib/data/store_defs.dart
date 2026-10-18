// Mapping between the app's records (the JSON objects the shared HTML UI uses,
// called "stores") and the normalized SQLite tables.
//
// Every table keeps the important fields in typed columns. Any other field the UI
// stores (now or in a future version) goes into the `extra` JSON column, so a
// record always round-trips without losing data.
import 'dart:convert';

import 'money.dart';

enum ColType { text, real, integer, boolean, json }

class Col {
  final String key; // field name in the JS record
  final String column; // SQLite column
  final ColType type;
  const Col(this.key, this.column, this.type);
}

class ChildDef {
  final String key; // e.g. 'items'
  final String table;
  final String parentColumn;
  final List<Col> cols;
  final String entity; // sync entity name, or '' when not synced
  const ChildDef(this.key, this.table, this.parentColumn, this.cols, this.entity);
}

class StoreDef {
  final String store;
  final String table;
  final List<Col> cols;
  final List<ChildDef> children;
  final String entity; // sync entity name, or '' when not synced to Sheets
  final bool wholeJson; // settings: the whole record is kept as JSON
  const StoreDef(this.store, this.table, this.cols,
      {this.children = const [], this.entity = '', this.wholeJson = false});
}

const _t = ColType.text, _r = ColType.real, _i = ColType.integer, _b = ColType.boolean, _j = ColType.json;

const itemCols = [
  Col('id', 'id', _t), Col('line', 'line_no', _i), Col('productId', 'product_id', _t),
  Col('desc', 'description', _t), Col('width', 'width', _r), Col('height', 'height', _r),
  Col('mu', 'measure_unit', _t), Col('qty', 'qty', _r), Col('unit', 'unit', _t),
  Col('rate', 'rate', _r), Col('basis', 'basis', _t),
];
const paymentCols = [
  Col('id', 'id', _t), Col('amount', 'amount', _r), Col('date', 'date', _t),
  Col('method', 'method', _t), Col('note', 'note', _t), Col('createdAt', 'created_at', _i),
];
const purchaseItemCols = [
  Col('id', 'id', _t), Col('line', 'line_no', _i), Col('productId', 'product_id', _t),
  Col('desc', 'description', _t), Col('qty', 'qty', _r), Col('rate', 'rate', _r),
  Col('basis', 'basis', _t), Col('unit', 'unit', _t), Col('width', 'width', _r), Col('height', 'height', _r),
];
const purchasePaymentCols = [
  Col('id', 'id', _t), Col('amount', 'amount', _r), Col('date', 'date', _t),
  Col('method', 'method', _t), Col('createdAt', 'created_at', _i),
];

const List<StoreDef> kStores = [
  StoreDef('settings', 'settings', [Col('id', 'id', _t)], wholeJson: true),
  StoreDef('counters', 'counters', [Col('id', 'id', _t), Col('n', 'n', _i)]),
  StoreDef('users', 'users', [
    Col('id', 'id', _t), Col('username', 'username', _t), Col('name', 'name', _t), Col('pass', 'pass', _t),
    Col('role', 'role', _t), Col('active', 'active', _b), Col('perms', 'perms', _j),
    Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ]),
  StoreDef('products', 'products', [
    Col('id', 'id', _t), Col('name', 'name', _t), Col('category', 'category', _t), Col('unit', 'unit', _t),
    Col('price', 'price', _r), Col('stocked', 'stocked', _b), Col('stock', 'stock', _r),
    Col('defaultBasis', 'default_basis', _t), Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ], entity: 'products'),
  StoreDef('customers', 'customers', [
    Col('id', 'id', _t), Col('name', 'name', _t), Col('phone', 'phone', _t), Col('address', 'address', _t),
    Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ], entity: 'customers'),
  StoreDef('suppliers', 'suppliers', [
    Col('id', 'id', _t), Col('name', 'name', _t), Col('phone', 'phone', _t), Col('address', 'address', _t),
    Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ]),
  StoreDef('documents', 'documents', [
    Col('id', 'id', _t), Col('type', 'type', _t), Col('no', 'no', _t), Col('date', 'date', _t),
    Col('customerId', 'customer_id', _t), Col('customerName', 'customer_name', _t),
    Col('customerPhone', 'customer_phone', _t), Col('branchId', 'branch_id', _t),
    Col('discount', 'discount', _r), Col('taxPct', 'tax_pct', _r), Col('note', 'note', _t),
    Col('orderStatus', 'order_status', _t), Col('fromQuote', 'from_quote', _t),
    Col('_stockApplied', 'stock_applied', _b), Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ], children: [
    ChildDef('items', 'document_items', 'document_id', itemCols, 'document_items'),
    ChildDef('payments', 'payments', 'document_id', paymentCols, 'payments'),
  ], entity: 'documents'),
  StoreDef('purchases', 'purchases', [
    Col('id', 'id', _t), Col('no', 'no', _t), Col('date', 'date', _t), Col('branchId', 'branch_id', _t),
    Col('supplierId', 'supplier_id', _t), Col('supplierName', 'supplier_name', _t),
    Col('discount', 'discount', _r), Col('note', 'note', _t), Col('_stockApplied', 'stock_applied', _b),
    Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ], children: [
    ChildDef('items', 'purchase_items', 'purchase_id', purchaseItemCols, ''),
    ChildDef('payments', 'purchase_payments', 'purchase_id', purchasePaymentCols, ''),
  ]),
  StoreDef('expenses', 'expenses', [
    Col('id', 'id', _t), Col('date', 'date', _t), Col('amount', 'amount', _r), Col('category', 'category', _t),
    Col('branchId', 'branch_id', _t), Col('description', 'description', _t),
    Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ], entity: 'expenses'),
  StoreDef('fixedexpenses', 'fixed_expenses', [
    Col('id', 'id', _t), Col('name', 'name', _t), Col('category', 'category', _t), Col('amount', 'amount', _r),
    Col('branchId', 'branch_id', _t), Col('active', 'active', _b), Col('startMonth', 'start_month', _t),
    Col('endMonth', 'end_month', _t), Col('note', 'note', _t),
    Col('createdAt', 'created_at', _i), Col('updatedAt', 'updated_at', _i),
  ], entity: 'fixedexpenses'),
  StoreDef('stockmoves', 'stockmoves', [
    Col('id', 'id', _t), Col('date', 'date', _t), Col('productId', 'product_id', _t), Col('type', 'type', _t),
    Col('qty', 'qty', _r), Col('reason', 'reason', _t), Col('ref', 'ref', _t), Col('createdAt', 'created_at', _i),
  ]),
  StoreDef('gallery', 'gallery', [
    Col('id', 'id', _t), Col('title', 'title', _t), Col('category', 'category', _t), Col('img', 'img', _t),
    Col('seeded', 'seeded', _b), Col('createdAt', 'created_at', _i),
  ]),
];

final Map<String, StoreDef> kStoreByName = {for (final s in kStores) s.store: s};
List<String> get kStoreNames => kStores.map((s) => s.store).toList();

class DataError implements Exception {
  final String message;
  DataError(this.message);
  @override
  String toString() => message;
}

Object? _toColumn(Col c, Object? v, String ctx) {
  if (v == null) return null;
  switch (c.type) {
    case ColType.text:
      if (v is Map || v is List) throw DataError('$ctx: "${c.key}" must be text');
      return v.toString();
    case ColType.real:
    case ColType.integer:
      if (v is String && v.trim().isEmpty) return null;
      double d;
      if (v is num) {
        d = v.toDouble();
      } else if (v is bool) {
        d = v ? 1 : 0;
      } else {
        final p = double.tryParse(v.toString().trim());
        if (p == null) throw DataError('$ctx: "${c.key}" must be a number (got "$v")');
        d = p;
      }
      if (d.isNaN || d.isInfinite) throw DataError('$ctx: "${c.key}" is not a valid number');
      return c.type == ColType.integer ? d.round() : d;
    case ColType.boolean:
      if (v is bool) return v ? 1 : 0;
      if (v is num) return v != 0 ? 1 : 0;
      final s = v.toString().toLowerCase();
      return (s == 'true' || s == '1') ? 1 : 0;
    case ColType.json:
      return jsonEncode(v);
  }
}

Object? _fromColumn(Col c, Object? v) {
  if (v == null) return null;
  switch (c.type) {
    case ColType.boolean:
      return v == 1 || v == true;
    case ColType.json:
      try {
        return jsonDecode(v as String);
      } catch (_) {
        return null;
      }
    case ColType.real:
      if (v is num) {
        // keep whole numbers as ints so the UI shows "5" not "5.0"
        return v == v.roundToDouble() && v.abs() < 9e15 ? v.toInt() : v.toDouble();
      }
      return v;
    default:
      return v;
  }
}

// NOT NULL columns that have a safe default (a missing value means "none").
const Map<String, Object> _columnDefaults = {
  'measure_unit': 'ft', 'line_no': 0, 'qty': 0, 'rate': 0, 'discount': 0,
  'tax_pct': 0, 'price': 0, 'n': 0,
};
// NOT NULL columns that must be provided, per table.
const Map<String, Set<String>> _requiredColumns = {
  'documents': {'type', 'no', 'date'},
  'purchases': {'no', 'date'},
  'expenses': {'date', 'amount'},
  'payments': {'amount'},
  'purchase_payments': {'amount'},
  'customers': {'name'},
  'suppliers': {'name'},
  'products': {'name'},
  'fixed_expenses': {'name'},
  'users': {'username'},
};

/// Encode a JS record into a row for [cols] (plus `extra`).
Map<String, Object?> encodeRow(List<Col> cols, Map rec,
    {Set<String> skipKeys = const {}, required String ctx, required String table}) {
  final req = _requiredColumns[table] ?? const <String>{};
  final id = rec['id'];
  if (id is! String || id.trim().isEmpty) throw DataError('$ctx: record has no ID');
  final row = <String, Object?>{};
  final used = <String>{...skipKeys};
  for (final c in cols) {
    var v = _toColumn(c, rec[c.key], ctx);
    if (v == null && _columnDefaults.containsKey(c.column)) v = _columnDefaults[c.column];
    if (v == null && req.contains(c.column)) {
      throw DataError('$ctx: "${c.key}" is required');
    }
    row[c.column] = v;
    used.add(c.key);
  }
  final extra = <String, Object?>{};
  rec.forEach((k, v) {
    if (!used.contains(k)) extra[k.toString()] = v;
  });
  row['extra'] = extra.isEmpty ? null : jsonEncode(extra);
  return row;
}

Map<String, dynamic> decodeRow(List<Col> cols, Map<String, Object?> row) {
  final out = <String, dynamic>{};
  final ex = row['extra'];
  if (ex is String && ex.isNotEmpty) {
    try {
      final m = jsonDecode(ex);
      if (m is Map) out.addAll(m.cast<String, dynamic>());
    } catch (_) {}
  }
  for (final c in cols) {
    final v = _fromColumn(c, row[c.column]);
    if (v != null) out[c.key] = v;
  }
  return out;
}

/// Computed snapshot columns stored with a document/purchase (for reports & Sheets).
Map<String, Object?> computedColumns(StoreDef def, Map rec) {
  if (def.store == 'documents') {
    final t = docTotals(rec);
    return {'subtotal': t.sub, 'tax_amount': t.tax, 'grand_total': t.grand};
  }
  if (def.store == 'purchases') {
    return {'grand_total': purchTotals(rec).grand};
  }
  return const {};
}

Map<String, Object?> computedChildColumns(ChildDef child, Map item) {
  if (child.table == 'document_items') {
    return {'area_sqft': lineArea(item), 'line_total': lineAmount(item)};
  }
  if (child.table == 'purchase_items') {
    return {'line_total': lineAmount(item)};
  }
  return const {};
}
