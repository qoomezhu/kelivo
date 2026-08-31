import 'dart:io';

import 'package:archive/archive_io.dart' as archive;

import 'models.dart';
import 'patcher.dart';

/// Port of rikkahub's RootfsInstaller.
///
/// Downloads an Alpine (or compatible) rootfs tarball and extracts it into
/// the workspace's `linux/` directory, then applies [WorkspaceRootfsPatcher].
///
/// Extraction delegates to `archive_io.extractFileToDisk`, which handles
/// gzip/xz wrapping, GNU long names, PAX headers, symlinks, hardlinks and
/// path-traversal safety.
class WorkspaceRootfsInstaller {
  WorkspaceRootfsInstaller({
    required this.manager,
    this.patcher = const WorkspaceRootfsPatcher(),
    this.httpClientFactory,
  });

  final WorkspaceManagerLike manager;
  final WorkspaceRootfsPatcher patcher;

  /// Injectable so tests can serve tarballs without the network.
  final Future<WorkspaceRootfsDownload> Function(Uri url)? httpClientFactory;

  static const int _bufferSize = 64 * 1024;
  static const int _progressStepBytes = 512 * 1024;

  /// Default Alpine mini rootfs URLs per architecture.
  ///
  /// - Android: aarch64 (device arch, proot does no instruction translation)
  /// - iOS: x86_64 (iSH emulates x86; aarch64 binaries cannot run) — and the
  ///   root must be fakefs format, so prefer [ishRootUrl] there.
  /// - Desktop: host arch.
  static const String alpineAarch64Url =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/'
      'alpine-minirootfs-3.21.3-aarch64.tar.gz';

  static const String alpineX86_64Url =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/'
      'alpine-minirootfs-3.21.3-x86_64.tar.gz';

  /// iSH official App Store root (fakefs layout, x86 userspace).
  static const String ishRootUrl =
      'https://github.com/ish-app/roots/releases/download/'
      'g00712ff0a54b2839c5aa1a8ed758003ca65357dc/appstore-apk.tar.gz';

  /// Pick the default rootfs URL for the current platform.
  static String defaultRootfsUrl() {
    if (Platform.isIOS) return ishRootUrl;
    if (Platform.isAndroid) return alpineAarch64Url;
    if (Platform.isMacOS) return alpineX86_64Url;
    // Linux/Windows desktop: prefer host arch via an injectable override.
    return alpineX86_64Url;
  }

  Future<void> install(
    String root,
    String url, {
    void Function(WorkspaceRootfsInstallProgress)? onProgress,
  }) async {
    if (url.trim().isEmpty) {
      throw WorkspaceException('Rootfs download url is required');
    }
    manager.ensureWorkspace(root);
    final tempDir = manager.tempDir(root);
    final stagingDir = Directory('${tempDir.path}/rootfs-staging');
    final linuxDir = manager.linuxDir(root);

    try {
      if (stagingDir.existsSync()) {
        stagingDir.deleteSync(recursive: true);
      }
      stagingDir.createSync(recursive: true);

      final archivePath = await _download(Uri.parse(url), tempDir, onProgress);
      try {
        await archive.extractFileToDisk(archivePath, stagingDir.path);
        onProgress?.call(const WorkspaceRootfsInstallProgress(
          stage: WorkspaceRootfsInstallStage.extracting,
          entriesExtracted: -1,
        ));
      } finally {
        final f = File(archivePath);
        if (f.existsSync()) f.deleteSync();
      }

      if (linuxDir.existsSync()) linuxDir.deleteSync(recursive: true);
      try {
        stagingDir.renameSync(linuxDir.path);
      } on FileSystemException {
        // Cross-device fallback: copy then remove.
        _copyDirectorySync(stagingDir, linuxDir);
        stagingDir.deleteSync(recursive: true);
      }
      patcher.patch(linuxDir);
      onProgress?.call(const WorkspaceRootfsInstallProgress(
        stage: WorkspaceRootfsInstallStage.installed,
      ));
    } finally {
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
    }
  }

  Future<String> _download(
    Uri url,
    Directory tempDir,
    void Function(WorkspaceRootfsInstallProgress)? onProgress,
  ) async {
    final name = url.pathSegments.isNotEmpty
        ? url.pathSegments.last
        : 'rootfs.tar.gz';
    final target = File('${tempDir.path}/$name');
    final download = await (httpClientFactory?.call(url) ??
        HttpRootfsDownload.open(url));
    try {
      tempDir.createSync(recursive: true);
      final sink = target.openSync(mode: FileMode.write);
      try {
        final totalBytes = download.contentLength;
        var bytesRead = 0;
        var lastReport = 0;
        while (true) {
          final chunk = await download.read(_bufferSize);
          if (chunk.isEmpty) break;
          sink.writeFromSync(chunk);
          bytesRead += chunk.length;
          if (bytesRead - lastReport >= _progressStepBytes ||
              bytesRead == totalBytes) {
            lastReport = bytesRead;
            onProgress?.call(WorkspaceRootfsInstallProgress(
              stage: WorkspaceRootfsInstallStage.downloading,
              bytesRead: bytesRead,
              totalBytes: totalBytes,
            ));
          }
        }
        onProgress?.call(WorkspaceRootfsInstallProgress(
          stage: WorkspaceRootfsInstallStage.downloading,
          bytesRead: bytesRead,
          totalBytes: totalBytes,
        ));
      } finally {
        sink.closeSync();
      }
    } finally {
      await download.close();
    }
    return target.path;
  }

  void _copyDirectorySync(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final e in src.listSync(followLinks: false)) {
      final name = e.path.split('/').last;
      final target = '${dst.path}/$name';
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
}

/// Subset of [WorkspaceManager] the installer needs; avoids a circular
/// import and simplifies unit testing.
abstract class WorkspaceManagerLike {
  void ensureWorkspace(String root);
  Directory tempDir(String root);
  Directory linuxDir(String root);
}

/// Minimal download abstraction, for testability.
abstract class WorkspaceRootfsDownload {
  int? get contentLength;
  Future<List<int>> read(int maxBytes);
  Future<void> close();
}

class HttpRootfsDownload implements WorkspaceRootfsDownload {
  HttpRootfsDownload._(this._response, this._client);

  final HttpClientResponse _response;
  final HttpClient _client;

  @override
  int? get contentLength =>
      _response.contentLength >= 0 ? _response.contentLength : null;

  static Future<HttpRootfsDownload> open(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        client.close(force: true);
        throw WorkspaceException(
            'Rootfs download failed: HTTP ${response.statusCode}');
      }
      return HttpRootfsDownload._(response, client);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  @override
  Future<List<int>> read(int maxBytes) async {
    final out = <int>[];
    await for (final chunk in _response) {
      out.addAll(chunk);
      if (out.length >= maxBytes) break;
    }
    if (out.length > maxBytes) return out.sublist(0, maxBytes);
    return out;
  }

  @override
  Future<void> close() async {
    _client.close(force: true);
  }
}
