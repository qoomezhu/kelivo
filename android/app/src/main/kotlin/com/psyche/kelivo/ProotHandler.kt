package com.psyche.kelivo

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Native backend for the workspace agent's proot shell runner.
 *
 * Mirrors rikkahub's ProotShellRunner: launches the bundled
 * libproot_exec.so with the extracted rootfs at <linuxDir>, bind-mounts
 * the workspace files area at /workspace, and runs the command through
 * bash -l -c with a clean environment.
 *
 * The proot binaries are shipped in app/src/main/jniLibs and land in
 * applicationInfo.nativeLibraryDir after packaging.
 */
class ProotHandler(private val context: Context) {
    companion object {
        const val CHANNEL_NAME = "kelivo.proot"
        private const val PROOT_EXEC = "libproot_exec.so"
        private const val PROOT_LOADER = "libproot_loader.so"
        private const val MAX_OUTPUT_CHARS = 128 * 1024
        private const val WORKSPACE_DIR = "/workspace"
    }

    private val executor = Executors.newCachedThreadPool()

    fun configure(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "exec" -> {
                    val command = call.argument<String>("command")
                        ?: return@setMethodCallHandler result.error("invalid_args", "command is required", null)
                    val cwd = call.argument<String>("cwd") ?: ""
                    val linuxDirPath = call.argument<String>("linuxDir")
                        ?: return@setMethodCallHandler result.error("invalid_args", "linuxDir is required", null)
                    val filesDirPath = call.argument<String>("filesDir")
                        ?: return@setMethodCallHandler result.error("invalid_args", "filesDir is required", null)
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 30_000

                    executor.execute {
                        try {
                            val res = exec(command, cwd, linuxDirPath, filesDirPath, timeoutMs)
                            mainHandler.post { result.success(res) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("proot_failed", e.message, null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun exec(
        command: String,
        cwd: String,
        linuxDirPath: String,
        filesDirPath: String,
        timeoutMs: Int,
    ): Map<String, Any> {
        val linuxDir = File(linuxDirPath)
        if (!File(linuxDir, "bin/sh").isFile) {
            return mapOf(
                "exitCode" to 127,
                "stdout" to "",
                "stderr" to "Rootfs is not installed",
                "timedOut" to false,
            )
        }

        val nativeDir = File(context.applicationInfo.nativeLibraryDir)
        val proot = File(nativeDir, PROOT_EXEC)
        val loader = File(nativeDir, PROOT_LOADER)
        if (!proot.isFile) {
            return mapOf(
                "exitCode" to 127,
                "stdout" to "",
                "stderr" to "proot executable not found: ${proot.absolutePath}",
                "timedOut" to false,
            )
        }
        if (!loader.isFile) {
            return mapOf(
                "exitCode" to 127,
                "stdout" to "",
                "stderr" to "proot loader not found: ${loader.absolutePath}",
                "timedOut" to false,
            )
        }

        val normalizedCwd = cwd.trim().trimStart('/')
        val prootCwd = if (normalizedCwd.isBlank()) WORKSPACE_DIR else "$WORKSPACE_DIR/$normalizedCwd"

        val argv = buildArgv(proot, linuxDir, File(filesDirPath), prootCwd, command)

        val process = ProcessBuilder(argv)
            .directory(File(filesDirPath))
            .redirectErrorStream(false)
            .apply {
                environment()["PROOT_LOADER"] = loader.absolutePath
                environment()["PROOT_TMP_DIR"] = File(linuxDirPath).parent + "/tmp"
                environment()["TMPDIR"] = File(linuxDirPath).parent + "/tmp"
            }
            .start()

        return readResult(process, timeoutMs.toLong())
    }

    private fun buildArgv(
        proot: File,
        linuxDir: File,
        filesDir: File,
        prootCwd: String,
        command: String,
    ): List<String> = mutableListOf(
        proot.absolutePath,
        "--root-id",
        "--link2symlink",
        "--kill-on-exit",
        "-r", linuxDir.absolutePath,
        "-w", prootCwd,
        "-b", "${filesDir.absolutePath}:$WORKSPACE_DIR",
        "/usr/bin/env", "-i",
        "HOME=/root",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=xterm-256color",
        "LANG=C.UTF-8",
        "LC_ALL=C.UTF-8",
        "CI=true",
        "NO_COLOR=1",
        "PAGER=cat",
        "/bin/bash", "-l", "-c",
        "cd -- \"\$1\" && eval \"\$2\"",
        "kelivo",
        prootCwd,
        command,
    )

    private fun readResult(process: Process, timeoutMs: Long): Map<String, Any> {
        val stdout = StreamCollector(process.inputStream)
        val stderr = StreamCollector(process.errorStream)

        // 没有 stdin 输入时立即关闭管道，避免 cat 等工具因 isatty 判断阻塞
        try {
            process.outputStream.close()
        } catch (_: IOException) {
            // 子进程已退出时忽略
        }

        val finished = try {
            process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            process.destroyForcibly()
            false
        }
        if (!finished) {
            process.destroyForcibly()
        }
        stdout.join(1000)
        stderr.join(1000)

        return mapOf(
            "exitCode" to if (finished) process.exitValue() else -1,
            "stdout" to stdout.text(),
            "stderr" to stderr.text(),
            "timedOut" to !finished,
            "truncated" to (stdout.truncated || stderr.truncated),
        )
    }

    /** 单流最大保留字符数：继续读到 EOF 但丢弃超出部分，防止管道阻塞。 */
    private class StreamCollector(stream: java.io.InputStream) {
        private val builder = StringBuilder()
        @Volatile var truncated = false
            private set

        private val thread = Thread {
            try {
                stream.bufferedReader().use { reader ->
                    val buffer = CharArray(4096)
                    while (true) {
                        val read = reader.read(buffer)
                        if (read < 0) break
                        synchronized(builder) {
                            val remaining = MAX_OUTPUT_CHARS - builder.length
                            if (remaining > 0) {
                                builder.append(buffer, 0, minOf(read, remaining))
                            }
                            if (read > remaining) truncated = true
                        }
                    }
                }
            } catch (_: IOException) {
                // 进程被杀时流关闭，保留已读内容
            }
        }.apply {
            isDaemon = true
            start()
        }

        fun join(millis: Long) = thread.join(millis)
        fun text(): String = synchronized(builder) { builder.toString() }
    }
}
