import 'dart:async';
import 'dart:io';

import 'models.dart';

/// Android 执行层：通过 proot 在 app 沙箱内跑 Linux rootfs。
///
/// 原生侧协议（Kotlin ProotHandler，见 android/.../ProotHandler.kt）：
///   MethodChannel('kelivo.proot')
///     - exec(command, cwd, linuxDir, filesDir, env, timeoutMs) -> {exitCode, stdout, stderr, timedOut}
///
/// 命令构造语义完全对齐 rikkahub 的 ProotShellRunner.buildCommand：
///   proot --root-id --link2symlink --kill-on-exit
///     -r <linuxDir> -w /workspace/<cwd> -b <filesDir>:/workspace
///     /usr/bin/env -i HOME=/root PATH=... TERM=xterm-256color
///     /bin/bash -l -c 'cd -- "$1" && eval "$2"' <root> <cwd> <command>
class ProotShellRunner implements WorkspaceShellRunner {
  ProotShellRunner({this.execCommand});

  /// 可注入的执行函数（测试替身）；生产环境走 MethodChannel。
  final Future<WorkspaceCommandResult> Function(
    String command,
    String cwd,
    String linuxDir,
    String filesDir,
    int timeoutMillis,
  )? execCommand;

  static const int maxOutputChars = 128 * 1024;

  @override
  Future<WorkspaceCommandResult> execute(WorkspaceShellContext context) async {
    final exec = execCommand;
    if (exec == null) {
      return WorkspaceCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'proot runner unavailable (native handler not configured)',
      );
    }
    if (!context.linuxDir.existsSync() ||
        !File('${context.linuxDir.path}/bin/sh').existsSync()) {
      return WorkspaceCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'Rootfs is not installed',
      );
    }
    return exec(
      context.command,
      context.cwd,
      context.linuxDir.path,
      context.filesDir.path,
      context.timeoutMillis,
    );
  }
}

/// 构造 proot argv（对齐 rikkahub ProotShellRunner.buildCommand）。
/// 导出供 Kotlin 侧对照和 Dart 测试使用。
List<String> buildProotArgv({
  required String prootPath,
  required String linuxDir,
  required String filesDir,
  required String cwd,
  required String command,
}) {
  final normalizedCwd = cwd.trim().replaceAll(RegExp(r'^/+'), '');
  final prootCwd =
      normalizedCwd.isEmpty ? '/workspace' : '/workspace/$normalizedCwd';

  return [
    prootPath,
    '--root-id',
    '--link2symlink',
    '--kill-on-exit',
    '-r',
    linuxDir,
    '-w',
    prootCwd,
    '-b',
    '$filesDir:/workspace',
    '/usr/bin/env',
    '-i',
    'HOME=/root',
    'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    'TERM=xterm-256color',
    'LANG=C.UTF-8',
    'LC_ALL=C.UTF-8',
    'CI=true',
    'NO_COLOR=1',
    'PAGER=cat',
    '/bin/bash',
    '-l',
    '-c',
    'cd -- "\$1" && eval "\$2"',
    'kelivo',
    prootCwd,
    command,
  ];
}
