// android/app/src/main/kotlin/io/nekohasekai/sfm/BoxService.kt
package io.nekohasekai.sfm

import android.content.Context
import android.os.Build
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.MonitorService
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import java.io.File

class BoxService(
    private val context: Context,
    private val platformInterface: PlatformInterface,
) : CommandServerHandler {
    companion object {
        private const val TAG = "sing-box/BoxService"
    }

    @Volatile
    private var running = false
    private var commandServer: CommandServer? = null
    private var monitorService: MonitorService? = null

    fun isRunning(): Boolean = running

    fun start(singBoxConfig: String? = null, netbirdConfig: String? = null) {
        if (running) {
            FileLogger.w(TAG, "start() called but already running")
            MarkerWriter.write("BoxService.start: already running, skip")
            return
        }
        MarkerWriter.write("BoxService.start() called")
        FileLogger.i(TAG, "=== BoxService.start() ===")
        try {
            // Step 0: Setup() initializes Go paths (required before any Go call)
            MarkerWriter.write("BoxService: calling Setup()")
            val basePath = context.filesDir.absolutePath
            val setupOptions = SetupOptions()
            setupOptions.basePath = basePath
            setupOptions.workingPath = basePath
            setupOptions.tempPath = context.cacheDir.absolutePath
            setupOptions.fixAndroidStack = true
            setupOptions.logMaxLines = 1000
            setupOptions.crashReportSource = "sing-box"
            Libbox.setup(setupOptions)
            MarkerWriter.write("BoxService: Setup() OK")

            // Merge netbird config into sing-box config (if netbird is available)
            var finalSbConfig = singBoxConfig
            if (netbirdConfig != null && netbirdConfig.isNotEmpty()) {
                // Android < 12 (API < 31): pidfd_open syscall is blocked by seccomp
                // and kills the process. Skip netbird engine on these devices.
                if (Build.VERSION.SDK_INT < 31) {
                    MarkerWriter.write("BoxService: Android < 12 detected, skipping NetbirdStartAll")
                    FileLogger.w(TAG, "Android < 12: pidfd blocked by seccomp, netbird disabled")
                } else {
                    MarkerWriter.write("BoxService: calling NetbirdStartAll (${netbirdConfig.length} chars)")
                    try {
                        val modified = Libbox.netbirdStartAll(netbirdConfig, singBoxConfig ?: "")
                        if (modified != null && modified.isNotEmpty()) {
                            finalSbConfig = modified
                            MarkerWriter.write("BoxService: NetbirdStartAll OK, config injected")
                        } else {
                            MarkerWriter.write("BoxService: NetbirdStartAll returned empty config")
                        }
                    } catch (e: Exception) {
                        MarkerWriter.write("BoxService: NetbirdStartAll FAILED: ${e.message?.take(80)}")
                        FileLogger.w(TAG, "NetbirdStartAll failed: ${e.message}")
                    }
                }
            }

            // Command server
            MarkerWriter.write("BoxService: creating CommandServer")
            FileLogger.d(TAG, "Creating CommandServer...")
            val server = CommandServer(this, platformInterface)
            MarkerWriter.write("BoxService: CommandServer created")
            FileLogger.d(TAG, "Calling CommandServer.start()...")
            try {
                server.start()
                commandServer = server
                MarkerWriter.write("BoxService: CommandServer.start() OK")
                FileLogger.i(TAG, "CommandServer started successfully")
            } catch (e: Throwable) {
                MarkerWriter.write("BoxService: CommandServer.start() FAILED: ${e}")
                FileLogger.w(TAG, "CommandServer.start() failed: $e")
                throw e
            }

            // Apply sing-box config (possibly modified by NetbirdStartAll)
            if (finalSbConfig != null && finalSbConfig.isNotEmpty()) {
                MarkerWriter.write("BoxService: loading sing-box config (${finalSbConfig.length} chars)")
                FileLogger.i(TAG, "Loading sing-box config (${finalSbConfig.length} chars)")
                server.startOrReloadService(finalSbConfig, OverrideOptions())
                MarkerWriter.write("BoxService: sing-box config loaded OK")
                FileLogger.i(TAG, "Sing-box config loaded OK")
            } else {
                MarkerWriter.write("BoxService: no sing-box config")
                FileLogger.w(TAG, "No sing-box config — engine started without rules")
            }

            // Monitor service — SQLite history (DNS/connections). This is the
            // Android equivalent of the Windows /monitor/* HTTP endpoints.
            // Was never wired up before → queries always returned "[]".
            try {
                val dbFile = File(context.filesDir, "monitor.db")
                monitorService = MonitorService(dbFile.absolutePath)
                MarkerWriter.write("BoxService: monitorService created at ${dbFile.absolutePath}")
                FileLogger.i(TAG, "MonitorService created (${dbFile.absolutePath})")
            } catch (e: Throwable) {
                MarkerWriter.write("BoxService: monitorService FAILED: ${e.message?.take(80)}")
                FileLogger.w(TAG, "MonitorService creation failed: $e")
            }

            // Netbird is now handled by NetbirdStartAll above — no separate saveNetbirdConfig/startNetbirdEngine needed

            MarkerWriter.write("BoxService: start() completed successfully")
            running = true
            FileLogger.i(TAG, "=== BoxService.start() OK ===")
            pushEvent("""{"type":"status","status":"started"}""")
        } catch (e: Exception) {
            MarkerWriter.write("BoxService: start() EXCEPTION: ${e}")
            FileLogger.e(TAG, "=== BoxService.start() FAILED ===", e)
            running = false
            pushEvent("""{"type":"status","status":"error","message":"${e.message}"}""")
        }
    }

    fun startService(configContent: String, options: OverrideOptions) {
        FileLogger.i(TAG, "startService() called, config=${configContent.length} chars")
        try {
            commandServer?.startOrReloadService(configContent, options)
            FileLogger.i(TAG, "startOrReloadService OK")
        } catch (e: Exception) {
            FileLogger.e(TAG, "startOrReloadService FAILED", e)
        }
    }

    fun stop() {
        if (!running) {
            FileLogger.w(TAG, "stop() called but not running")
            return
        }
        FileLogger.i(TAG, "=== BoxService.stop() ===")
        try {
            commandServer?.closeService()
            commandServer?.close()
            commandServer = null
            monitorService = null
            running = false
            FileLogger.i(TAG, "=== BoxService.stop() OK ===")
            pushEvent("""{"type":"status","status":"stopped"}""")
        } catch (e: Exception) {
            FileLogger.e(TAG, "BoxService.stop() FAILED", e)
        }
    }

    // ---- CommandServerHandler ----
    override fun serviceStop() { stop() }
    override fun serviceReload() {}
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        available = false; enabled = false
    }
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun triggerNativeCrash() {}
    override fun writeDebugMessage(msg: String) { Log.d(TAG, msg) }
    override fun connectSSHAgent(): Int = -1

    // ---- Monitor queries ----
    fun getDNSHistory(limit: Int): String =
        monitorService?.getDNSHistory(limit.toLong()) ?: "[]"

    fun getConnectionHistory(limit: Int): String =
        monitorService?.getConnectionHistory(limit.toLong()) ?: "[]"

    fun addAlertRule(json: String): Int {
        monitorService?.addAlertRule(json)
        return 0
    }

    fun deleteAlertRule(ruleId: Int) {
        monitorService?.deleteAlertRule(ruleId.toLong())
    }

    fun getAlertRules(): String =
        monitorService?.getAlertRules() ?: "[]"

    private fun pushEvent(json: String) {
        val activity = context
        if (activity is MainActivity) {
            android.os.Handler(activity.mainLooper).post {
                activity.pushEvent(json)
            }
        }
    }
}
