// Google authorization through Android's Identity AuthorizationClient
// (implemented in MainActivity.kt). Returns short-lived OAuth access tokens;
// nothing secret is embedded in the app. Requires an "Android" OAuth client in
// Google Cloud for this package name + signing certificate SHA-1.
import 'package:flutter/services.dart';

const kGoogleScopes = [
  'https://www.googleapis.com/auth/spreadsheets', // read/write the chosen spreadsheet
  'https://www.googleapis.com/auth/drive.file', // only files this app creates/opens (backups, new sheet)
];

class AuthFailure implements Exception {
  final String code; // NOT_CONFIGURED | CANCELED | NEEDS_UI | NETWORK | AUTH_ERROR
  final String message;
  AuthFailure(this.code, this.message);
  @override
  String toString() => message;
}

abstract class GoogleAuth {
  /// interactive=false never shows UI; throws NEEDS_UI if consent is required.
  Future<String> accessToken({required bool interactive});
  Future<void> clearToken(String token);
  Future<Map<String, String>> signingInfo();
}

class AndroidGoogleAuth implements GoogleAuth {
  static const _ch = MethodChannel('pdm/google_auth');

  @override
  Future<String> accessToken({required bool interactive}) async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('authorize', {'interactive': interactive, 'scopes': kGoogleScopes});
      final t = r?['accessToken'] as String?;
      if (t == null || t.isEmpty) throw AuthFailure('AUTH_ERROR', 'Google did not return an access token');
      return t;
    } on PlatformException catch (e) {
      throw AuthFailure(e.code, _friendly(e.code, e.message));
    }
  }

  String _friendly(String code, String? msg) {
    switch (code) {
      case 'NOT_CONFIGURED':
        return 'Google sign-in is not set up for this app yet (Google Cloud OAuth client missing for this package/SHA-1).';
      case 'CANCELED':
        return 'Google sign-in was cancelled.';
      case 'NEEDS_UI':
        return 'Google needs you to sign in again. Open Backup & Sync and tap Connect Google Account.';
      case 'NETWORK':
        return 'No internet connection.';
    }
    return msg ?? 'Google sign-in failed';
  }

  @override
  Future<void> clearToken(String token) async {
    try {
      await _ch.invokeMethod('clearToken', {'token': token});
    } catch (_) {}
  }

  @override
  Future<Map<String, String>> signingInfo() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('signingInfo');
      return {'packageName': '${r?['packageName'] ?? ''}', 'sha1': '${r?['sha1'] ?? ''}'};
    } catch (_) {
      return {'packageName': '', 'sha1': ''};
    }
  }
}
