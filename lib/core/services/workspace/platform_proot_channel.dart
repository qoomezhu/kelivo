import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';
import 'proot_runner.dart';

/// 生产环境 proot channel：MethodChannel('kelivo.proot') 的 exec 方法。
Future<WorkspaceCommandResult> prootExec(
  String command,
  String cwd,
  String linuxDir,
  String filesDir,
  int timeoutMillis,
) async {
  const channel = MethodChannel('kelivo.proot');
  try {
    final raw = await channel.invokeMethod<Map<dynamic, dynamic>>('exec', {
      'command': command,
      'cwd': cwd,
      'linuxDir': linuxDir,
      'filesDir': filesDir,
      'timeoutMs': timeoutMillis,
    });
    if (raw == null) {
      return WorkspaceCommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'proot exec returned null',
      );
    }
    return WorkspaceCommandResult(
      exitCode: (raw['exitCode'] as num?)?.toInt() ?? -1,
      stdout: raw['stdout']?.toString() ?? '',
      stderr: raw['stderr']?.toString() ?? '',
      timedOut: raw['timedOut'] == true,
      truncated: raw['truncated'] == true,
    );
  } on PlatformException catch (e) {
    return WorkspaceCommandResult(
      exitCode: 127,
      stdout: '',
      stderr: 'proot exec failed: ${e.message}',
    );
  } on MissingPluginException {
    return WorkspaceCommandResult(
      exitCode: 127,
      stdout: '',
      stderr: 'proot native handler not available on this platform',
    );
  }
}

/// Android 平台的 [WorkspaceShellRunner]。
WorkspaceShellRunner androidProotRunner() =>
    ProotShellRunner(execCommand: prootExec);
