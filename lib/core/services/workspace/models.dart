import 'dart:io';

/// Workspace runtime status, mirroring rikkahub's WorkspaceShellStatus.
enum WorkspaceShellStatus { disabled, installing, ready, broken }

/// Storage area inside a workspace root.
enum WorkspaceStorageArea { files, linux }

/// Rootfs installation stages reported by [WorkspaceRootfsInstaller].
enum WorkspaceRootfsInstallStage { downloading, extracting, installed }

/// Progress payload emitted during a rootfs install.
class WorkspaceRootfsInstallProgress {
  const WorkspaceRootfsInstallProgress({
    required this.stage,
    this.bytesRead = 0,
    this.totalBytes,
    this.entriesExtracted = 0,
    this.currentEntry,
    this.error,
  });

  final WorkspaceRootfsInstallStage stage;
  final int bytesRead;
  final int? totalBytes;
  final int entriesExtracted;
  final String? currentEntry;
  final String? error;
}

/// A single workspace aggregate. Mirrors rikkahub's Workspace data class.
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.root,
    this.shellStatus = WorkspaceShellStatus.disabled,
    required this.createdAt,
    required this.updatedAt,
    this.lastAccessAt,
  });

  final String id;
  final String name;

  /// Directory name under the workspace base directory; [WorkspaceManager]
  /// validates it against [WorkspaceManager.rootNamePattern].
  final String root;
  final WorkspaceShellStatus shellStatus;
  final int createdAt;
  final int updatedAt;
  final int? lastAccessAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'root': root,
        'shellStatus': shellStatus.name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (lastAccessAt != null) 'lastAccessAt': lastAccessAt,
      };

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        id: json['id'] as String,
        name: json['name'] as String,
        root: json['root'] as String,
        shellStatus: WorkspaceShellStatus.values.firstWhere(
          (s) => s.name == json['shellStatus'],
          orElse: () => WorkspaceShellStatus.disabled,
        ),
        createdAt: json['createdAt'] as int? ?? 0,
        updatedAt: json['updatedAt'] as int? ?? 0,
        lastAccessAt: json['lastAccessAt'] as int?,
      );
}

/// Limits applied to file operations. Mirrors rikkahub's WorkspaceConfig.
class WorkspaceConfig {
  const WorkspaceConfig({
    this.maxReadBytes = 512 * 1024,
    this.maxWriteBytes = 2 * 1024 * 1024,
    this.maxListEntries = 500,
    this.maxSearchResults = 100,
  });

  final int maxReadBytes;
  final int maxWriteBytes;
  final int maxListEntries;
  final int maxSearchResults;
}

/// Metadata for one file inside a workspace.
class WorkspaceFileEntry {
  const WorkspaceFileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.sizeBytes,
    required this.updatedAt,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int sizeBytes;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'isDirectory': isDirectory,
    'sizeBytes': sizeBytes,
    'updatedAt': updatedAt,
  };
}

/// One grep hit.
class WorkspaceSearchMatch {
  const WorkspaceSearchMatch({
    required this.path,
    required this.line,
    required this.text,
  });

  final String path;
  final int line;
  final String text;

  Map<String, dynamic> toJson() =>
      {'path': path, 'line': line, 'text': text};
}

/// Result of a workspace command execution.
class WorkspaceCommandResult {
  const WorkspaceCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.truncated = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool truncated;

  Map<String, dynamic> toJson() => {
    'exitCode': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'timedOut': timedOut,
    if (truncated) 'truncated': true,
  };
}

/// Where a rootfs-absolute path physically lands on the host filesystem.
class WorkspaceRootfsLocation {
  const WorkspaceRootfsLocation({
    required this.rootDir,
    required this.relativePath,
  });

  final Directory rootDir;
  final String relativePath;
}

/// Bind mount projected into the rootfs at [target].
class WorkspaceBindMount {
  WorkspaceBindMount({required this.source, required this.target})
      : assert(target.startsWith('/'), 'target must be absolute');

  final Directory source;
  final String target;
}

/// Contract for executing a command inside a workspace.
abstract interface class WorkspaceShellRunner {
  Future<WorkspaceCommandResult> execute(
    WorkspaceShellContext context,
  );
}

/// Everything a [WorkspaceShellRunner] needs to run one command.
class WorkspaceShellContext {
  const WorkspaceShellContext({
    required this.root,
    required this.command,
    required this.cwd,
    required this.filesDir,
    required this.linuxDir,
    required this.tempDir,
    required this.workingDir,
    required this.timeoutMillis,
    this.stdin,
    this.bindMounts = const [],
  });

  final String root;
  final String command;
  final String cwd;
  final Directory filesDir;
  final Directory linuxDir;
  final Directory tempDir;
  final Directory workingDir;
  final int timeoutMillis;
  final List<int>? stdin;
  final List<WorkspaceBindMount> bindMounts;
}

/// Thrown for user-facing workspace errors (bad paths, missing rootfs...).
class WorkspaceException implements Exception {
  WorkspaceException(this.message);

  final String message;

  @override
  String toString() => message;
}
