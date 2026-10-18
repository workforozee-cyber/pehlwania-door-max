// PDF bill (A4) with the shop logo, branch address and contact numbers on top.
// The bill data comes ready-calculated from the app (billModel() in index.html),
// so the PDF always matches the screen and the printed desktop bill.
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _navy = PdfColor.fromInt(0xFF1E3157);
const _orange = PdfColor.fromInt(0xFFE07D1C);
const _red = PdfColor.fromInt(0xFFC0392B);
const _stripe = PdfColor.fromInt(0xFFF7F4EE);

String _s(Object? v) => v == null ? '' : v.toString();

/// Characters outside the standard PDF font are replaced so nothing prints as boxes.
String _safe(Object? v) => _s(v)
    .replaceAll('²', '2')
    .replaceAll('—', '-')
    .replaceAll('–', '-')
    .replaceAll('•', '-')
    .replaceAll(RegExp(r'[^\x00-\xFF×]'), '');

Future<Uint8List> buildBillPdf(Map<String, dynamic> b, {Uint8List? logo}) async {
  final doc = pw.Document(title: '${_s(b['title'])} ${_s(b['no'])}', author: _s(b['shopName']));
  final cur = _s(b['currency']).isEmpty ? 'Rs' : _s(b['currency']);
  final branch = (b['branch'] as Map?) ?? const {};
  final items = ((b['items'] as List?) ?? const []).cast<Map>();
  final isInvoice = b['type'] == 'invoice';
  final logoImg = logo == null ? null : pw.MemoryImage(logo);

  pw.Widget cell(String t, {bool right = false, bool bold = false, PdfColor? color, double size = 9.5}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: pw.Text(_safe(t),
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color)),
      );

  pw.Widget totRow(String l, String v, {bool big = false, PdfColor? color}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(_safe(l), style: pw.TextStyle(fontSize: big ? 12.5 : 10, fontWeight: big ? pw.FontWeight.bold : null, color: color)),
          pw.Text(_safe('$cur $v'), style: pw.TextStyle(fontSize: big ? 12.5 : 10, fontWeight: pw.FontWeight.bold, color: color)),
        ]),
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(30),
    build: (ctx) => [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (logoImg != null) pw.Container(width: 70, height: 70, margin: const pw.EdgeInsets.only(right: 10), child: pw.Image(logoImg)),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(_safe(b['shopName']), style: pw.TextStyle(fontSize: 19, fontWeight: pw.FontWeight.bold, color: _navy)),
            if (_s(b['tagline']).isNotEmpty)
              pw.Text(_safe(b['tagline']).toUpperCase(), style: pw.TextStyle(fontSize: 8.5, color: _orange, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Text(_safe(branch['name']), style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
            if (_s(branch['phone']).isNotEmpty) pw.Text('Phone: ${_safe(branch['phone'])}', style: const pw.TextStyle(fontSize: 9.5)),
            if (_s(branch['address']).isNotEmpty) pw.Text(_safe(branch['address']), style: const pw.TextStyle(fontSize: 9.5)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(_safe(b['title']), style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: _navy, letterSpacing: 1.5)),
          pw.SizedBox(height: 6),
          pw.Text('No: ${_safe(b['no'])}', style: const pw.TextStyle(fontSize: 10)),
          pw.Text('Date: ${_safe(b['date'])}', style: const pw.TextStyle(fontSize: 10)),
          if (_s(b['fromQuote']).isNotEmpty) pw.Text('Ref Quote: ${_safe(b['fromQuote'])}', style: const pw.TextStyle(fontSize: 10)),
        ]),
      ]),
      pw.Container(height: 2.5, color: _navy, margin: const pw.EdgeInsets.symmetric(vertical: 8)),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('BILL TO', style: pw.TextStyle(fontSize: 8.5, color: _orange, fontWeight: pw.FontWeight.bold)),
            pw.Text(_safe(b['customerName']), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            if (_s(b['customerPhone']).isNotEmpty) pw.Text('Phone: ${_safe(b['customerPhone'])}', style: const pw.TextStyle(fontSize: 10)),
          ]),
        ),
        if (_s(b['note']).isNotEmpty)
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text('NOTE', style: pw.TextStyle(fontSize: 8.5, color: _orange, fontWeight: pw.FontWeight.bold)),
              pw.Text(_safe(b['note']), style: const pw.TextStyle(fontSize: 10), textAlign: pw.TextAlign.right),
            ]),
          ),
      ]),
      pw.SizedBox(height: 10),
      pw.Table(
        columnWidths: {
          0: const pw.FixedColumnWidth(22), 1: const pw.FlexColumnWidth(3.2), 2: const pw.FlexColumnWidth(1.6),
          3: const pw.FlexColumnWidth(1.1), 4: const pw.FlexColumnWidth(1.3), 5: const pw.FlexColumnWidth(1.4),
        },
        children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: _navy), children: [
            cell('#', bold: true, color: PdfColors.white, size: 9),
            cell('Description', bold: true, color: PdfColors.white, size: 9),
            cell('Size', bold: true, color: PdfColors.white, right: true, size: 9),
            cell('Qty', bold: true, color: PdfColors.white, right: true, size: 9),
            cell('Rate', bold: true, color: PdfColors.white, right: true, size: 9),
            cell('Amount ($cur)', bold: true, color: PdfColors.white, right: true, size: 9),
          ]),
          for (var i = 0; i < items.length; i++)
            pw.TableRow(decoration: pw.BoxDecoration(color: i.isOdd ? _stripe : null), children: [
              cell(_s(items[i]['n'])),
              cell(_s(items[i]['desc'])),
              cell(_s(items[i]['size']) + (_s(items[i]['area']).isEmpty ? '' : '\n${_s(items[i]['area'])}'), right: true),
              cell(_s(items[i]['qty']), right: true),
              cell(_s(items[i]['rate']), right: true),
              cell(_s(items[i]['amount']), right: true),
            ]),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Row(children: [
        pw.Spacer(),
        pw.SizedBox(
          width: 230,
          child: pw.Column(children: [
            totRow('Subtotal', _s(b['sub'])),
            if (_s(b['disc']).isNotEmpty) totRow('Discount', '- ${_s(b['disc'])}'),
            if (_s(b['tax']).isNotEmpty) totRow('Tax (${_s(b['taxPct'])}%)', _s(b['tax'])),
            pw.Container(height: 1.5, color: _navy, margin: const pw.EdgeInsets.symmetric(vertical: 3)),
            totRow('Grand Total', _s(b['grand']), big: true, color: _navy),
            if (isInvoice) totRow('Amount Received', _s(b['paid'])),
            if (isInvoice) totRow('Balance Due', _s(b['balance']), big: true, color: _red),
          ]),
        ),
      ]),
      pw.SizedBox(height: 8),
      pw.Text('In words: ${_safe(b['words'])}', style: pw.TextStyle(fontSize: 9.5, fontStyle: pw.FontStyle.italic)),
      if (_s(b['terms']).isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('Terms: ${_safe(b['terms'])}', style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
      ],
      pw.SizedBox(height: 36),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        _sign('Customer Signature'),
        _sign('For ${_safe(b['shopName'])}'),
      ]),
      pw.SizedBox(height: 14),
      pw.Divider(color: PdfColors.grey400),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Thank you for your business!', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.Text('${_safe(branch['name'])}  ${_safe(branch['phone'])}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
      ]),
    ],
  ));
  return doc.save();
}

pw.Widget _sign(String label) => pw.Container(
      width: 170,
      padding: const pw.EdgeInsets.only(top: 5),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 0.8))),
      child: pw.Text(label, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9.5)),
    );
