// android/app/src/main/kotlin/io/nekohasekai/sfm/FileLogger.kt
package io.nekohasekai.sfm

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 原生侧文件日志 — 崩溃后仍可读取
 * 写入到 context.filesDir/logs/native.log
 */
object FileLogger {
    private const val TAG = "sing-box/FileLogger"
    private const val MAX_LOG_SIZE = 512 * 1024 // 512KB max
    private const val MAX_LOG_LINES = 5000       // keep last 5000 lines

    private var logFile: File? = null
    private var writer: FileWriter? = null
    private var lineCount = 0

    fun init(context: Context) {
        try {
            val logDir = File(context.filesDir, "logs")
            if (!logDir.exists()) logDir.mkdirs()
            logFile = File(logDir, "native.log")

            // Rotate if too large
            if (logFile!!.exists() && logFile!!.length() > MAX_LOG_SIZE) {
                logFile!!.renameTo(File(logDir, "native.old.log"))
                logFile = File(logDir, "native.log")
            }

            writer = FileWriter(logFile, true) // append
            lineCount = 0
            i("FileLogger", "=== Native logger started ===")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to init FileLogger", e)
        }
    }

    private fun write(level: String, tag: String, msg: String) {
        try {
            if (writer == null) return
            val time = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
            writer!!.write("$time $level/$tag: $msg\n")
            writer!!.flush()
            lineCount++

            // Trim if too many lines
            if (lineCount > MAX_LOG_LINES) {
                trimLog()
            }
        } catch (e: IOException) {
            Log.e(TAG, "Write failed", e)
        }
    }

    fun d(tag: String, msg: String) {
        Log.d(tag, msg)
        write("D", tag, msg)
    }

    fun e(tag: String, msg: String, tr: Throwable? = null) {
        Log.e(tag, msg, tr)
        write("E", tag, "$msg ${tr?.message ?: ""}")
        tr?.let {
            for (ste in it.stackTrace) {
                write("E", tag, "  at $ste")
            }
        }
    }

    fun i(tag: String, msg: String) {
        Log.i(tag, msg)
        write("I", tag, msg)
    }

    fun w(tag: String, msg: String) {
        Log.w(tag, msg)
        write("W", tag, msg)
    }

    /** 读取当前日志文件内容 */
    fun readContent(): String {
        return try {
            if (logFile?.exists() == true) {
                val file = logFile!!
                if (file.length() > MAX_LOG_SIZE) {
                    // Read last 512KB
                    val raf = java.io.RandomAccessFile(file, "r")
                    raf.seek(file.length() - MAX_LOG_SIZE)
                    val buf = ByteArray(MAX_LOG_SIZE)
                    val read = raf.read(buf)
                    raf.close()
                    String(buf, 0, read, Charsets.UTF_8)
                } else {
                    file.readText(Charsets.UTF_8)
                }
            } else {
                "(no native log yet)"
            }
        } catch (e: Exception) {
            "Error reading log: ${e.message}"
        }
    }

    /** 裁剪日志到一半行数 */
    private fun trimLog() {
        try {
            if (logFile?.exists() != true) return
            val lines = logFile!!.readLines()
            if (lines.size <= MAX_LOG_LINES) return
            val trimmed = lines.drop(lines.size / 2)
            logFile!!.writeText(trimmed.joinToString("\n") + "\n")
            lineCount = trimmed.size
            writer?.close()
            writer = FileWriter(logFile, true)
        } catch (e: Exception) {
            Log.e(TAG, "Trim failed", e)
        }
    }

    /** 安全关闭 */
    fun close() {
        try {
            writer?.close()
        } catch (_: Exception) {}
        writer = null
    }
}
