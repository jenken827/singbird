// android/app/src/main/kotlin/io/nekohasekai/sfm/MainActivity.kt
package io.nekohasekai.sfm

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.Libbox
import org.json.JSONArray
import org.json.JSONObject
import io.nekohasekai.sfm.VpnService as SfVpnService
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CONTROL_CHANNEL = "sing-box/monitor/control"
        private const val EVENT_CHANNEL = "sing-box/monitor/events"
        private const val REQUEST_VPN = 1001

        @Volatile
        var boxService: BoxService? = null

        // Pending method result for startVpn — resolved after VPN permission dialog
        private var pendingStartVpnResult: MethodChannel.Result? = null
        // Original MethodCall args — preserved across the permission dialog
        // (onActivityResult previously passed null call, losing configDir/netbirdEnabled)
        private var pendingStartVpnCall: MethodCall? = null

        // Track whether we've auto-started VPN to avoid duplicate attempts
        private var autoStarted = false
    }

    private var eventSink: EventChannel.EventSink? = null

    override fun onResume() {
        super.onResume()
        // Auto-start VPN on first resume after app launch
        if (!autoStarted) {
            autoStarted = true
            MarkerWriter.write("MainActivity.onResume: auto-starting VPN")
            val prepareIntent = android.net.VpnService.prepare(this@MainActivity)
            if (prepareIntent == null) {
                MarkerWriter.write("  permission already granted, starting service")
                try {
                    val intent = Intent(this, io.nekohasekai.sfm.VpnService::class.java)
                    intent.putExtra("config_dir", filesDir.absolutePath)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    MarkerWriter.write("  auto-start OK")
                } catch (e: Exception) {
                    MarkerWriter.write("  auto-start FAILED: ${e}")
                }
            } else {
                MarkerWriter.write("  need VPN permission dialog, skipping auto-start")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Init marker writer for crash diagnostics
        MarkerWriter.init(this)
        MarkerWriter.write("MainActivity.configureFlutterEngine")

        // EventChannel: Go -> Flutter (real-time events)
        EventChannel(flutterEngine.dartExecutor, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        // MethodChannel: Flutter -> Native
        MethodChannel(flutterEngine.dartExecutor, CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {

                        // ── Service lifecycle ──

                        "setServiceConfig" -> {
                            val config = call.argument<String>("config") ?: ""
                            MarkerWriter.write("HANDLER: setServiceConfig len=${config.length}")
                            boxService?.startService(config, OverrideOptions())
                            MarkerWriter.write("  setServiceConfig OK")
                            result.success(true)
                        }

                        "startService" -> {
                            MarkerWriter.write("HANDLER: startService (legacy)")
                            boxService?.start()
                            result.success(true)
                        }

                        "stopService" -> {
                            MarkerWriter.write("HANDLER: stopService (legacy)")
                            boxService?.stop()
                            result.success(true)
                        }

                        "isRunning" -> {
                            val running = boxService?.isRunning() ?: false
                            result.success(running)
                        }

                        // ── VPN lifecycle (Android-specific) ──

                        "startVpn" -> {
                            MarkerWriter.write("HANDLER: startVpn")
                            MarkerWriter.write("  step=prepare_check")
                            val prepareIntent = android.net.VpnService.prepare(this@MainActivity)
                            MarkerWriter.write("  prepareIntent=${prepareIntent != null}")
                            if (prepareIntent != null) {
                                MarkerWriter.write("  step=startActivityForResult(REQUEST_VPN)")
                                pendingStartVpnResult = result
                                pendingStartVpnCall = call
                                startActivityForResult(prepareIntent, REQUEST_VPN)
                            } else {
                                MarkerWriter.write("  permission already granted, skip dialog")
                                startVpnService(call, result)
                            }
                        }

                        "stopVpn" -> {
                            MarkerWriter.write("HANDLER: stopVpn")
                            // Full shutdown from the activity side: close TUN
                            // fd first (removes VPN network → system unbinds),
                            // then stopForeground + stopSelf.
                            SfVpnService.instance?.shutdown()
                            // Belt & braces: force service destruction.
                            try {
                                stopService(Intent(this, io.nekohasekai.sfm.VpnService::class.java))
                            } catch (_: Exception) {}
                            result.success(true)
                        }

                        "getVpnStatus" -> {
                            val running = SfVpnService.instance != null && boxService?.isRunning() == true
                            val allowed = SfVpnService.allowedPackages
                            val disallowed = SfVpnService.disallowedPackages
                            val map = mapOf(
                                "running" to running,
                                "allowedPackages" to (allowed?.toList() ?: emptyList<String>()),
                                "disallowedPackages" to (disallowed?.toList() ?: emptyList<String>())
                            )
                            result.success(map)
                        }

                        "getBackendVersion" -> {
                            // Version info from the libbox engine (sing-box + netbird)
                            val info = JSONObject()
                            info.put("singBoxVersion", Libbox.version() ?: "unknown")
                            info.put("singBoxCommit", Libbox.singBoxCommit() ?: "")
                            info.put("singBoxBuildTime", Libbox.singBoxBuildTime() ?: "")
                            info.put("netbirdVersion", Libbox.netbirdVersion() ?: "N/A")
                            info.put("netbirdCommit", Libbox.netbirdCommit() ?: "")
                            result.success(info.toString())
                        }

                        // ── Per-app VPN filter ──

                        "setAllowedPackages" -> {
                            val pkgs = call.argument<List<String>>("packages") ?: emptyList()
                            SfVpnService.updateAppFilter(pkgs.toSet(), null, this)
                            result.success(true)
                        }

                        "setDisallowedPackages" -> {
                            val pkgs = call.argument<List<String>>("packages") ?: emptyList()
                            SfVpnService.updateAppFilter(null, pkgs.toSet(), this)
                            result.success(true)
                        }

                        "clearAppFilter" -> {
                            SfVpnService.updateAppFilter(null, null, this)
                            result.success(true)
                        }

                        "getInstalledApps" -> {
                            val apps = getInstalledApps()
                            result.success(apps)
                        }

                        // ── History queries ──

                        "readNativeLog" -> {
                            result.success(FileLogger.readContent())
                        }

                        "readMarkers" -> {
                            result.success(MarkerWriter.readAll())
                        }

                        "readGoMarkers" -> {
                            val goFile = File(filesDir, "logs/go_markers.txt")
                            result.success(if (goFile.exists()) goFile.readText() else "(no Go markers yet)")
                        }

                        "readCrashReport" -> {
                            val crashFile = File(filesDir, "CrashReport-sing-box.log")
                            result.success(if (crashFile.exists()) crashFile.readText() else "(no crash report)")
                        }

                        "clearLogs" -> {
                            try {
                                File(File(filesDir, "logs"), "markers.log").delete()
                                File(File(filesDir, "logs"), "go_markers.txt").delete()
                                File(filesDir, "CrashReport-sing-box.log").delete()
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }

                        "getDNSHistory" -> {
                            val limit = call.arguments as? Int ?: 100
                            result.success(boxService?.getDNSHistory(limit) ?: "[]")
                        }

                        "getConnectionHistory" -> {
                            val limit = call.arguments as? Int ?: 100
                            result.success(boxService?.getConnectionHistory(limit) ?: "[]")
                        }

                        "queryDNSHistory" -> {
                            val args = call.arguments as? Map<String, Any> ?: emptyMap()
                            val since = (args["since"] as? Number)?.toInt() ?: 0
                            val limit = (args["limit"] as? Number)?.toInt() ?: 200
                            result.success(boxService?.getDNSHistory(limit) ?: "[]")
                        }

                        "queryConnectionHistory" -> {
                            val args = call.arguments as? Map<String, Any> ?: emptyMap()
                            val since = (args["since"] as? Number)?.toInt() ?: 0
                            val limit = (args["limit"] as? Number)?.toInt() ?: 200
                            result.success(boxService?.getConnectionHistory(limit) ?: "[]")
                        }

                        "queryStats" -> {
                            result.success("{}")
                        }

                        // ── Alert rules ──

                        "addAlertRule" -> {
                            result.success(
                                boxService?.addAlertRule(call.arguments as String) ?: -1
                            )
                        }

                        "deleteAlertRule" -> {
                            val ruleId = call.arguments as? Int ?: return@setMethodCallHandler
                            boxService?.deleteAlertRule(ruleId)
                            result.success(true)
                        }

                        "getAlertRules" -> {
                            result.success(boxService?.getAlertRules() ?: "[]")
                        }

                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error(call.method.uppercase() + "_FAILED", e.message, null)
                }
            }
    }

    // ── VPN permission dialog result ──

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN) {
            MarkerWriter.write("onActivityResult: requestCode=$requestCode resultCode=$resultCode")
            val pending = pendingStartVpnResult
            pendingStartVpnResult = null
            val pendingCall = pendingStartVpnCall
            pendingStartVpnCall = null
            if (resultCode == RESULT_OK) {
                MarkerWriter.write("  user GRANTED VPN permission")
                pending?.let { result -> startVpnService(pendingCall, result) }
            } else {
                MarkerWriter.write("  user DENIED VPN permission")
                pending?.error("VPN_PERMISSION_DENIED", "VPN permission denied by user", null)
            }
        }
    }

    // ── Helpers ──

    private fun startVpnService(call: MethodCall?, result: MethodChannel.Result) {
        MarkerWriter.write("startVpnService: building intent for VpnService")
        val intent = Intent(this, io.nekohasekai.sfm.VpnService::class.java)

        // Pass app filter from Flutter settings
        if (call != null) {
            val allowed: List<String>? = call.argument("allowedPackages")
            if (allowed != null) {
                MarkerWriter.write("  extra: allowed_packages=${allowed.size}")
                intent.putStringArrayListExtra("allowed_packages", ArrayList(allowed))
            }
            val disallowed: List<String>? = call.argument("disallowedPackages")
            if (disallowed != null) {
                MarkerWriter.write("  extra: disallowed_packages=${disallowed.size}")
                intent.putStringArrayListExtra("disallowed_packages", ArrayList(disallowed))
            }
            val configDir: String? = call.argument("configDir")
            if (configDir != null) {
                MarkerWriter.write("  extra: configDir=$configDir")
                intent.putExtra("config_dir", configDir)
            }
            val netbirdEnabled: Boolean? = call.argument("netbirdEnabled")
            if (netbirdEnabled != null) {
                MarkerWriter.write("  extra: netbird_enabled=$netbirdEnabled")
                intent.putExtra("netbird_enabled", netbirdEnabled)
            }
        }

        MarkerWriter.write("  calling startForegroundService()")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        MarkerWriter.write("  startForegroundService returned OK")
        result.success(true)
        MarkerWriter.write("  METHOD CHANNEL RESULT SENT — Flutter side will continue")
    }

    private fun getInstalledApps(): String {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val activities = pm.queryIntentActivities(intent, 0)
        val appList = activities
            .filter { it.activityInfo.packageName != packageName } // exclude self
            .map { resolveInfo ->
                val ai = resolveInfo.activityInfo
                val name = ai.loadLabel(pm).toString()
                val pkg = ai.packageName
                mapOf("name" to name, "packageName" to pkg)
            }
            .distinctBy { it["packageName"] }
            .sortedBy { it["name"]?.toString()?.lowercase() }

        val arr = JSONArray()
        for (app in appList) {
            val obj = org.json.JSONObject()
            obj.put("name", app["name"])
            obj.put("packageName", app["packageName"])
            arr.put(obj)
        }
        return arr.toString()
    }

    fun pushEvent(json: String) {
        eventSink?.success(json)
    }
}
