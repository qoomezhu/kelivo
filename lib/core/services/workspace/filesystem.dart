import 'dart:io';

import 'models.dart';

/// Pure-Dart port of rikkahub's WorkspaceFileSystem.
///
/// All operations are confined to the workspace root: every path is
/// normalized and rejected when it would escape the root (zip-slip safe).
class WorkspaceFileSystem {
  WorkspaceFileSystem({this.config = const WorkspaceConfig()});

  final WorkspaceConfig config;

  static const String _link2symlinkPrefix = '.l2s.';

  List<WorkspaceFileEntry> list(Directory root, [String path = '']) {
    final dir = _resolveDir(root, path);
    if (!dir.existsSync()) {
      throw WorkspaceException('Path does not exist: $path');
    }
    final entities = dir.listSync(followLinks: false)
        .where((e) => !_isHiddenArtifact(e))
        .toList()
      ..sort((a, b) {
        final aDir = _isDirectory(a);
        final bDir = _isDirectory(b);
        if (aDir != bDir) return aDir ? -1 : 1;
        return _baseName(a).toLowerCase().compareTo(_baseName(b).toLowerCase());
      });
    return entities
        .take(config.maxListEntries)
        .map((e) => _toEntry(e, root))
        .toList();
  }

  String readText(Directory root, String path) {
    final file = _resolveFile(root, path);
    if (!file.existsSync()) {
      throw WorkspaceException('File does not exist: $path');
    }
    final length = file.lengthSync();
    if (length > config.maxReadBytes) {
      throw WorkspaceException('File is too large to read: $length bytes');
    }
    return file.readAsStringSync();
  }

  WorkspaceFileEntry writeText(
    Directory root,
    String path,
    String text, {
    bool overwrite = true,
  }) {
    final bytes = text.codeUnits;
    if (bytes.length > config.maxWriteBytes) {
      throw WorkspaceException(
          'Content is too large to write: ${bytes.length} bytes');
    }
    final file = _resolveFile(root, path);
    final exists = file.existsSync();
    if (exists && !overwrite) {
      throw WorkspaceException('File already exists: $path');
    }
    if (exists && _isDirectory(file)) {
      throw WorkspaceException('Path is not a file: $path');
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text, flush: true);
    return _toEntry(file, root);
  }

  WorkspaceFileEntry importBytes(
      Directory root, String path, List<int> bytes) {
    var file = _resolveFile(root, path);
    file.parent.createSync(recursive: true);
    if (file.existsSync()) {
      file = _resolveConflict(file);
    }
    file.writeAsBytesSync(bytes, flush: true);
    return _toEntry(file, root);
  }

  bool delete(Directory root, String path, {bool recursive = false}) {
    if (path.trim().isEmpty || path.trim() == '.') {
      throw WorkspaceException('Refusing to delete workspace root');
    }
    final entity = _resolve(root, path);
    if (!entity.existsSync()) return false;
    if (_isDirectory(entity)) {
      if (!recursive) {
        throw WorkspaceException('Directory delete requires recursive = true');
      }
      (entity as Directory).deleteSync(recursive: true);
      return true;
    }
    entity.deleteSync();
    return true;
  }

  WorkspaceFileEntry move(
    Directory root,
    String source,
    String target, {
    bool overwrite = false,
  }) {
    if (source.trim().isEmpty || source.trim() == '.') {
      throw WorkspaceException('Refusing to move workspace root');
    }
    final sourceEntity = _resolve(root, source);
    final targetEntity = _resolve(root, target);
    if (!sourceEntity.existsSync()) {
      throw WorkspaceException('Source does not exist: $source');
    }
    if (targetEntity.existsSync()) {
      if (!overwrite) {
        throw WorkspaceException('Target already exists: $target');
      }
      if (_isDirectory(targetEntity)) {
        (targetEntity as Directory).deleteSync(recursive: true);
      } else {
        targetEntity.deleteSync();
      }
    }
    if (targetEntity is Directory) {
      targetEntity.createSync(recursive: true);
    } else {
      (targetEntity as File).parent.createSync(recursive: true);
    }
    try {
      sourceEntity.renameSync(targetEntity.path);
    } on FileSystemException catch (e) {
      // Cross-device or platform rename failure: fall back to copy+delete.
      if (_isDirectory(sourceEntity)) {
        _copyDirectorySync(
            sourceEntity as Directory, Directory(targetEntity.path));
        sourceEntity.deleteSync(recursive: true);
      } else {
        File(targetEntity.path)
            .writeAsBytesSync((sourceEntity as File).readAsBytesSync(),
                flush: true);
        sourceEntity.deleteSync();
      }
      if (!targetEntity.existsSync()) {
        throw WorkspaceException(
            'Failed to move $source to $target: $e');
      }
    }
    return _toEntry(_resolve(root, target), root);
  }

  List<WorkspaceFileEntry> glob(
      Directory root, String pattern, String path) {
    if (pattern.trim().isEmpty) {
      throw WorkspaceException('Glob pattern is required');
    }
    final start = _resolve(root, path);
    if (!start.existsSync()) {
      throw WorkspaceException('Path does not exist: $path');
    }
    final matcher = _GlobMatcher(pattern);
    final results = <WorkspaceFileEntry>[];
    // The walk starts at the given subdirectory; relative paths for matching
    // must therefore be computed against that start dir, not the root.
    final startPath = _normalize(start.absolute.path);
    _walk(start, (entity) {
      if (results.length >= config.maxListEntries) return false;
      if (_isHiddenArtifact(entity)) return true;
      var rel = _normalize(entity.path);
      if (rel.startsWith('$startPath/')) {
        rel = rel.substring(startPath.length + 1);
      } else if (rel == startPath) {
        rel = '';
      }
      if (rel.isNotEmpty && matcher.matches(rel)) {
        results.add(_toEntry(entity, root));
      }
      return true;
    });
    return results;
  }

  List<WorkspaceSearchMatch> grep(
    Directory root,
    String query, {
    String path = '',
    bool regex = false,
    bool ignoreCase = true,
    String? includeGlob,
  }) {
    if (query.trim().isEmpty) {
      throw WorkspaceException('Search query is required');
    }
    final start = _resolve(root, path);
    if (!start.existsSync()) {
      throw WorkspaceException('Path does not exist: $path');
    }
    final pattern = regex
        ? RegExp(query, caseSensitive: !ignoreCase)
        : RegExp(RegExp.escape(query), caseSensitive: !ignoreCase);
    final includeMatcher = (includeGlob == null || includeGlob.trim().isEmpty)
        ? null
        : _GlobMatcher(includeGlob);
    final results = <WorkspaceSearchMatch>[];

    _walk(start, (entity) {
      if (results.length >= config.maxSearchResults) return false;
      if (_isHiddenArtifact(entity)) return true;
      if (!_isRegularFile(entity)) return true;
      final file = entity as File;
      if (file.lengthSync() > config.maxReadBytes) return true;
      if (includeMatcher != null &&
          !includeMatcher.matches(_relativeTo(file, root))) {
        return true;
      }
      final lines = _readLinesSafe(file);
      for (var i = 0; i < lines.length; i++) {
        if (results.length >= config.maxSearchResults) break;
        if (pattern.hasMatch(lines[i])) {
          results.add(WorkspaceSearchMatch(
            path: _relativeTo(file, root),
            line: i + 1,
            text: lines[i],
          ));
        }
      }
      return true;
    });
    return results;
  }

  /// Resolve [path] against [root], rejecting traversal outside the root.
  FileSystemEntity resolve(Directory root, String path) => _resolve(root, path);

  FileSystemEntity _resolve(Directory root, String path) {
    final normalized = _sanitize(path);
    root.createSync(recursive: true);
    if (normalized.isEmpty || normalized == '.') {
      return Directory(_normalize(root.absolute.path));
    }
    final rootPath = _normalize(root.absolute.path);
    final candidate = _normalize('${root.absolute.path}/$normalized');
    if (candidate != rootPath && !candidate.startsWith('$rootPath/')) {
      throw WorkspaceException('Path escapes workspace root: $path');
    }
    // A trailing slash means "directory". Otherwise check what actually
    // exists on disk so list/delete/glob see directories as directories.
    final looksLikeDir = path.trimRight().endsWith('/');
    if (looksLikeDir) return Directory(candidate);
    final f = File(candidate);
    if (!f.existsSync()) return Directory(candidate);
    return f;
  }

  Directory _resolveDir(Directory root, String path) {
    final e = _resolve(root, path);
    if (e.existsSync() && _isDirectory(e)) return e as Directory;
    // Even when missing, callers want a Directory handle to create.
    return Directory(e.path);
  }

  File _resolveFile(Directory root, String path) {
    // Try File first: new files must resolve as File even though they do
    // not exist yet. Only fail when a directory actually occupies the path.
    final normalized = _sanitize(path);
    root.createSync(recursive: true);
    final rootPath = _normalize(root.absolute.path);
    final candidate = _normalize('${root.absolute.path}/$normalized');
    if (candidate != rootPath && !candidate.startsWith('$rootPath/')) {
      throw WorkspaceException('Path escapes workspace root: $path');
    }
    final f = File(candidate);
    if (Directory(candidate).existsSync() &&
        Directory(candidate).statSync().type == FileSystemEntityType.directory) {
      throw WorkspaceException('Path is not a file: $path');
    }
    return f;
  }

  String _sanitize(String path) {
    final normalized = path
        .replaceAll('\\', '/')
        .trim()
        .replaceAll(RegExp(r'^/+'), '');
    if (normalized.contains('\u0000')) {
      throw WorkspaceException('Path contains invalid character');
    }
    return normalized;
  }

  String _normalize(String path) {
    final parts = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return '/${parts.join('/')}';
  }

  bool _isDirectory(FileSystemEntity e) =>
      e.statSync().type == FileSystemEntityType.directory;

  bool _isRegularFile(FileSystemEntity e) =>
      e.statSync().type == FileSystemEntityType.file;

  bool _isHiddenArtifact(FileSystemEntity e) =>
      _baseName(e).startsWith(_link2symlinkPrefix);

  String _baseName(FileSystemEntity e) => e.path.split('/').last;

  String _relativeTo(FileSystemEntity e, Directory root) {
    final rootPath = _normalize(root.absolute.path);
    var p = _normalize(e.path);
    if (p.startsWith('$rootPath/')) p = p.substring(rootPath.length + 1);
    return p;
  }

  WorkspaceFileEntry _toEntry(FileSystemEntity e, Directory root) {
    final stat = e.statSync();
    final isDir = stat.type == FileSystemEntityType.directory;
    return WorkspaceFileEntry(
      path: _relativeTo(e, root),
      name: _baseName(e),
      isDirectory: isDir,
      sizeBytes: isDir ? 0 : stat.size,
      updatedAt: stat.modified.millisecondsSinceEpoch,
    );
  }

  File _resolveConflict(File file) {
    final name = _baseName(file);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    final parent = file.parent;
    var n = 1;
    var candidate = File('${parent.path}/$stem ($n)$ext');
    while (candidate.existsSync()) {
      n++;
      candidate = File('${parent.path}/$stem ($n)$ext');
    }
    return candidate;
  }

  List<String> _readLinesSafe(File file) {
    try {
      return file.readAsStringSync().split('\n');
    } on FileSystemException {
      // Binary file or decoding error: treat as no matches.
      return const <String>[];
    }
  }

  void _copyDirectorySync(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final e in src.listSync(followLinks: false)) {
      final target = '${dst.path}/${_baseName(e)}';
      if (e is Directory) {
        _copyDirectorySync(e, Directory(target));
      } else if (e is File) {
        File(target).writeAsBytesSync(e.readAsBytesSync(), flush: true);
      } else if (e is Link) {
        try {
          Link(target).createSync(e.targetSync());
        } on FileSystemException {
          // ignore
        }
      }
    }
  }

  /// Walk with an early-exit predicate. Directories are traversed after
  /// being visited so callers can prune.
  void _walk(FileSystemEntity start, bool Function(FileSystemEntity) visit) {
    if (!start.existsSync()) return;
    final stack = <FileSystemEntity>[start];
    while (stack.isNotEmpty) {
      final e = stack.removeLast();
      if (!visit(e)) return;
      if (_isDirectory(e)) {
        try {
          stack.addAll((e as Directory).listSync(followLinks: false));
        } on FileSystemException {
          // Unreadable directory: skip it.
        }
      }
    }
  }
}

/// Minimal glob matcher supporting `*`, `?`, `**` and character classes.
class _GlobMatcher {
  _GlobMatcher(String pattern) : _regex = _compile(pattern);

  final RegExp _regex;

  bool matches(String path) => _regex.hasMatch(path);

  static RegExp _compile(String pattern) {
    final buf = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      switch (c) {
        case '*':
          if (i + 1 < pattern.length && pattern[i + 1] == '*') {
            buf.write('.*');
            i += 2;
            // An optional following slash so `**/x` also matches `x`.
            if (i < pattern.length && pattern[i] == '/') i++;
            continue;
          }
          buf.write('[^/]*');
        case '?':
          buf.write('[^/]');
        case '[':
          final end = pattern.indexOf(']', i + 1);
          if (end < 0) {
            buf.write(RegExp.escape(c));
          } else {
            buf.write(pattern.substring(i, end + 1));
            i = end;
          }
        case _:
          buf.write(RegExp.escape(c));
      }
      i++;
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }
}
