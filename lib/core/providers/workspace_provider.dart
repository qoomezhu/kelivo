import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_directories.dart';
import '../services/workspace/filesystem.dart';
import '../services/workspace/manager.dart';
import '../services/workspace/models.dart';
import '../services/workspace/rootfs_installer.dart';

/// Change notification emitted by [WorkspaceProvider].
enum WorkspaceChangeType { created, deleted, renamed, statusChanged }

/// Riverpod-free workspace registry modeled on kelivo's ChangeNotifier
/// providers (see McpProvider / AssistantProvider).
///
/// Persistence uses SharedPreferences JSON, mirroring how kelivo stores
/// lightweight settings without a DB migration.
class WorkspaceProvider extends ChangeNotifier {
  WorkspaceProvider({String? prefsKey})
      : _prefsKey = prefsKey ?? 'kelivo.workspaces.v1';

  final String _prefsKey;
  final List<Workspace> _workspaces = [];
  bool _loaded = false;
  bool _initializing = false;
  String? _installError;

  WorkspaceManager? _manager;
  WorkspaceRootfsInstaller? _installer;

  List<Workspace> get workspaces =>
      List.unmodifiable(_workspaces);
  bool get loaded => _loaded;
  bool get initializing => _initializing;
  String? get installError => _installError;

  /// Base directory: <appData>/workspaces
  Future<WorkspaceManager> _ensureManager() async {
    if (_manager != null) return _manager!;
    final root = await AppDirectories.getAppDataDirectory();
    final base = Directory('${root.path}/workspaces');
    _manager = WorkspaceManager(baseDir: base);
    _installer = WorkspaceRootfsInstaller(manager: _manager!);
    return _manager!;
  }

  Future<void> load() async {
    if (_loaded || _initializing) return;
    _initializing = true;
    try {
      final manager = await _ensureManager();
      final raw = await _readPrefs();
      final decoded = (jsonDecode(raw) as List<dynamic>? ?? [])
          .map((e) => Workspace.fromJson(e as Map<String, dynamic>))
          .toList();
      _workspaces
        ..clear()
        ..addAll(decoded);
      // Sync persisted status with what is actually on disk.
      for (var i = 0; i < _workspaces.length; i++) {
        final ws = _workspaces[i];
        final hasRootfs = manager.hasRootfs(ws.root);
        final status = hasRootfs
            ? WorkspaceShellStatus.ready
            : ws.shellStatus == WorkspaceShellStatus.installing
                ? WorkspaceShellStatus.installing
                : WorkspaceShellStatus.disabled;
        if (status != ws.shellStatus) {
          _workspaces[i] = Workspace(
            id: ws.id,
            name: ws.name,
            root: ws.root,
            shellStatus: status,
            createdAt: ws.createdAt,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            lastAccessAt: ws.lastAccessAt,
          );
        }
      }
      _loaded = true;
      notifyListeners();
    } finally {
      _initializing = false;
    }
  }

  Future<String> _readPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefsKey) ?? '[]';
    } catch (_) {
      return '[]';
    }
  }

  Future<void> _writePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey,
          jsonEncode(_workspaces
              .map((w) => w.toJson())
              .toList(growable: false)));
    } catch (_) {
      // Persistence is best-effort; the on-disk layout remains the source
      // of truth for rootfs presence.
    }
  }

  /// Create a new workspace. Generates a unique root directory name.
  Future<Workspace> create(String name, {String? root}) async {
    await load();
    final manager = await _ensureManager();
    final safeRoot = root ??
        _sanitizeRoot(name) ??
        'ws${DateTime.now().millisecondsSinceEpoch}';
    if (_workspaces.any((w) => w.root == safeRoot)) {
      throw WorkspaceException('Workspace root already exists: $safeRoot');
    }
    manager.ensureWorkspace(safeRoot);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ws = Workspace(
      id: 'ws_${now}_${_workspaces.length}',
      name: name,
      root: safeRoot,
      shellStatus: WorkspaceShellStatus.disabled,
      createdAt: now,
      updatedAt: now,
    );
    _workspaces.add(ws);
    await _writePrefs();
    notifyListeners();
    return ws;
  }

  Future<void> delete(String id) async {
    await load();
    final manager = await _ensureManager();
    final idx = _workspaces.indexWhere((w) => w.id == id);
    if (idx < 0) return;
    final ws = _workspaces[idx];
    manager.deleteWorkspace(ws.root);
    _workspaces.removeAt(idx);
    await _writePrefs();
    notifyListeners();
  }

  Future<void> rename(String id, String newName) async {
    await load();
    final idx = _workspaces.indexWhere((w) => w.id == id);
    if (idx < 0) return;
    final ws = _workspaces[idx];
    _workspaces[idx] = Workspace(
      id: ws.id,
      name: newName,
      root: ws.root,
      shellStatus: ws.shellStatus,
      createdAt: ws.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      lastAccessAt: ws.lastAccessAt,
    );
    await _writePrefs();
    notifyListeners();
  }

  /// Download + install the Alpine rootfs into a workspace.
  Future<void> installRootfs(
    String id, {
    String url = WorkspaceRootfsInstaller.alpineAarch64Url,
    void Function(WorkspaceRootfsInstallProgress)? onProgress,
  }) async {
    await load();
    final idx = _workspaces.indexWhere((w) => w.id == id);
    if (idx < 0) throw WorkspaceException('Workspace not found: $id');
    final manager = await _ensureManager();
    final ws = _workspaces[idx];
    _setStatus(idx, WorkspaceShellStatus.installing);
    _installError = null;
    try {
      await _installer!.install(ws.root, url, onProgress: onProgress);
      _setStatus(idx,
          manager.hasRootfs(ws.root)
              ? WorkspaceShellStatus.ready
              : WorkspaceShellStatus.broken);
    } catch (e) {
      _installError = e.toString();
      _setStatus(idx, WorkspaceShellStatus.broken);
      rethrow;
    }
  }

  /// Remove the rootfs but keep the files area.
  Future<void> uninstallRootfs(String id) async {
    await load();
    final idx = _workspaces.indexWhere((w) => w.id == id);
    if (idx < 0) return;
    final manager = await _ensureManager();
    final ws = _workspaces[idx];
    final linux = manager.linuxDir(ws.root);
    if (linux.existsSync()) linux.deleteSync(recursive: true);
    _setStatus(idx, WorkspaceShellStatus.disabled);
  }

  void _setStatus(int idx, WorkspaceShellStatus status) {
    final ws = _workspaces[idx];
    _workspaces[idx] = Workspace(
      id: ws.id,
      name: ws.name,
      root: ws.root,
      shellStatus: status,
      createdAt: ws.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      lastAccessAt: ws.lastAccessAt,
    );
    notifyListeners();
    _writePrefs();
  }

  String? _sanitizeRoot(String name) {
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (cleaned.isEmpty || !WorkspaceManager.rootNamePattern
        .hasMatch(cleaned)) {
      return null;
    }
    return cleaned;
  }

  /// Shared manager access for tool dispatch and the workspace UI.
  Future<WorkspaceManager> manager() async {
    await load();
    return _ensureManager();
  }
}



