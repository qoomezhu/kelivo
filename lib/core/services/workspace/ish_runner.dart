import 'dart:async';

import 'models.dart';

/// iOS 执行层：通过嵌入的 iSH 内核执行命令。
///
/// 原生侧协议（见 ISH-EMBEDDING-DESIGN.md）：
///   MethodChannel('kelivo.ish')
///     - boot(rootPath) -> bool            启动内核（幂等）
///     - startSession(command, cwd, env) -> {pid}   起进程
///     - writeInput(pid, data)             写 stdin
///     - wait(pid) -> {exitCode}           等退出
///   EventChannel('kelivo.ish/output')
///     - {pid, stream: 'stdout'|'stderr', data: base64}
///
/// 输出收集/截断/超时语义对齐 rikkahub 的 Process.readResult。
class IshShellRunner implements WorkspaceShellRunner {
  IshShellRunner({this.channel, this.outputStream});

  /// 注入测试替身；生产环境由调用方传入平台 channel。
  final IshChannel? channel;
  final Stream<IshOutputEvent>? outputStream;

  static const int maxOutputChars = 128 * 1024;

  @override
  Future<WorkspaceCommandResult> execute(WorkspaceShellContext context) async {
    final ch = channel;
    if (ch == null) {
      return WorkspaceCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'iSH runner unavailable on this platform',
      );
    }

    // 启动会话（rootfs 是否就位由 manager.hasRootfs 判断，这里直接执行）
    final env = <String, String>{
      'TERM': 'xterm-256color',
      'PATH':
          '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': '/root',
      'LANG': 'C.UTF-8',
      'CI': 'true',
      'NO_COLOR': '1',
      'PAGER': 'cat',
    };

    int pid;
    try {
      pid = await ch.startSession(
        command: context.command,
        cwd: context.cwd,
        linuxDir: context.linuxDir.path,
        filesDir: context.filesDir.path,
        env: env,
      );
    } on IshException catch (e) {
      return WorkspaceCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'iSH start failed: ${e.message}',
      );
    }

    // 3. 收集输出（带截断），同时等退出
    final stdoutBuf = _ClampedBuffer(maxOutputChars);
    final stderrBuf = _ClampedBuffer(maxOutputChars);
    final outSub = outputStream?.listen((event) {
      if (event.pid != pid) return;
      if (event.stream == 'stdout') {
        stdoutBuf.append(event.data);
      } else if (event.stream == 'stderr') {
        stderrBuf.append(event.data);
      }
    });

    try {
      if (context.stdin != null && context.stdin!.isNotEmpty) {
        await ch.writeInput(pid, context.stdin!);
      }

      var timedOut = false;
      int exitCode;
      try {
        exitCode = await ch.wait(pid)
            .timeout(Duration(milliseconds: context.timeoutMillis));
      } on TimeoutException {
        timedOut = true;
        exitCode = -1;
        await ch.kill(pid);
      }

      // 给尾随输出一点排空时间
      await Future<void>.delayed(const Duration(milliseconds: 50));

      return WorkspaceCommandResult(
        exitCode: exitCode,
        stdout: stdoutBuf.toString(),
        stderr: stderrBuf.toString(),
        timedOut: timedOut,
        truncated: stdoutBuf.truncated || stderrBuf.truncated,
      );
    } finally {
      await outSub?.cancel();
    }
  }
}

/// 平台 channel 抽象（测试可替换）。
abstract class IshChannel {
  Future<bool> boot(String rootPath);
  Future<int> startSession({
    required String command,
    required String cwd,
    required String linuxDir,
    required String filesDir,
    Map<String, String> env = const {},
  });
  Future<void> writeInput(int pid, List<int> data);
  Future<int> wait(int pid);
  Future<void> kill(int pid);
}

class IshException implements Exception {
  IshException(this.message);
  final String message;

  @override
  String toString() => message;
}

class IshOutputEvent {
  const IshOutputEvent({
    required this.pid,
    required this.stream,
    required this.data,
  });

  final int pid;
  final String stream; // stdout | stderr
  final String data;
}

/// 输出缓冲：累计到上限后丢弃但继续消费（防管道阻塞），标记 truncated。
class _ClampedBuffer {
  _ClampedBuffer(this.maxChars);

  final int maxChars;
  final StringBuffer _buf = StringBuffer();
  bool truncated = false;

  void append(String chunk) {
    if (_buf.length + chunk.length <= maxChars) {
      _buf.write(chunk);
      return;
    }
    final remaining = maxChars - _buf.length;
    if (remaining > 0) _buf.write(chunk.substring(0, remaining));
    truncated = true;
  }

  @override
  String toString() => _buf.toString();
}
