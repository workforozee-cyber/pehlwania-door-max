// Minimal REST clients for Google Sheets v4 and Drive v3 (HTTPS only).
// Access tokens come from Android's Google authorization (see google_auth.dart);
// no client secret, service-account key or password is stored in the app.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class ApiError implements Exception {
  final int status; // 0 = network
  final String message;
  final Duration? retryAfter;
  ApiError(this.status, this.message, {this.retryAfter});

  bool get isNetwork => status == 0;
  bool get isAuth => status == 401;
  bool get isPermission => status == 403 && !isRateLimit;
  bool get isNotFound => status == 404;
  bool get isRateLimit => status == 429 || (status == 403 && message.toLowerCase().contains('rate'));
  bool get isRetryable => isNetwork || isRateLimit || status >= 500 || status == 408;

  @override
  String toString() => status == 0 ? 'No internet connection ($message)' : 'Google API error $status: $message';
}

typedef TokenProvider = Future<String> Function();

class GoogleApi {
  final http.Client client;
  final TokenProvider token;
  final Duration timeout;
  GoogleApi(this.client, this.token, {this.timeout = const Duration(seconds: 30)});

  static const sheetsBase = 'https://sheets.googleapis.com/v4/spreadsheets';
  static const driveBase = 'https://www.googleapis.com/drive/v3';
  static const uploadBase = 'https://www.googleapis.com/upload/drive/v3';

  Future<dynamic> _send(String method, Uri url, {Object? body, Map<String, String>? headers, bool raw = false}) async {
    final t = await token();
    final h = {'Authorization': 'Bearer $t', ...?headers};
    http.Response res;
    try {
      final req = http.Request(method, url)..headers.addAll(h);
      if (body is String) {
        req.body = body;
      } else if (body is List<int>) {
        req.bodyBytes = body;
      } else if (body != null) {
        req.headers['Content-Type'] = 'application/json; charset=utf-8';
        req.body = jsonEncode(body);
      }
      res = await http.Response.fromStream(await client.send(req).timeout(timeout)).timeout(timeout);
    } on ApiError {
      rethrow;
    } catch (e) {
      throw ApiError(0, e.toString().split('\n').first);
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (raw) return res.body;
      if (res.body.isEmpty) return <String, dynamic>{};
      try {
        return jsonDecode(res.body);
      } catch (_) {
        throw ApiError(res.statusCode, 'Unexpected response from Google');
      }
    }
    var msg = res.reasonPhrase ?? 'HTTP ${res.statusCode}';
    try {
      final j = jsonDecode(res.body);
      if (j is Map && j['error'] is Map) msg = (j['error']['message'] ?? msg).toString();
    } catch (_) {}
    Duration? ra;
    final raH = res.headers['retry-after'];
    if (raH != null) {
      final s = int.tryParse(raH.trim());
      if (s != null) ra = Duration(seconds: s);
    }
    throw ApiError(res.statusCode, msg, retryAfter: ra);
  }

  String _r(String range) => Uri.encodeComponent(range);

  // ------------------------------------------------------------ Sheets
  Future<Map<String, dynamic>> getSpreadsheet(String id) async {
    final url = Uri.parse('$sheetsBase/$id?fields=spreadsheetId,spreadsheetUrl,properties.title,sheets.properties(sheetId,title)');
    return Map<String, dynamic>.from(await _send('GET', url) as Map);
  }

  Future<Map<String, dynamic>> createSpreadsheet(String title, List<String> tabTitles) async {
    final body = {
      'properties': {'title': title},
      'sheets': [
        for (final t in tabTitles) {'properties': {'title': t, 'gridProperties': {'frozenRowCount': 1}}}
      ],
    };
    return Map<String, dynamic>.from(await _send('POST', Uri.parse(sheetsBase), body: body) as Map);
  }

  Future<void> addSheets(String id, List<String> titles) async {
    if (titles.isEmpty) return;
    await _send('POST', Uri.parse('$sheetsBase/$id:batchUpdate'), body: {
      'requests': [
        for (final t in titles) {'addSheet': {'properties': {'title': t, 'gridProperties': {'frozenRowCount': 1}}}}
      ]
    });
  }

  /// Returns rows for each range (same order as [ranges]).
  Future<List<List<List<Object?>>>> batchGet(String id, List<String> ranges) async {
    final out = <List<List<Object?>>>[];
    for (var i = 0; i < ranges.length; i += 80) {
      final chunk = ranges.sublist(i, min(i + 80, ranges.length));
      final q = chunk.map((r) => 'ranges=${_r(r)}').join('&');
      final url = Uri.parse('$sheetsBase/$id/values:batchGet?$q&valueRenderOption=UNFORMATTED_VALUE&majorDimension=ROWS');
      final res = await _send('GET', url) as Map;
      final vrs = (res['valueRanges'] as List?) ?? const [];
      for (var k = 0; k < chunk.length; k++) {
        final vr = k < vrs.length ? vrs[k] as Map : const {};
        out.add(((vr['values'] as List?) ?? const []).map((row) => List<Object?>.from(row as List)).toList());
      }
    }
    return out;
  }

  Future<int> batchUpdate(String id, List<MapEntry<String, List<Object?>>> rows) async {
    if (rows.isEmpty) return 0;
    var total = 0;
    for (var i = 0; i < rows.length; i += 200) {
      final chunk = rows.sublist(i, min(i + 200, rows.length));
      final res = await _send('POST', Uri.parse('$sheetsBase/$id/values:batchUpdate'), body: {
        'valueInputOption': 'RAW',
        'data': [
          for (final r in chunk) {'range': r.key, 'majorDimension': 'ROWS', 'values': [r.value]}
        ],
      }) as Map;
      total += (res['totalUpdatedRows'] as num?)?.toInt() ?? 0;
    }
    return total;
  }

  /// Appends rows after the last row of the tab. Returns number of rows written.
  Future<int> append(String id, String tabTitle, List<List<Object?>> rows) async {
    if (rows.isEmpty) return 0;
    final range = _r("${_quote(tabTitle)}!A1");
    final url = Uri.parse('$sheetsBase/$id/values/$range:append?valueInputOption=RAW&insertDataOption=INSERT_ROWS');
    final res = await _send('POST', url, body: {'majorDimension': 'ROWS', 'values': rows}) as Map;
    return ((res['updates'] as Map?)?['updatedRows'] as num?)?.toInt() ?? 0;
  }

  String _quote(String t) => "'${t.replaceAll("'", "''")}'";

  // ------------------------------------------------------------- Drive
  Future<Map<String, dynamic>> about() async =>
      Map<String, dynamic>.from(await _send('GET', Uri.parse('$driveBase/about?fields=user(emailAddress,displayName)')) as Map);

  Future<String> ensureFolder(String name) async {
    final q = Uri.encodeQueryComponent("name = '$name' and mimeType = 'application/vnd.google-apps.folder' and trashed = false");
    final res = await _send('GET', Uri.parse('$driveBase/files?q=$q&fields=files(id,name)&spaces=drive')) as Map;
    final files = (res['files'] as List?) ?? const [];
    if (files.isNotEmpty) return (files.first as Map)['id'] as String;
    final created = await _send('POST', Uri.parse('$driveBase/files?fields=id'),
        body: {'name': name, 'mimeType': 'application/vnd.google-apps.folder'}) as Map;
    return created['id'] as String;
  }

  /// Multipart upload; verifies Google's MD5 matches the bytes sent.
  Future<Map<String, dynamic>> uploadFile(String folderId, String name, List<int> bytes) async {
    final boundary = 'pdm${Random().nextInt(1 << 31)}${DateTime.now().microsecondsSinceEpoch}';
    final meta = jsonEncode({'name': name, 'parents': [folderId], 'mimeType': 'application/json'});
    final body = <int>[
      ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'
          '--$boundary\r\nContent-Type: application/json\r\n\r\n'),
      ...bytes,
      ...utf8.encode('\r\n--$boundary--'),
    ];
    final res = Map<String, dynamic>.from(await _send('POST',
        Uri.parse('$uploadBase/files?uploadType=multipart&fields=id,name,size,md5Checksum,createdTime'),
        body: body, headers: {'Content-Type': 'multipart/related; boundary=$boundary'}) as Map);
    final md5Local = md5.convert(bytes).toString();
    if (res['md5Checksum'] != null && res['md5Checksum'] != md5Local) {
      throw ApiError(500, 'Upload verification failed (checksum mismatch)');
    }
    return res;
  }

  Future<List<Map<String, dynamic>>> listFiles(String folderId) async {
    final q = Uri.encodeQueryComponent("'$folderId' in parents and trashed = false");
    final res = await _send('GET',
        Uri.parse('$driveBase/files?q=$q&orderBy=createdTime%20desc&pageSize=50&fields=files(id,name,size,createdTime)')) as Map;
    return ((res['files'] as List?) ?? const []).map((f) => Map<String, dynamic>.from(f as Map)).toList();
  }

  Future<String> downloadText(String fileId) async =>
      await _send('GET', Uri.parse('$driveBase/files/$fileId?alt=media'), raw: true) as String;
}
