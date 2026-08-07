// android/app/src/main/kotlin/io/nekohasekai/sfm/MarkerWriter.kt
package io.nekohasekai.sfm

import android.content.Context
import java.io.File

/**
 * 极简标记写入器 — 零依赖，写文件不需要初始化
 * 每个方法写一条带时间戳的标记，崩溃后读文件就能看到执行到哪一步
 */
object MarkerWriter {

    private var contextRef: Context? = null
    private val buffer = StringBuilder()
    private var written = false

    fun init(context: Context) {
        contextRef = context
        write("=== MarkerWriter initialized ===")
    }

    fun write(msg: String) {
        val time = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US)
            .format(java.util.Date())
        val line = "[$time] $msg"
        buffer.appendLine(line)

        // Write to file every time (flush immediately)
        val ctx = contextRef ?: return
        try {
            val logDir = File(ctx.filesDir, "logs")
            if (!logDir.exists()) logDir.mkdirs()
            val file = File(logDir, "markers.log")
            file.appendText("$line\n")
            written = true
        } catch (_: Exception) {
            // Silent — marker writing should never crash
        }

        // Also logcat
        android.util.Log.d("sing-box/Marker", msg)
    }

    /** 读取所有标记 */
    fun readAll(): String {
        val ctx = contextRef ?: return buffer.toString()
        try {
            val file = File(File(ctx.filesDir, "logs"), "markers.log")
            if (file.exists()) {
                return file.readText()
            }
        } catch (_: Exception) {}
        return buffer.toString()
    }
}
