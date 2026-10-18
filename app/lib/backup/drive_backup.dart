// Optional Google Drive backup: uploads the SAME complete v3 backup file to a
// "Pehlwania POS Backups" folder (drive.file scope: the app only sees files it created).
import 'dart:convert';

import '../data/repository.dart';
import '../sync/sync_service.dart';
import 'backup_service.dart';

class DriveBackup {
  static const folderName = 'Pehlwania POS Backups';
  final Repository repo;
  final BackupService backups;
  final SyncService sync;
  DriveBackup(this.repo, this.backups, this.sync);

  Future<Map<String, dynamic>> status() => repo.kvJson('drive.status');

  Future<Map<String, Object?>> backupNow() async {
    try {
      final text = await backups.buildBackupText(source: 'android-drive');
      final v = validateBackupText(text);
      if (!v.ok) throw StateError('Backup could not be verified: ${v.errors.first}');
      final name = BackupService.fileNameNow();
      final bytes = utf8.encode(text);
      final res = await sync.withAuthRetry((api) async {
        final folder = await api.ensureFolder(folderName);
        return api.uploadFile(folder, name, bytes); // verifies MD5 from Google
      });
      if ('${res['size']}' != '${bytes.length}') {
        throw StateError('Drive reported ${res['size']} bytes, expected ${bytes.length}');
      }
      final st = await status();
      st.addAll({
        'lastSuccessAt': DateTime.now().toUtc().toIso8601String(),
        'fileName': name, 'fileId': res['id'], 'sizeBytes': bytes.length, 'lastError': '',
      });
      await repo.kvSetJson('drive.status', st);
      return {'fileName': name, 'sizeBytes': bytes.length};
    } catch (e) {
      final st = await status();
      st.addAll({'lastError': e.toString(), 'lastAttemptAt': DateTime.now().toUtc().toIso8601String()});
      await repo.kvSetJson('drive.status', st);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> list() => sync.withAuthRetry((api) async {
        final folder = await api.ensureFolder(folderName);
        return api.listFiles(folder);
      });

  Future<BackupValidation> download(String fileId) async {
    final text = await sync.withAuthRetry((api) => api.downloadText(fileId));
    return validateBackupText(text);
  }
}
