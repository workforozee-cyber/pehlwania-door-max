// Pehlwania Door Max & Interior — Android app.
// The existing POS screens (assets/www/index.html, shared with the desktop
// version) run in a WebView; all data lives in SQLite on the phone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'backup/backup_service.dart';
import 'backup/drive_backup.dart';
import 'bridge.dart';
import 'data/app_database.dart';
import 'data/repository.dart';
import 'sync/google_auth.dart';
import 'sync/sync_service.dart';

/// CI-only: lets the automated Android emulator test drive the page through
/// Chrome DevTools. Never enabled in builds given to the shop.
const bool kWebViewDebug = bool.fromEnvironment('PDM_WEBVIEW_DEBUG');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kWebViewDebug) AndroidWebViewController.enableDebugging(true);
  runApp(const PehlwaniaApp());
}

class Services {
  final Repository repo;
  final BackupService backups;
  final SyncService sync;
  final DriveBackup drive;
  Services(this.repo, this.backups, this.sync, this.drive);

  static Future<Services> start() async {
    final dir = await getDatabasesPath();
    final db = await AppDatabase.open(databaseFactory, p.join(dir, AppDatabase.fileName));
    final repo = Repository(db);
    final backups = BackupService(repo, safetyDir: getApplicationDocumentsDirectory);
    final connectivity = Connectivity();
    final sync = SyncService(repo, AndroidGoogleAuth(),
        httpClient: http.Client.new,
        isOnline: () async => !(await connectivity.checkConnectivity()).contains(ConnectivityResult.none));
    await sync.init();
    return Services(repo, backups, sync, DriveBackup(repo, backups, sync));
  }
}

class PehlwaniaApp extends StatelessWidget {
  const PehlwaniaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pehlwania POS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1E3157), useMaterial3: true),
        home: const StartupScreen(),
      );
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});
  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  late Future<Services> _f = Services.start();

  @override
  Widget build(BuildContext context) => FutureBuilder<Services>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return _DatabaseErrorScreen(error: snap.error!, onRetry: () => setState(() => _f = Services.start()));
          if (!snap.hasData) {
            return const Scaffold(backgroundColor: Color(0xFF12203C), body: Center(child: CircularProgressIndicator()));
          }
          return PosScreen(services: snap.data!);
        },
      );
}

/// Shown if the database cannot be opened/upgraded. Nothing is deleted.
class _DatabaseErrorScreen extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _DatabaseErrorScreen({required this.error, required this.onRetry});

  Future<void> _exportRawDb(BuildContext context) async {
    try {
      final path = p.join(await getDatabasesPath(), AppDatabase.fileName);
      final bytes = await File(path).readAsBytes();
      final out = await FilePicker.platform.saveFile(
          dialogTitle: 'Save database copy', fileName: 'pehlwania_pos-database-copy.db', bytes: bytes);
      if (out != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Database copy saved')));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not copy: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Pehlwania POS')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('The database could not be opened', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('Your data has NOT been deleted. Please do not uninstall the app or clear its data. '
                'Save a copy of the database file below and contact support.'),
            const SizedBox(height: 12),
            Text('$error', style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => _exportRawDb(context), child: const Text('Save a copy of the database file')),
          ]),
        ),
      );
}

class PosScreen extends StatefulWidget {
  final Services services;
  const PosScreen({super.key, required this.services});
  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  late final WebViewController _web;
  late final Bridge _bridge;
  StreamSubscription<List<ConnectivityResult>>? _net;
  AppLifecycleListener? _life;
  bool _wasOffline = false;

  Services get s => widget.services;

  @override
  void initState() {
    super.initState();
    _web = WebViewController();
    _bridge = Bridge(repo: s.repo, backups: s.backups, sync: s.sync, drive: s.drive, runJs: (js) => _web.runJavaScript(js));
    s.sync.onStatus = (st) {
      _web.runJavaScript('window.PDM_onSyncStatus&&window.PDM_onSyncStatus(${jsonEncodeSafe(st)})');
    };
    _setupWebView();

    // automatic sync triggers: open, resume, connectivity restored (after local changes: see Bridge)
    _life = AppLifecycleListener(onResume: () => _syncQuietly());
    _net = Connectivity().onConnectivityChanged.listen((r) {
      final offline = r.contains(ConnectivityResult.none);
      if (_wasOffline && !offline) _syncQuietly();
      _wasOffline = offline;
    });
    Future.delayed(const Duration(seconds: 6), _syncQuietly);
  }

  void _syncQuietly() {
    if (s.sync.configured) unawaited(s.sync.syncNow().catchError((_) => <String, dynamic>{}));
  }

  Future<void> _setupWebView() async {
    await _web.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _web.setBackgroundColor(const Color(0xFF12203C));
    await _web.addJavaScriptChannel('PDMBridge', onMessageReceived: (m) => _bridge.handle(m.message));
    await _web.setNavigationDelegate(NavigationDelegate(onNavigationRequest: (req) {
      final u = Uri.tryParse(req.url);
      if (u != null && (u.scheme == 'file' || u.scheme == 'about' || u.scheme == 'data' || u.scheme == 'blob')) {
        return NavigationDecision.navigate;
      }
      if (u != null && u.scheme == 'https') unawaited(_bridge.dispatch('app.openUrl', {'url': req.url}).catchError((_) => null));
      return NavigationDecision.prevent;
    }));
    await _web.setOnJavaScriptAlertDialog((req) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          content: SingleChildScrollView(child: Text(req.message)),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    });
    await _web.setOnJavaScriptConfirmDialog((req) async {
      if (!mounted) return false;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          content: SingleChildScrollView(child: Text(req.message)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
          ],
        ),
      );
      return ok ?? false;
    });
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      await platform.setAllowFileAccess(true);
      // "Add Photo" in the Showcase: <input type=file accept=image/*>
      await platform.setOnShowFileSelector((params) async {
        final res = await FilePicker.platform.pickFiles(type: FileType.image);
        final path = res?.files.single.path;
        return path == null ? <String>[] : [Uri.file(path).toString()];
      });
    }
    await _web.loadFlutterAsset('assets/www/index.html');
  }

  Future<void> _onBack() async {
    Object? handled;
    try {
      handled = await _web.runJavaScriptReturningResult('window.PDM_onBack ? window.PDM_onBack() : false');
    } catch (_) {}
    if (handled == true || handled == 'true') return;
    if (!mounted) return;
    final exit = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: const Text('Close Pehlwania POS? Everything is already saved on this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Close')),
        ],
      ),
    );
    if (exit == true) await SystemNavigator.pop();
  }

  @override
  void dispose() {
    _net?.cancel();
    _life?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _onBack();
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF12203C),
          body: SafeArea(child: WebViewWidget(controller: _web)),
        ),
      );
}

String jsonEncodeSafe(Object? v) {
  try {
    return const JsonEncoder().convert(v);
  } catch (_) {
    return 'null';
  }
}
