// In-memory fake of the parts of the Google Sheets v4 + Drive v3 REST API the app uses.
// Lets tests run sync end-to-end (including failures) without a real Google account.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeSheets {
  final String id;
  final Map<String, List<List<Object?>>> tabs = {}; // title -> rows (row 0 = header)
  bool exists = true;
  bool forbidden = false;
  int failNextWith = 0; // e.g. 429 / 500 — next request of any kind
  int failAppendWith = 0; // next append (row write) fails with this status
  bool dropNextAppendResponse = false; // apply append, then "lose" the response
  int unauthorizedOnce = 0; // number of 401 responses to return
  int requests = 0;
  final List<String> calls = [];
  final Map<String, String> driveFiles = {}; // id -> content
  final Map<String, String> driveNames = {};

  FakeSheets(this.id);

  List<List<Object?>> tab(String t) => tabs[t] ?? (throw StateError('no tab $t'));

  static String _unquote(String t) {
    t = t.trim();
    if (t.startsWith("'") && t.endsWith("'")) t = t.substring(1, t.length - 1).replaceAll("''", "'");
    return t;
  }

  static int _colIndex(String letters) {
    var n = 0;
    for (final c in letters.codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  /// Parses 'Tab'!A2:C5 / 'Tab'!1:1 / 'Tab'!A2:A / 'Tab'!A7
  ({String tab, int r0, int? r1, int c0, int? c1}) _range(String a1) {
    final bang = a1.lastIndexOf('!');
    final tab = _unquote(a1.substring(0, bang));
    final ref = a1.substring(bang + 1);
    final parts = ref.split(':');
    ({int? r, int? c}) cell(String s) {
      final m = RegExp(r'^([A-Z]*)(\d*)$').firstMatch(s)!;
      return (c: m.group(1)!.isEmpty ? null : _colIndex(m.group(1)!), r: m.group(2)!.isEmpty ? null : int.parse(m.group(2)!) - 1);
    }
    final a = cell(parts[0]);
    final b = parts.length > 1 ? cell(parts[1]) : a;
    return (tab: tab, r0: a.r ?? 0, r1: parts.length > 1 ? b.r : a.r, c0: a.c ?? 0, c1: b.c);
  }

  List<List<Object?>> _read(String a1) {
    final r = _range(a1);
    final rows = tab(r.tab);
    final out = <List<Object?>>[];
    final end = r.r1 ?? (rows.length - 1);
    for (var i = r.r0; i <= end && i < rows.length; i++) {
      final row = rows[i];
      final c1 = r.c1 ?? (row.length - 1);
      final slice = <Object?>[];
      for (var c = r.c0; c <= c1 && c < row.length; c++) {
        slice.add(row[c]);
      }
      while (slice.isNotEmpty && (slice.last == null || slice.last == '')) {
        slice.removeLast();
      }
      out.add(slice);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out;
  }

  int _write(String a1, List<List<Object?>> values) {
    final r = _range(a1);
    final rows = tab(r.tab);
    for (var i = 0; i < values.length; i++) {
      final ri = r.r0 + i;
      while (rows.length <= ri) {
        rows.add([]);
      }
      final row = rows[ri];
      for (var c = 0; c < values[i].length; c++) {
        final ci = r.c0 + c;
        while (row.length <= ci) {
          row.add('');
        }
        row[ci] = _store(values[i][c]);
      }
    }
    return values.length;
  }

  /// Sheets stores numbers as doubles, strings as-is (RAW), bools as bools.
  Object? _store(Object? v) => v is int ? v.toDouble() : v;

  /// Numbers come back as JSON numbers (whole numbers without ".0").
  Object? _out(Object? v) => (v is double && v == v.roundToDouble()) ? v.toInt() : v;

  http.Response _json(Object o, [int status = 200]) =>
      http.Response(jsonEncode(o), status, headers: {'content-type': 'application/json'});
  http.Response _err(int status, String msg) => _json({'error': {'code': status, 'message': msg}}, status);

  late final MockClient client = MockClient((req) async {
    requests++;
    final url = req.url;
    calls.add('${req.method} ${url.path}');
    if (unauthorizedOnce > 0) {
      unauthorizedOnce--;
      return _err(401, 'Request had invalid authentication credentials.');
    }
    if (failNextWith != 0) {
      final s = failNextWith;
      failNextWith = 0;
      return _err(s, s == 429 ? 'Quota exceeded (rate limit)' : 'Backend error');
    }
    final path = url.path;
    // ---------------- Drive
    if (url.host == 'www.googleapis.com') {
      if (path.endsWith('/about')) return _json({'user': {'emailAddress': 'shop@example.com', 'displayName': 'Shop'}});
      if (path.startsWith('/upload/drive/v3/files')) {
        final body = utf8.decode(req.bodyBytes);
        final start = body.indexOf('Content-Type: application/json\r\n\r\n');
        final content = body.substring(start + 'Content-Type: application/json\r\n\r\n'.length, body.lastIndexOf('\r\n--'));
        final id = 'file${driveFiles.length + 1}';
        driveFiles[id] = content;
        final meta = jsonDecode(body.substring(body.indexOf('{'), body.indexOf('}\r\n') + 1)) as Map;
        driveNames[id] = meta['name'] as String;
        return _json({'id': id, 'name': meta['name'], 'size': '${utf8.encode(content).length}', 'createdTime': '2026-01-01T00:00:00Z'});
      }
      if (path == '/drive/v3/files' && req.method == 'GET') {
        final q = url.queryParameters['q'] ?? '';
        if (q.contains('folder')) return _json({'files': [{'id': 'folder1', 'name': 'Pehlwania POS Backups'}]});
        return _json({'files': [for (final e in driveFiles.entries) {'id': e.key, 'name': driveNames[e.key], 'size': '${e.value.length}', 'createdTime': '2026-01-01T00:00:00Z'}]});
      }
      if (path.startsWith('/drive/v3/files/')) return http.Response(driveFiles[path.split('/').last] ?? '', 200);
      return _err(404, 'not found');
    }
    // ---------------- Sheets
    if (req.method == 'POST' && path == '/v4/spreadsheets') {
      final b = jsonDecode(req.body) as Map;
      for (final s in (b['sheets'] as List)) {
        tabs[(s as Map)['properties']['title'] as String] = [];
      }
      return _json({'spreadsheetId': id, 'spreadsheetUrl': 'https://docs.google.com/spreadsheets/d/$id', 'properties': b['properties']});
    }
    final m = RegExp(r'^/v4/spreadsheets/([^/:]+)(.*)$').firstMatch(path);
    if (m == null) return _err(404, 'bad path');
    if (m.group(1) != id || !exists) return _err(404, 'Requested entity was not found.');
    if (forbidden) return _err(403, 'The caller does not have permission');
    final rest = m.group(2)!;
    if (rest.isEmpty && req.method == 'GET') {
      return _json({
        'spreadsheetId': id, 'spreadsheetUrl': 'https://docs.google.com/spreadsheets/d/$id',
        'properties': {'title': 'Test Sheet'},
        'sheets': [for (final t in tabs.keys) {'properties': {'title': t, 'sheetId': t.hashCode}}],
      });
    }
    if (rest == ':batchUpdate') {
      final b = jsonDecode(req.body) as Map;
      for (final r in (b['requests'] as List)) {
        final add = (r as Map)['addSheet'];
        if (add != null) tabs[(add as Map)['properties']['title'] as String] = [];
      }
      return _json({'replies': []});
    }
    if (rest == '/values:batchGet') {
      final ranges = url.queryParametersAll['ranges'] ?? const [];
      return _json({
        'valueRanges': [for (final r in ranges) {'range': r, 'values': _read(r).map((row) => row.map(_out).toList()).toList()}]
      });
    }
    if (rest == '/values:batchUpdate') {
      final b = jsonDecode(req.body) as Map;
      var n = 0;
      for (final d in (b['data'] as List)) {
        n += _write((d as Map)['range'] as String, (d['values'] as List).map((r) => List<Object?>.from(r as List)).toList());
      }
      return _json({'totalUpdatedRows': n});
    }
    final app = RegExp(r'^/values/(.+):append$').firstMatch(rest);
    if (app != null) {
      if (failAppendWith != 0) {
        final st = failAppendWith;
        failAppendWith = 0;
        return http.Response(jsonEncode({'error': {'code': st, 'message': 'Quota exceeded (rate limit)'}}), st,
            headers: {'retry-after': '120', 'content-type': 'application/json'});
      }
      final range = Uri.decodeComponent(app.group(1)!);
      final t = _range(range).tab;
      final rows = tab(t);
      final b = jsonDecode(req.body) as Map;
      final values = (b['values'] as List).map((r) => List<Object?>.from(r as List)).toList();
      // find last non-empty row
      var last = rows.length;
      while (last > 0 && rows[last - 1].every((c) => c == null || c == '')) {
        last--;
      }
      rows.length = last;
      for (final v in values) {
        rows.add(v.map(_store).toList());
      }
      if (dropNextAppendResponse) {
        dropNextAppendResponse = false;
        throw http.ClientException('Connection reset by peer');
      }
      return _json({'updates': {'updatedRows': values.length}});
    }
    return _err(400, 'unsupported $rest');
  });

  /// Data rows (without header) whose first column is [recordId].
  List<List<Object?>> rowsFor(String tabTitle, String recordId) =>
      tab(tabTitle).skip(1).where((r) => r.isNotEmpty && r.first == recordId).toList();
}
