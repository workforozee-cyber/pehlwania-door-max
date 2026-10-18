// Google Sheets tab and column layout. The FIRST column of every data tab is the
// record's stable ID — rows are always matched by that ID, never by row number,
// name or phone. Rows are never physically deleted by the app: a deleted record
// gets "Deleted = TRUE" and a "Deleted At" time.
import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../data/money.dart';
import '../data/store_defs.dart';

class TabDef {
  final String entity;
  final String title;
  final List<String> headers;
  final bool financial; // conflicting remote edits are never overwritten automatically
  const TabDef(this.entity, this.title, this.headers, {this.financial = false});
  int get deletedCol => headers.indexOf('Deleted');
}

const kSyncLogTab = 'Sync Log';
const kSyncLogHeaders = ['Timestamp', 'Device', 'Event', 'Entity', 'Record ID', 'Result', 'Details'];

const List<TabDef> kTabs = [
  TabDef('customers', 'Customers',
      ['Customer ID', 'Name', 'Phone', 'Address', 'Created At', 'Updated At', 'Deleted', 'Deleted At']),
  TabDef('documents', 'Orders', [
    'Order ID', 'Type', 'Number', 'Date', 'Customer ID', 'Customer Name', 'Customer Phone', 'Branch',
    'Subtotal', 'Discount', 'Tax %', 'Tax Amount', 'Grand Total', 'Paid', 'Balance', 'Payment Status',
    'Order Status', 'From Quote', 'Note', 'Created At', 'Updated At', 'Deleted', 'Deleted At',
  ], financial: true),
  TabDef('document_items', 'Order Items', [
    'Item ID', 'Order ID', 'Order Number', 'Line', 'Product ID', 'Description', 'Width', 'Height',
    'Measure Unit', 'Area per Piece (sq ft)', 'Qty', 'Unit', 'Price Basis', 'Agreed Rate', 'Line Total',
    'Updated At', 'Deleted', 'Deleted At',
  ], financial: true),
  TabDef('payments', 'Payments', [
    'Payment ID', 'Order ID', 'Order Number', 'Customer ID', 'Customer Name', 'Date', 'Amount', 'Method',
    'Note', 'Created At', 'Updated At', 'Deleted', 'Deleted At',
  ], financial: true),
  TabDef('products', 'Products & Rates', [
    'Product ID', 'Name', 'Category', 'Unit', 'Current Rate', 'Price Basis', 'Stock Item', 'Stock Qty',
    'Last Rate Change', 'Updated At', 'Deleted', 'Deleted At',
  ]),
  TabDef('expenses', 'Daily Expenses',
      ['Expense ID', 'Date', 'Category', 'Description', 'Branch', 'Amount', 'Created At', 'Updated At', 'Deleted', 'Deleted At']),
  TabDef('fixedexpenses', 'Fixed Monthly Expenses', [
    'Fixed Expense ID', 'Name', 'Category', 'Monthly Amount', 'Branch', 'Active', 'Start Month', 'End Month',
    'Note', 'Updated At', 'Deleted', 'Deleted At',
  ]),
];

final Map<String, TabDef> kTabByEntity = {for (final t in kTabs) t.entity: t};

String colLetter(int n) {
  // 1 -> A
  var s = '';
  while (n > 0) {
    final m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

String quoteTab(String title) => "'${title.replaceAll("'", "''")}'";

String _iso(Object? ms) {
  if (ms == null) return '';
  final v = ms is num ? ms.toInt() : int.tryParse(ms.toString());
  if (v == null) return ms.toString();
  return DateTime.fromMillisecondsSinceEpoch(v).toIso8601String().substring(0, 19).replaceFirst('T', ' ');
}

double _r2(double x) => (x * 100).roundToDouble() / 100;

/// Builds the current spreadsheet row for a record from SQLite.
/// Returns null if the record no longer exists locally.
class RowBuilder {
  final DatabaseExecutor db;
  Map<String, String>? _branches;
  RowBuilder(this.db);

  Future<String> _branch(Object? id) async {
    if (_branches == null) {
      _branches = {};
      final r = await db.query('settings', where: 'id = ?', whereArgs: ['app']);
      if (r.isNotEmpty) {
        try {
          final m = decodeSettings(r.first['data'] as String);
          for (final b in (m['branches'] as List? ?? const [])) {
            if (b is Map) _branches![b['id'].toString()] = (b['name'] ?? '').toString();
          }
        } catch (_) {}
      }
    }
    return id == null ? '' : (_branches![id.toString()] ?? '');
  }

  Future<Map<String, dynamic>?> _doc(String id) async {
    final rows = await db.query('documents', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final def = kStoreByName['documents']!;
    final d = decodeRow(def.cols, rows.first);
    for (final c in def.children) {
      final kids = await db.query(c.table, where: 'document_id = ?', whereArgs: [id]);
      d[c.key] = kids.map((k) => decodeRow(c.cols, k)).toList();
    }
    return d;
  }

  Future<List<Object?>?> build(String entity, String id) async {
    switch (entity) {
      case 'customers':
        final r = await db.query('customers', where: 'id = ?', whereArgs: [id]);
        if (r.isEmpty) return null;
        final c = r.first;
        return [id, c['name'], c['phone'] ?? '', c['address'] ?? '', _iso(c['created_at']), _iso(c['updated_at']), false, ''];
      case 'documents':
        final d = await _doc(id);
        if (d == null) return null;
        final t = docTotals(d);
        return [
          id, d['type'] == 'quote' ? 'Quotation' : 'Invoice', d['no'], d['date'], d['customerId'] ?? '',
          d['customerName'] ?? '', d['customerPhone'] ?? '', await _branch(d['branchId']),
          _r2(t.sub), _r2(t.disc), numOf(d['taxPct']), _r2(t.tax), _r2(t.grand),
          d['type'] == 'quote' ? 0 : _r2(t.paid), d['type'] == 'quote' ? 0 : _r2(t.balance),
          d['type'] == 'quote' ? 'Quotation' : t.paymentStatus,
          d['orderStatus'] ?? '', d['fromQuote'] ?? '', d['note'] ?? '',
          _iso(d['createdAt']), _iso(d['updatedAt'] ?? d['createdAt']), false, '',
        ];
      case 'document_items':
        final r = await db.rawQuery(
            'SELECT i.*, d.no AS doc_no, d.updated_at AS doc_updated, d.created_at AS doc_created FROM document_items i JOIN documents d ON d.id = i.document_id WHERE i.id = ?',
            [id]);
        if (r.isEmpty) return null;
        final i = r.first;
        final item = decodeRow(itemCols, i);
        return [
          id, i['document_id'], i['doc_no'], i['line_no'], i['product_id'] ?? '', i['description'] ?? '',
          i['width'] ?? '', i['height'] ?? '', i['measure_unit'], (lineArea(item) * 10000).roundToDouble() / 10000,
          numOf(i['qty']), i['unit'] ?? '', i['basis'] == 'sqft' ? 'per sq ft' : 'per piece',
          numOf(i['rate']), _r2(lineAmount(item)), _iso(i['doc_updated'] ?? i['doc_created']), false, '',
        ];
      case 'payments':
        final r = await db.rawQuery(
            'SELECT p.*, d.no AS doc_no, d.customer_id AS cust_id, d.customer_name AS cust_name FROM payments p JOIN documents d ON d.id = p.document_id WHERE p.id = ?',
            [id]);
        if (r.isEmpty) return null;
        final p = r.first;
        final created = _iso(p['created_at']);
        return [
          id, p['document_id'], p['doc_no'], p['cust_id'] ?? '', p['cust_name'] ?? '',
          (p['date'] ?? '').toString().length >= 10 ? (p['date'] as String).substring(0, 10) : (p['date'] ?? ''),
          numOf(p['amount']), p['method'] ?? '', p['note'] ?? '', created, created, false, '',
        ];
      case 'products':
        final r = await db.query('products', where: 'id = ?', whereArgs: [id]);
        if (r.isEmpty) return null;
        final p = decodeRow(kStoreByName['products']!.cols, r.first);
        final hist = p['rateHistory'];
        final last = (hist is List && hist.isNotEmpty && hist.last is Map) ? (hist.last['at'] ?? '').toString() : '';
        return [
          id, p['name'], p['category'] ?? '', p['unit'] ?? '', numOf(p['price']),
          p['defaultBasis'] == 'sqft' ? 'per sq ft' : 'per piece', p['stocked'] == true, numOf(p['stock']),
          last.length >= 19 ? last.substring(0, 19).replaceFirst('T', ' ') : last,
          _iso(p['updatedAt'] ?? p['createdAt']), false, '',
        ];
      case 'expenses':
        final r = await db.query('expenses', where: 'id = ?', whereArgs: [id]);
        if (r.isEmpty) return null;
        final e = r.first;
        return [
          id, e['date'], e['category'] ?? '', e['description'] ?? '', await _branch(e['branch_id']),
          numOf(e['amount']), _iso(e['created_at']), _iso(e['updated_at'] ?? e['created_at']), false, '',
        ];
      case 'fixedexpenses':
        final r = await db.query('fixed_expenses', where: 'id = ?', whereArgs: [id]);
        if (r.isEmpty) return null;
        final f = r.first;
        return [
          id, f['name'], f['category'] ?? '', numOf(f['amount']),
          f['branch_id'] == null || f['branch_id'] == '' ? 'All' : await _branch(f['branch_id']),
          f['active'] != 0, f['start_month'] ?? '', f['end_month'] ?? '', f['note'] ?? '',
          _iso(f['updated_at'] ?? f['created_at']), false, '',
        ];
    }
    throw ArgumentError('Unknown sync entity $entity');
  }
}

Map<String, dynamic> decodeSettings(String json) => Map<String, dynamic>.from(jsonDecode(json) as Map);

/// Normalises a cell so values written and read back hash identically.
String normCell(Object? v) {
  if (v == null) return '';
  if (v is bool) return v ? 'TRUE' : 'FALSE';
  if (v is num) {
    if (v.isNaN) return '';
    if (v == v.roundToDouble() && v.abs() < 9e15) return v.toInt().toString();
    return v.toDouble().toString();
  }
  return v.toString();
}

List<String> normRow(List<Object?> row, int width) {
  final out = row.map(normCell).toList();
  while (out.length < width) {
    out.add('');
  }
  if (out.length > width) return out.sublist(0, width);
  return out;
}
