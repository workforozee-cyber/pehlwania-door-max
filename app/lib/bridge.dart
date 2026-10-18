// JavaScript <-> Dart bridge. The page sends {id, method, args} through the
// "PDMBridge" channel; we reply with PDMNative._resolve(id, ok, payload).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'backup/backup_service.dart';
import 'backup/drive_backup.dart';
import 'data/repository.dart';
import 'data/store_defs.dart';
import 'pdf/bill_pdf.dart';
import 'sync/google_auth.dart';
import 'sync/sync_service.dart';

typedef JsRunner = Future<void> Function(String js);

class Bridge {
  final Repository repo;
  final BackupService backups;
  final SyncService sync;
  final DriveBackup drive;
  final JsRunner runJs;
  final Map<String, BackupValidation> _pendingRestores = {};

  Bridge({required this.repo, required this.backups, required this.sync, required this.drive, required this.runJs});

  Future<void> handle(String message) async {
    int? id;
    try {
      final m = jsonDecode(message) as Map;
      id = (m['id'] as num).toInt();
      final args = (m['args'] is Map) ? Map<String, dynamic>.from(m['args'] as Map) : <String, dynamic>{};
      final result = await dispatch(m['method'] as String, args);
      await _reply(id, true, result);
    } catch (e) {
      if (id != null) {
        await _reply(id, false, {'message': _message(e), 'code': e is AuthFailure ? e.code : null});
      }
    }
  }

  String _message(Object e) {
    final s = e.toString();
    return s.startsWith('Bad state: ') ? s.substring(11) : s.replaceFirst('Exception: ', '');
  }

  Future<void> _reply(int id, bool ok, Object? payload) async {
    final json = jsonEncode(payload);
    await runJs('PDMNative._resolve($id,$ok,$json)');
  }

  Future<Object?> dispatch(String method, Map<String, dynamic> a) async {
    switch (method) {
      // ---------------------------------------------------------------- data
      case 'db.open':
        return true;
      case 'db.getAll':
        return repo.getAll(a['store'] as String);
      case 'db.get':
        return repo.get(a['store'] as String, a['id'].toString());
      case 'db.batch':
        final ops = ((a['ops'] as List?) ?? const []).map((o) => StoreOp.fromJson(o as Map)).toList();
        final r = await repo.applyBatch(ops);
        if ((r['queued'] as int? ?? 0) > 0) sync.scheduleSoon();
        return r;
      case 'db.wipe':
        await backups.writeSafetyBackup();
        await repo.wipe();
        return true;

      // -------------------------------------------------------------- backup
      case 'backup.status':
        return backups.status();
      case 'backup.export':
        return _exportBackup();
      case 'backup.pick':
        final f = await FilePicker.pickFile(type: FileType.any);
        if (f == null) return {'cancelled': true};
        final bytes = await f.readAsBytes();
        return _inspect(utf8.decode(bytes, allowMalformed: true));
      case 'backup.restore':
        final v = _pendingRestores.remove(a['token']);
        if (v == null) throw StateError('Please choose the backup file again.');
        final r = await backups.restore(v);
        sync.scheduleSoon(const Duration(seconds: 5));
        return r;

      // ---------------------------------------------------------------- sync
      case 'sync.status':
        return sync.status();
      case 'sync.connect':
        return sync.connect();
      case 'sync.disconnect':
        return sync.disconnect();
      case 'sync.createSpreadsheet':
        return sync.createSpreadsheet();
      case 'sync.useSpreadsheet':
        return sync.useSpreadsheet((a['id'] ?? '').toString().trim());
      case 'sync.now':
        return sync.syncNow();
      case 'sync.retryFailed':
        return sync.retryFailed();
      case 'sync.conflicts':
        return sync.conflicts();
      case 'sync.resolveConflicts':
        return sync.resolveConflicts((a['mode'] ?? '').toString());
      case 'sync.log':
        return sync.log(limit: (a['limit'] as num?)?.toInt() ?? 150);

      // --------------------------------------------------------------- drive
      case 'drive.status':
        return drive.status();
      case 'drive.backup':
        return drive.backupNow();
      case 'drive.list':
        return drive.list();
      case 'drive.inspect':
        final v = await drive.download(a['fileId'].toString());
        return _register(v);

      // ------------------------------------------------------- pdf / sharing
      case 'pdf.print':
        final b = Map<String, dynamic>.from(a['bill'] as Map);
        final bytes = await buildBillPdf(b, logo: await _logo());
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: _s(b['fileName'], 'bill.pdf'));
        return true;
      case 'pdf.share':
        final b = Map<String, dynamic>.from(a['bill'] as Map);
        final bytes = await buildBillPdf(b, logo: await _logo());
        await Printing.sharePdf(bytes: bytes, filename: _s(b['fileName'], 'bill.pdf'));
        return true;
      case 'app.openUrl':
        final uri = Uri.parse(a['url'].toString());
        if (uri.scheme != 'https') throw StateError('Only secure links can be opened');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError('Could not open the link (is WhatsApp installed?)');
        }
        return true;
    }
    throw DataError('Unknown action: $method');
  }

  String _s(Object? v, String d) => (v == null || v.toString().isEmpty) ? d : v.toString();

  Uint8List? _logoCache;
  Future<Uint8List?> _logo() async {
    try {
      return _logoCache ??= (await rootBundle.load('assets/brand/logo.png')).buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _inspect(String text) => _register(validateBackupText(text));

  Map<String, Object?> _register(BackupValidation v) {
    final token = const Uuid().v4();
    if (v.ok) _pendingRestores[token] = v;
    return {...v.toJson(), 'token': token};
  }

  Future<Map<String, Object?>> _exportBackup() async {
    try {
      final text = await backups.buildBackupText();
      // verify the exact bytes before writing them anywhere
      final v = validateBackupText(text);
      if (!v.ok) throw StateError('Backup verification failed: ${v.errors.first}');
      final bytes = Uint8List.fromList(utf8.encode(text));
      final name = BackupService.fileNameNow();
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save backup file',
        fileName: name,
        bytes: bytes,
      );
      if (uri == null) return {'cancelled': true}; // previous successful status is kept
      final path = uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
      var readBack = false;
      try {
        final f = File(path);
        if (await f.exists()) {
          final back = await f.readAsString();
          if (!validateBackupText(back).ok || back.length != text.length) {
            throw StateError('The saved file could not be verified (storage problem?)');
          }
          readBack = true;
        }
      } on FileSystemException {
        // Storage Access Framework locations are not always readable by path
      }
      await backups.recordSuccess(
        fileName: name,
        location: readBack ? path : 'Chosen folder (Android file picker)',
        sizeBytes: bytes.length,
        counts: v.counts,
      );
      return {'fileName': name, 'sizeBytes': bytes.length, 'readBackVerified': readBack};
    } catch (e) {
      await backups.recordFailure(_message(e));
      rethrow;
    }
  }
}
