import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'filesystem.dart';
import 'rootfs_installer.dart';
import 'models.dart';

/// Port of rikkahub's WorkspaceManager.
///
/// Layout per workspace root:
///   <baseDir>/<root>/files  — the user-visible files area (mounted at
///                             /workspace inside the rootfs)
///   <baseDir>/<root>/linux  — the extracted Linux rootfs
///   <baseDir>/<root>/tmp    — scratch dir shared with the runner
class WorkspaceManager implements WorkspaceManagerLike {
  WorkspaceManager({
    required this.baseDir,
    this.config = const WorkspaceConfig(),
    WorkspaceShellRunner? shellRunner,
    this.bindMounts = const [],
  })  : _shellRunner = shellRunner ?? HostShellRunner(),
        fileSystem = WorkspaceFileSystem() {
    baseDir.createSync(recursive: true);
  }

  final Directory baseDir;
  final WorkspaceConfig config;
  final WorkspaceFileSystem fileSystem;
  final WorkspaceShellRunner _shellRunner;
  final List<WorkspaceBindMount> bindMounts;

  /// Bind mounts sorted by target length so `/a/b` wins over `/a`.
  late final List<WorkspaceBindMount> sortedBindMounts = List.of(bindMounts)
    ..sort((a, b) => b.target.trimRight().length
        .compareTo(a.target.trimRight().length));

  static const int defaultCommandTimeoutMs = 30000;

  /// Mount point of the files area inside the rootfs.
  static const String rootfsWorkspaceDir = '/workspace';

  /// Kernel pseudo filesystems: only reachable via shell, never as files.
  static const List<String> kernelFsMounts = ['/dev', '/proc', '/sys'];

  static final RegExp rootNamePattern = RegExp(r'[A-Za-z0-9._-]+');

  Directory ensureWorkspace(String root) {
    final dir = workspaceDir(root);
    for (final d in [filesDir(root), linuxDir(root), tempDir(root)]) {
      d.createSync(recursive: true);
    }
    return dir;
  }

  Directory workspaceDir(String root) {
    _requireValidRoot(root);
    return Directory('${baseDir.path}/$root');
  }

  Directory filesDir(String root) =>
      Directory('${workspaceDir(root).path}/$_filesDirName');

  Directory linuxDir(String root) =>
      Directory('${workspaceDir(root).path}/$_linuxDirName');

  Directory tempDir(String root) =>
      Directory('${workspaceDir(root).path}/$_tempDirName');

  bool hasRootfs(String root) =>
      File('${linuxDir(root).path}/bin/sh').existsSync();

  bool deleteWorkspace(String root) {
    final dir = workspaceDir(root);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      return true;
    }
    return false;
  }

  List<WorkspaceFileEntry> listFiles(
    String root, {
    String path = '',
    WorkspaceStorageArea area = WorkspaceStorageArea.files,
  }) =>
      fileSystem.list(_areaDir(root, area), path);

  String readText(String root, String path) =>
      fileSystem.readText(filesDir(root), path);

  WorkspaceFileEntry writeText(
    String root,
    String path,
    String text, {
    bool overwrite = true,
  }) =>
      fileSystem.writeText(filesDir(root), path, text, overwrite: overwrite);

  WorkspaceFileEntry importFile(
    String root,
    String destinationPath,
    String fileName,
    List<int> bytes, {
    WorkspaceStorageArea area = WorkspaceStorageArea.files,
  }) {
    final areaRoot = _areaDir(root, area);
    final targetPath = destinationPath.trim().isEmpty
        ? fileName
        : '$destinationPath/$fileName';
    return fileSystem.importBytes(areaRoot, targetPath, bytes);
  }

  int fileSize(
    String root,
    String path, {
    WorkspaceStorageArea area = WorkspaceStorageArea.files,
  }) {
    final f = fileSystem.resolve(_areaDir(root, area), path);
    if (!f.existsSync()) {
      throw WorkspaceException('File does not exist: $path');
    }
    if (f.statSync().type != FileSystemEntityType.file) {
      throw WorkspaceException('Path is not a file: $path');
    }
    return (f as File).lengthSync();
  }

  List<int> exportFile(
    String root,
    String path, {
    WorkspaceStorageArea area = WorkspaceStorageArea.files,
  }) {
    final f = fileSystem.resolve(_areaDir(root, area), path);
    if (f is! File || !f.existsSync()) {
      throw WorkspaceException('File does not exist: $path');
    }
    return f.readAsBytesSync();
  }

  bool deleteFile(
    String root,
    String path, {
    bool recursive = false,
    WorkspaceStorageArea area = WorkspaceStorageArea.files,
  }) =>
      fileSystem.delete(_areaDir(root, area), path, recursive: recursive);

  WorkspaceFileEntry moveFile(
    String root,
    String source,
    String target, {
    bool overwrite = false,
  }) =>
      fileSystem.move(filesDir(root), source, target, overwrite: overwrite);

  List<WorkspaceFileEntry> glob(String root, String pattern,
          [String path = '']) =>
      fileSystem.glob(filesDir(root), pattern, path);

  List<WorkspaceSearchMatch> grep(
    String root,
    String query, {
    String path = '',
    bool regex = false,
    bool ignoreCase = true,
    String? includeGlob,
  }) =>
      fileSystem.grep(
        filesDir(root),
        query,
        path: path,
        regex: regex,
        ignoreCase: ignoreCase,
        includeGlob: includeGlob,
      );

  /// Map a rootfs-absolute path to its host filesystem location.
  ///
  /// Bind-mount sources are host directories, so `/skills`-style targets
  /// resolve to the source without going through the runner. The files area
  /// maps to [filesDir]. Kernel pseudo filesystems are rejected.
  WorkspaceRootfsLocation resolveRootfsPath(String root, String path) {
    final trimmed = path.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) {
      return WorkspaceRootfsLocation(
        rootDir: filesDir(root),
        relativePath: '',
      );
    }
    if (!trimmed.startsWith('/')) {
      throw WorkspaceException('Rootfs path must be absolute: $path');
    }

    for (final mount in sortedBindMounts) {
      final target = mount.target.trimRight();
      if (trimmed == target) {
        return WorkspaceRootfsLocation(
          rootDir: mount.source,
          relativePath: '',
        );
      }
      if (trimmed.startsWith('$target/')) {
        return WorkspaceRootfsLocation(
          rootDir: mount.source,
          relativePath: trimmed.substring(target.length + 1),
        );
      }
    }

    if (trimmed == rootfsWorkspaceDir ||
        trimmed.startsWith('$rootfsWorkspaceDir/')) {
      return WorkspaceRootfsLocation(
        rootDir: filesDir(root),
        relativePath: trimmed
            .substring(rootfsWorkspaceDir.length)
            .replaceFirst(RegExp(r'^/+'), ''),
      );
    }

    for (final fs in kernelFsMounts) {
      if (trimmed == fs || trimmed.startsWith('$fs/')) {
        throw WorkspaceException(
          '$fs is a kernel filesystem and cannot be read as a file, '
          'use workspace_shell instead',
        );
      }
    }

    return WorkspaceRootfsLocation(
      rootDir: linuxDir(root),
      relativePath: trimmed.replaceFirst(RegExp(r'^/+'), ''),
    );
  }

  int rootfsFileSize(String root, String path) {
    final f = _resolveRootfsFile(root, path);
    if (f is! File || !f.existsSync()) {
      throw WorkspaceException('File does not exist: $path');
    }
    return f.lengthSync();
  }

  List<int> exportRootfsFile(String root, String path) {
    final f = _resolveRootfsFile(root, path);
    if (f is! File || !f.existsSync()) {
      throw WorkspaceException('File does not exist: $path');
    }
    return f.readAsBytesSync();
  }

  String readRootfsText(String root, String path) =>
      String.fromCharCodes(exportRootfsFile(root, path));

  FileSystemEntity _resolveRootfsFile(String root, String path) {
    final loc = resolveRootfsPath(root, path);
    return fileSystem.resolve(loc.rootDir, loc.relativePath);
  }

  Future<WorkspaceCommandResult> executeCommand(
    String root,
    String command, {
    String cwd = '',
    int timeoutMillis = defaultCommandTimeoutMs,
    List<int>? stdin,
  }) async {
    if (command.trim().isEmpty) {
      throw WorkspaceException('Command is required');
    }
    final workingDir = fileSystem.resolve(filesDir(root), cwd);
    if (!workingDir.existsSync()) {
      throw WorkspaceException('Working directory does not exist: $cwd');
    }
    if (workingDir.statSync().type != FileSystemEntityType.directory) {
      throw WorkspaceException('Working path is not a directory: $cwd');
    }

    return _shellRunner.execute(WorkspaceShellContext(
      root: root,
      command: command,
      cwd: cwd,
      filesDir: filesDir(root),
      linuxDir: linuxDir(root),
      tempDir: tempDir(root),
      workingDir: Directory(workingDir.absolute.path),
      timeoutMillis: timeoutMillis,
      stdin: stdin,
      bindMounts: bindMounts,
    ));
  }

  /// Remove scratch dirs for every workspace root.
  void cleanupAllTempDirs() {
    if (!baseDir.existsSync()) return;
    for (final dir in baseDir.listSync().whereType<Directory>()) {
      final root = dir.path.split('/').last;
      if (!rootNamePattern.hasMatch(root) ||
          rootNamePattern.matchAsPrefix(root)?.end != root.length) {
        continue;
      }
      final tmp = tempDir(root);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      final rootfsTmp = Directory('${linuxDir(root).path}/tmp');
      if (rootfsTmp.existsSync()) rootfsTmp.deleteSync(recursive: true);
      final rootfsVarTmp = Directory('${linuxDir(root).path}/var/tmp');
      if (rootfsVarTmp.existsSync()) rootfsVarTmp.deleteSync(recursive: true);
    }
  }

  void _requireValidRoot(String root) {
    final match = rootNamePattern.firstMatch(root);
    if (root.isEmpty || match == null || match.end != root.length) {
      throw WorkspaceException('Invalid workspace root name: $root');
    }
  }

  Directory _areaDir(String root, WorkspaceStorageArea area) => switch (area) {
        WorkspaceStorageArea.files => filesDir(root),
        WorkspaceStorageArea.linux => linuxDir(root),
      };

  static const String _filesDirName = 'files';
  static const String _linuxDirName = 'linux';
  static const String _tempDirName = 'tmp';
}

/// Fallback runner executing on the host OS shell (no rootfs).
class HostShellRunner implements WorkspaceShellRunner {
  @override
  Future<WorkspaceCommandResult> execute(WorkspaceShellContext context) async {
    final shell = Platform.isWindows ? 'cmd /c' : '/bin/sh';
    final args = Platform.isWindows
        ? <String>[shell, context.command]
        : <String>[shell, '-c', context.command];
    return ProcessRunner.run(
      args.first,
      args.skip(1).toList(),
      workingDirectory: context.workingDir.path,
      timeoutMillis: context.timeoutMillis,
      stdinBytes: context.stdin,
    );
  }
}

/// Generic process runner with timeout and output truncation.
///
/// Port of rikkahub's Process.readResult helper.
class ProcessRunner {
  static const int maxOutputChars = 128 * 1024;

  static Future<WorkspaceCommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int timeoutMillis = WorkspaceManager.defaultCommandTimeoutMs,
    List<int>? stdinBytes,
  }) async {
    Process? process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } catch (e) {
      return WorkspaceCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'Failed to start process: $e',
      );
    }

    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .fold<StringBuffer>(StringBuffer(), (buf, chunk) {
      _appendClamped(buf, chunk, maxOutputChars);
      return buf;
    }).then((buf) => buf.toString());
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .fold<StringBuffer>(StringBuffer(), (buf, chunk) {
      _appendClamped(buf, chunk, maxOutputChars);
      return buf;
    }).then((buf) => buf.toString());

    if (stdinBytes != null && stdinBytes.isNotEmpty) {
      process.stdin.add(stdinBytes);
      await process.stdin.flush();
    }
    await process.stdin.close();

    var timedOut = false;
    int exitCode;
    try {
      exitCode = await process.exitCode
          .timeout(Duration(milliseconds: timeoutMillis));
    } on TimeoutException {
      timedOut = true;
      exitCode = -1;
      process.kill(ProcessSignal.sigkill);
    }

    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;
    return WorkspaceCommandResult(
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      timedOut: timedOut,
    );
  }

  static void _appendClamped(StringBuffer buf, String chunk, int maxChars) {
    if (buf.length + chunk.length <= maxChars) {
      buf.write(chunk);
      return;
    }
    final remaining = maxChars - buf.length;
    if (remaining > 0) buf.write(chunk.substring(0, remaining));
  }
}
