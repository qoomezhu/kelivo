import 'dart:async';

import 'package:flutter/services.dart';

import 'ish_runner.dart';

/// 生产环境的 iSH platform channel 实现。
///
/// 对应 iOS 原生插件（见 ISH-EMBEDDING-DESIGN.md 第五节）：
///   MethodChannel('kelivo.ish')
///     - boot(rootPath)
///     - startSession(command, cwd, linuxDir, filesDir, env)
///     - writeInput(pid, data)
///     - wait(pid)
///     - kill(pid)
///   EventChannel('kelivo.ish/output')
///     - {pid, stream, data}
class PlatformIshChannel implements IshChannel {
  PlatformIshChannel({MethodChannel? method, EventChannel? output})
      : _method = method ?? const MethodChannel('kelivo.ish'),
        _output = output ?? const EventChannel('kelivo.ish/output');

  final MethodChannel _method;
  final EventChannel _output;

  Stream<IshOutputEvent>? _outputStream;

  /// 输出事件流（懒初始化，广播语义）。
  Stream<IshOutputEvent> get onOutput => _outputStream ??= _output
      .receiveBroadcastStream()
      .map((raw) {
        final map = Map<String, dynamic>.from(raw as Map);
        return IshOutputEvent(
          pid: map['pid'] as int,
          stream: map['stream'] as String,
          data: map['data'] as String,
        );
      })
      .asBroadcastStream();

  @override
  Future<bool> boot(String rootPath) async {
    try {
      final ok = await _method.invokeMethod<bool>('boot', {
        'rootPath': rootPath,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      throw IshException('boot failed: ${e.message}');
    } on MissingPluginException {
      throw IshException('iSH plugin not available on this platform');
    }
  }

  @override
  Future<int> startSession({
    required String command,
    required String cwd,
    required String linuxDir,
    required String filesDir,
    Map<String, String> env = const {},
  }) async {
    try {
      final pid = await _method.invokeMethod<int>('startSession', {
        'command': command,
        'cwd': cwd,
        'linuxDir': linuxDir,
        'filesDir': filesDir,
        'env': env,
      });
      return pid ?? -1;
    } on PlatformException catch (e) {
      throw IshException(e.message ?? 'startSession failed');
    }
  }

  @override
  Future<void> writeInput(int pid, List<int> data) async {
    try {
      await _method.invokeMethod<void>('writeInput', {
        'pid': pid,
        'data': data,
      });
    } on PlatformException catch (e) {
      throw IshException('writeInput failed: ${e.message}');
    }
  }

  @override
  Future<int> wait(int pid) async {
    try {
      final code = await _method.invokeMethod<int>('wait', {
        'pid': pid,
      });
      return code ?? -1;
    } on PlatformException catch (e) {
      throw IshException('wait failed: ${e.message}');
    }
  }

  @override
  Future<void> kill(int pid) async {
    try {
      await _method.invokeMethod<void>('kill', {'pid': pid});
    } on PlatformException {
      // 进程可能已退出；忽略。
    }
  }
}
