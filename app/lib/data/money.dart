// Money math — an exact port of the JavaScript functions in assets/www/index.html
// (lineArea, lineAmount, docTotals, purchTotals). Used for stored totals,
// Google Sheets rows and restore verification. Do not change pricing rules here
// without changing the JavaScript too.

/// JavaScript `Number(v) || 0`.
double numOf(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.isNaN ? 0 : v.toDouble();
  if (v is bool) return v ? 1 : 0;
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  final p = double.tryParse(s);
  return (p == null || p.isNaN || p.isInfinite) ? 0 : p;
}

/// JavaScript Math.round (rounds .5 up, also for negatives).
double jsRound(double x) => (x + 0.5).floorToDouble();

String measureUnit(Map item) => item['mu'] == 'in' ? 'in' : 'ft';

/// Square feet for one piece. Inches: W×H÷144. Feet (and old lines): W×H.
double lineArea(Map item) {
  final w = numOf(item['width']), h = numOf(item['height']);
  return measureUnit(item) == 'in' ? (w * h) / 144 : w * h;
}

double lineAmount(Map item) {
  final qty = numOf(item['qty']), rate = numOf(item['rate']);
  if (item['basis'] == 'sqft') return rate * lineArea(item) * qty;
  return rate * qty;
}

class DocTotals {
  final double sub, disc, tax, grand, paid, balance;
  const DocTotals(this.sub, this.disc, this.tax, this.grand, this.paid, this.balance);
  String get paymentStatus => balance <= 0 ? 'Paid' : (paid > 0 ? 'Partial' : 'Unpaid');
}

DocTotals docTotals(Map doc) {
  final items = (doc['items'] as List?) ?? const [];
  final sub = items.fold<double>(0, (s, it) => s + lineAmount(it as Map));
  final disc = numOf(doc['discount']);
  final taxable = (sub - disc) < 0 ? 0.0 : sub - disc;
  final tax = jsRound(taxable * (numOf(doc['taxPct']) / 100));
  final grand = taxable + tax;
  final pays = (doc['payments'] as List?) ?? const [];
  final paid = pays.fold<double>(0, (s, p) => s + numOf((p as Map)['amount']));
  return DocTotals(sub, disc, tax, grand, paid, grand - paid);
}

DocTotals purchTotals(Map po) {
  final items = (po['items'] as List?) ?? const [];
  final sub = items.fold<double>(0, (s, it) => s + lineAmount(it as Map));
  final disc = numOf(po['discount']);
  final grand = (sub - disc) < 0 ? 0.0 : sub - disc;
  final pays = (po['payments'] as List?) ?? const [];
  final paid = pays.fold<double>(0, (s, p) => s + numOf((p as Map)['amount']));
  return DocTotals(sub, disc, 0, grand, paid, grand - paid);
}

/// Totals used to verify a backup/restore: sum of invoice grand totals and payments.
Map<String, double> datasetTotals(Map<String, dynamic> data) {
  double grand = 0, paid = 0;
  for (final d in (data['documents'] as List? ?? const [])) {
    if (d is Map && d['type'] == 'invoice') {
      final t = docTotals(d);
      grand += t.grand;
      paid += t.paid;
    }
  }
  double r2(double x) => (x * 100).roundToDouble() / 100;
  return {'invoiceGrand': r2(grand), 'payments': r2(paid)};
}
