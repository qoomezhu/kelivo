import 'dart:convert';

import 'manager.dart';
import 'models.dart';

/// LLM tool definitions and dispatch, ported from rikkahub's WorkspaceTools.kt.
///
/// Four tools are exposed to the model:
///   workspace_read_file  — read a file inside the rootfs
///   workspace_write_file — write a UTF-8 text file
///   workspace_edit_file  — exact/anchored text replacement with diff
///   workspace_shell      — run a command inside the rootfs
///
/// All paths are rootfs-absolute; `/workspace` maps to the files area.
class WorkspaceTools {
  /// Build a tools dispatcher bound to one workspace root.
  WorkspaceTools.forRoot(this.root,
      {required this.manager, this.maxReadFileBytes = 8 * 1024 * 1024});

  final WorkspaceManager manager;
  final int maxReadFileBytes;

  /// Workspace root name this instance operates on.
  final String root;

  static const int shellTimeoutMaxSeconds = 600;

  static const Map<String, bool> defaultApprovals = {
    'workspace_read_file': false,
    'workspace_write_file': false,
    'workspace_edit_file': false,
    'workspace_shell': true,
  };

  static bool resolveToolApproval(
    String name,
    Map<String, bool> overrides,
  ) =>
      overrides[name] ?? defaultApprovals[name] ?? false;

  static const List<String> toolNames = [
    'workspace_read_file',
    'workspace_write_file',
    'workspace_edit_file',
    'workspace_shell',
  ];

  /// OpenAI-style tool schemas, matching kelivo's toolDef shape.
  static List<Map<String, dynamic>> toolDefinitions({String? cwd}) {
    final shellDesc = StringBuffer()
      ..write(
        'Run a shell command in the assistant\'s bound workspace Rootfs. '
        'The workspace files area is mounted at /workspace. '
        'Use cwd for a path relative to the workspace files root. ');
    if (cwd != null && cwd.trim().isNotEmpty) {
      shellDesc.write("Defaults to '$cwd'. ");
    }
    shellDesc.write('Requires Rootfs to be installed and ready.');

    return [
      {
        'type': 'function',
        'function': {
          'name': 'workspace_read_file',
          'description': 'Read a file using the assistant\'s bound workspace '
              'Rootfs. Paths must be absolute inside Rootfs. Use /workspace '
              'for the workspace files area. Supports UTF-8 text files.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'Absolute path inside the Rootfs',
              },
            },
            'required': ['path'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'workspace_write_file',
          'description': 'Write a UTF-8 text file using the assistant\'s '
              'bound workspace Rootfs. Paths must be absolute inside Rootfs. '
              'Use /workspace for the workspace files area.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'Absolute path inside the Rootfs',
              },
              'text': {
                'type': 'string',
                'description': 'UTF-8 text content to write',
              },
              'overwrite': {
                'type': 'boolean',
                'description':
                    'Whether to overwrite an existing file. Defaults to true.',
              },
            },
            'required': ['path', 'text'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'workspace_edit_file',
          'description': 'Edit a UTF-8 text file using the assistant\'s bound '
              'workspace Rootfs. Paths must be absolute inside Rootfs. Use '
              '/workspace for the workspace files area. Provide old_text and '
              'new_text. By default old_text must occur exactly once; set '
              'replace_all=true to replace every occurrence.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'Absolute path inside the Rootfs',
              },
              'old_text': {
                'type': 'string',
                'description': 'Exact text to replace',
              },
              'new_text': {
                'type': 'string',
                'description': 'Replacement text',
              },
              'replace_all': {
                'type': 'boolean',
                'description':
                    'Whether to replace every occurrence. Defaults to false.',
              },
            },
            'required': ['path', 'old_text', 'new_text'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'workspace_shell',
          'description': shellDesc.toString(),
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'description': 'Shell command to run',
              },
              'cwd': {
                'type': 'string',
                'description': cwd != null && cwd.trim().isNotEmpty
                    ? 'Working directory relative to the workspace files '
                        'root. Defaults to \'$cwd\'.'
                    : 'Working directory relative to the workspace files '
                        'root. Defaults to root.',
              },
              'timeout': {
                'type': 'integer',
                'description': 'Command timeout in seconds. Defaults to 30, '
                    'max $shellTimeoutMaxSeconds.',
              },
            },
            'required': ['command'],
          },
        },
      },
    ];
  }

  /// Dispatch one tool call. Returns the JSON payload kelivo persists as the
  /// tool result content, mirroring rikkahub's UIMessagePart.Text payloads.
  Future<String> handleToolCall(
    String name,
    Map<String, dynamic> args, {
    String? defaultCwd,
  }) async {
    switch (name) {
      case 'workspace_read_file':
        return _readFile(args);
      case 'workspace_write_file':
        return _writeFile(args);
      case 'workspace_edit_file':
        return _editFile(args);
      case 'workspace_shell':
        return _shell(args, defaultCwd);
      default:
        throw WorkspaceException('Unknown workspace tool: $name');
    }
  }

  String _absolutePath(Map<String, dynamic> args) {
    final raw = (args['path'] ?? '').toString().trim();
    if (raw.isEmpty) {
      throw WorkspaceException('path is required');
    }
    if (!raw.startsWith('/')) {
      throw WorkspaceException('path must be absolute inside the Rootfs: $raw');
    }
    return raw;
  }

  Future<String> _readFile(Map<String, dynamic> args) async {
    final path = _absolutePath(args);
    final size = manager.rootfsFileSize(root, path);
    if (size > maxReadFileBytes) {
      throw WorkspaceException(
        'File is too large to read: $path (${size ~/ 1024 ~/ 1024}MB, max '
        '${maxReadFileBytes ~/ 1024 ~/ 1024}MB). Use shell commands like '
        'head, tail, or grep to read parts of it.');
    }
    final text = manager.readRootfsText(root, path);
    return jsonEncode({'path': path, 'text': text});
  }

  Future<String> _writeFile(Map<String, dynamic> args) async {
    final path = _absolutePath(args);
    final text = args['text']?.toString();
    if (text == null) {
      throw WorkspaceException('text is required');
    }
    final overwrite = args['overwrite'] is bool
        ? args['overwrite'] as bool
        : (args['overwrite']?.toString() != 'false');
    final entry = manager.writeText(
      root,
      _toFilesRelative(path),
      text,
      overwrite: overwrite,
    );
    return jsonEncode(entry.toJson());
  }

  Future<String> _editFile(Map<String, dynamic> args) async {
    final path = _absolutePath(args);
    final oldText = args['old_text']?.toString();
    final newText = args['new_text']?.toString();
    if (oldText == null || oldText.isEmpty) {
      throw WorkspaceException('old_text must not be empty');
    }
    if (newText == null) {
      throw WorkspaceException('new_text is required');
    }
    final replaceAll = args['replace_all'] == true ||
        args['replace_all']?.toString() == 'true';

    final original = manager.readRootfsText(root, path);
    final result = WorkspaceTextReplacer.replace(
      original,
      oldText,
      newText,
      replaceAll,
    );
    manager.writeText(root, _toFilesRelative(path), result.updated,
        overwrite: true);

    return jsonEncode({
      'path': path,
      'replacements': result.replacements,
      if (result.strategy != 'exact') 'matchStrategy': result.strategy,
    });
  }

  Future<String> _shell(Map<String, dynamic> args, String? defaultCwd) async {
    final command = args['command']?.toString();
    if (command == null || command.trim().isEmpty) {
      throw WorkspaceException('command is required');
    }
    var cwd = (args['cwd']?.toString() ?? defaultCwd ?? '')
        .replaceAll('/workspace/', '')
        .replaceAll('/workspace', '');
    final timeoutSeconds = int.tryParse(args['timeout']?.toString() ?? '');
    final timeoutMillis = timeoutSeconds == null
        ? WorkspaceManager.defaultCommandTimeoutMs
        : (timeoutSeconds.clamp(1, shellTimeoutMaxSeconds)) * 1000;

    final result = await manager.executeCommand(
      root,
      command,
      cwd: cwd,
      timeoutMillis: timeoutMillis,
    );
    return jsonEncode(result.toJson());
  }

  /// `/workspace/foo` -> `foo` for the files-area APIs.
  String _toFilesRelative(String rootfsPath) {
    if (rootfsPath == '/workspace') return '';
    if (rootfsPath.startsWith('/workspace/')) {
      return rootfsPath.substring('/workspace/'.length);
    }
    return rootfsPath.replaceFirst(RegExp(r'^/+'), '');
  }
}



/// Text replacement strategies ported from rikkahub's TextReplacers.kt:
/// exact match -> whitespace-trimmed line match -> block anchor.
class WorkspaceTextReplacer {
  static _ReplaceResult replace(
    String original,
    String oldText,
    String newText,
    bool replaceAll,
  ) {
    final exact = _tryExact(original, oldText, newText, replaceAll, 'exact');
    if (exact != null) return exact;

    final lineTrimmed = _tryLineTrimmed(
        original, oldText, newText, replaceAll, 'line_trimmed');
    if (lineTrimmed != null) return lineTrimmed;

    final anchored = _tryBlockAnchor(
        original, oldText, newText, replaceAll, 'block_anchor');
    if (anchored != null) return anchored;

    throw WorkspaceException(
      'old_text not found in the target file '
      '(tried exact, line_trimmed and block_anchor matching)');
  }

  static _ReplaceResult? _tryExact(
    String original,
    String oldText,
    String newText,
    bool replaceAll,
    String strategy,
  ) {
    final count = _countOccurrences(original, oldText);
    if (count == 0) return null;
    if (!replaceAll && count > 1) {
      throw WorkspaceException(
        'old_text occurs $count times; provide more context or set '
        'replace_all=true');
    }
    final updated = replaceAll
        ? original.replaceAll(oldText, newText)
        : original.replaceFirst(oldText, newText);
    return _ReplaceResult(updated, replaceAll ? count : 1, strategy);
  }

  static _ReplaceResult? _tryLineTrimmed(
    String original,
    String oldText,
    String newText,
    bool replaceAll,
    String strategy,
  ) {
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');
    final fileLines = original.split('\n');

    var replaced = 0;
    final out = <String>[];
    var i = 0;
    while (i < fileLines.length) {
      if (_linesMatchTrimmed(fileLines, i, oldLines)) {
        out.addAll(newLines);
        i += oldLines.length;
        replaced++;
        if (!replaceAll) break;
      } else {
        out.add(fileLines[i]);
        i++;
      }
    }
    if (replaced == 0) return null;
    if (!replaceAll && replaced > 1) {
      throw WorkspaceException(
        'old_text matches $replaced blocks; provide more context or set '
        'replace_all=true');
    }
    return _ReplaceResult(out.join('\n'), replaced, strategy);
  }

  static _ReplaceResult? _tryBlockAnchor(
    String original,
    String oldText,
    String newText,
    bool replaceAll,
    String strategy,
  ) {
    // Anchor on the first and last non-empty lines of old_text.
    final oldLines =
        oldText.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (oldLines.length < 2) return null;
    final first = oldLines.first.trim();
    final last = oldLines.last.trim();

    final fileLines = original.split('\n');
    for (var start = 0; start < fileLines.length; start++) {
      if (fileLines[start].trim() != first) continue;
      for (var end = start + 1; end < fileLines.length; end++) {
        if (fileLines[end].trim() != last) continue;
        final block = fileLines.sublist(start, end + 1).join('\n');
        if (!_linesMatchTrimmed(block.split('\n'), 0, oldLines)) continue;
        final updated = [
          ...fileLines.sublist(0, start),
          ...newText.split('\n'),
          ...fileLines.sublist(end + 1),
        ].join('\n');
        return _ReplaceResult(updated, 1, strategy);
      }
    }
    return null;
  }

  static bool _linesMatchTrimmed(List<String> file, int offset, List<String> target) {
    if (offset + target.length > file.length) return false;
    for (var i = 0; i < target.length; i++) {
      if (file[offset + i].trim() != target[i].trim()) return false;
    }
    return true;
  }

  static int _countOccurrences(String haystack, String needle) {
    if (needle.isEmpty) return 0;
    var count = 0;
    var idx = haystack.indexOf(needle);
    while (idx >= 0) {
      count++;
      idx = haystack.indexOf(needle, idx + needle.length);
    }
    return count;
  }
}

class _ReplaceResult {
  const _ReplaceResult(this.updated, this.replacements, this.strategy);

  final String updated;
  final int replacements;
  final String strategy;
}
