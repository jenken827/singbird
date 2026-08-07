// android/app/src/main/kotlin/io/nekohasekai/sfm/VpnService.kt
package io.nekohasekai.sfm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService as AndroidVpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.File
import io.flutter.Log
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import io.nekohasekai.libbox.Notification as SfNotification

class VpnService : AndroidVpnService(), PlatformInterface {

    companion object {
        private const val TAG = "sing-box/VpnService"
        private const val NOTIFICATION_CHANNEL_ID = "singbox_vpn"
        private const val NOTIFICATION_ID = 1001

        private const val PREFS_NAME = "vpn_filter_prefs"
        private const val KEY_ALLOWED = "allowed_packages"
        private const val KEY_DISALLOWED = "disallowed_packages"

        @Volatile
        var instance: VpnService? = null

        // Per-app VPN filter: null = no restriction
        @Volatile
        var allowedPackages: Set<String>? = null   // only these apps → VPN
        @Volatile
        var disallowedPackages: Set<String>? = null // these apps → bypass VPN

        /** Called from settings UI when app filter changes (persists + rebuilds). */
        fun updateAppFilter(allowed: Set<String>?, disallowed: Set<String>?, ctx: android.content.Context) {
            allowedPackages = allowed
            disallowedPackages = disallowed
            // Persist across app restarts
            try {
                ctx.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                    .edit()
                    .putStringSet(KEY_ALLOWED, allowed)
                    .putStringSet(KEY_DISALLOWED, disallowed)
                    .apply()
            } catch (_: Exception) {}
            // Signal the running service to rebuild VPN with new filter
            instance?.rebuildVpn()
        }

        /** Restore persisted filter after process restart (app killed & relaunched). */
        fun loadPersistedFilter(ctx: android.content.Context) {
            try {
                val prefs = ctx.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                val a = prefs.getStringSet(KEY_ALLOWED, null)
                val d = prefs.getStringSet(KEY_DISALLOWED, null)
                if (a != null || d != null) {
                    allowedPackages = a
                    disallowedPackages = d
                }
            } catch (_: Exception) {}
        }
    }

    private var boxService: BoxService? = null

    /**
     * Stop the VPN from the activity side. Order matters:
     * 1. close TUN fd → Android removes the VPN network → the system
     *    (ConnectivityService) unbinds this service
     * 2. then stopForeground + stopSelf actually destroy the service
     * Without step 1, this service is system-bound (BIND_VPN_SERVICE) and
     * stopSelf()/stopService() never trigger onDestroy → stale fd + tun0 →
     * next establish() fails to register the VPN network.
     */
    fun shutdown() {
        MarkerWriter.write("VpnService.shutdown()")
        try { currentTunFd?.close() } catch (_: Exception) {}
        currentTunFd = null
        boxService?.stop()
        try { stopForeground(true) } catch (_: Exception) {}
        stopSelf()
    }

    // ── Lifecycle ──

    override fun onCreate() {
        super.onCreate()
        MarkerWriter.init(this)
        MarkerWriter.write("VpnService.onCreate()")
        instance = this
        createNotificationChannel()
        // Restore persisted per-app filter (survives app restarts)
        loadPersistedFilter(applicationContext)

        // Catch all uncaught exceptions to log them
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            MarkerWriter.write("UNCAUGHT EXCEPTION on ${thread.name}: ${throwable}")
            for (ste in throwable.stackTrace.take(30)) {
                MarkerWriter.write("  at $ste")
            }
            FileLogger.e(TAG, "UNCAUGHT on ${thread.name}", throwable)
            FileLogger.close()
            null
        }

        MarkerWriter.write("VpnService created OK")
    }

    private var heartbeatTimer: java.util.Timer? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        MarkerWriter.write("VpnService.onStartCommand()")
        if (intent == null) {
            MarkerWriter.write("  intent is NULL — returning START_NOT_STICKY")
            return START_NOT_STICKY
        }
        MarkerWriter.write("  intent=$intent")

        // Extract config directory (contains sing-box-config.json + netbird-config.json)
        var configDir: String? = null
        intent.getStringExtra("config_dir")?.let {
            configDir = it
            MarkerWriter.write("  extra config_dir: $it")
        } ?: MarkerWriter.write("  extra config_dir: null")

        intent.getStringArrayListExtra("allowed_packages")?.let {
            allowedPackages = it.toSet()
            MarkerWriter.write("  allowed_packages: ${it.size}")
        }
        intent.getStringArrayListExtra("disallowed_packages")?.let {
            disallowedPackages = it.toSet()
            MarkerWriter.write("  disallowed_packages: ${it.size}")
        }

        // Netbird enable flag from Flutter settings
        val netbirdEnabled = if (intent.hasExtra("netbird_enabled")) {
            intent.getBooleanExtra("netbird_enabled", false)
        } else {
            // Legacy: default to enabled (old behavior)
            true
        }
        MarkerWriter.write("  netbird_enabled: $netbirdEnabled")

        // Step 1: startForeground
        MarkerWriter.write("STEP 1: startForeground()")
        try {
            val notification = buildNotification("Connecting...")
            startForeground(NOTIFICATION_ID, notification)
            MarkerWriter.write("  startForeground OK")
        } catch (e: Exception) {
            MarkerWriter.write("  startForeground FAILED: ${e}")
            stopSelf()
            return START_NOT_STICKY
        }

        // Step 2: BoxService creation
        MarkerWriter.write("STEP 2: creating BoxService")
        try {
            if (boxService == null) {
                boxService = BoxService(this, this)
                MainActivity.boxService = boxService
                MarkerWriter.write("  BoxService created OK")
            }
        } catch (e: Exception) {
            MarkerWriter.write("  BoxService creation FAILED: ${e}")
            updateNotification("Error: ${e.message}")
            return START_STICKY
        }

        // Step 3: BoxService.start(config from file at configDir)
        MarkerWriter.write("STEP 3: BoxService.start()")
        try {
            // Read sing-box config from file
            val sbConfigFile = if (configDir != null) File(configDir, "sing-box-config.json") else null
            var sbConfig = if (sbConfigFile?.exists() == true) sbConfigFile.readText() else null
            MarkerWriter.write("  sing-box config from file: ${sbConfig?.length ?: "null"} chars")

            // Inject Android-required TUN settings (covers auto-start too —
            // Flutter-side injection only runs on manual start):
            // - tun stack=gvisor: with `mixed` the gvisor TCP half fails to
            //   start on Android 10 MIUI (DNS/UDP works, TCP never processed)
            // - remove tun interface_name: VpnService assigns tun0; a fixed
            //   name breaks sing-box own-TUN exclusion
            // - route.auto_detect_interface=false: MIUI SELinux blocks
            //   /proc/net; protect() is applied unconditionally instead
            if (sbConfig != null) {
                try {
                    val obj = org.json.JSONObject(sbConfig)
                    val route = obj.optJSONObject("route") ?: org.json.JSONObject().also { obj.put("route", it) }
                    route.put("auto_detect_interface", false)
                    val inbounds = obj.optJSONArray("inbounds")
                    if (inbounds != null) {
                        for (i in 0 until inbounds.length()) {
                            val ib = inbounds.optJSONObject(i) ?: continue
                            if (ib.optString("type") == "tun") {
                                ib.remove("interface_name")
                                ib.put("stack", "gvisor")
                            }
                        }
                    }
                    sbConfig = obj.toString()
                    MarkerWriter.write("  Android TUN injected: stack=gvisor, auto_detect=false")
                } catch (e: Exception) {
                    MarkerWriter.write("  config inject FAILED: ${e.message?.take(60)}")
                }
            }

            // Read netbird config from file (only pass to engine if enabled)
            var nbConfig: String? = null
            if (netbirdEnabled) {
                val nbConfigFile = if (configDir != null) File(configDir, "netbird-config.json") else null
                nbConfig = if (nbConfigFile?.exists() == true) nbConfigFile.readText() else null
            }
            MarkerWriter.write("  netbird config from file: ${nbConfig != null} (enabled=$netbirdEnabled)")

            boxService?.start(sbConfig, nbConfig)
            MarkerWriter.write("  BoxService.start() returned OK")
        } catch (e: Exception) {
            MarkerWriter.write("  BoxService.start() FAILED: ${e}")
            updateNotification("Error: ${e.message}")
            return START_STICKY
        }

        // Step 4: Config already loaded in BoxService.start() — skip
        MarkerWriter.write("STEP 4: config already loaded in start(), skipping")

        MarkerWriter.write("VpnService.onStartCommand() COMPLETE — returning START_STICKY")

        // Heartbeat to detect post-startup crashes
        heartbeatTimer = java.util.Timer("vpn-heartbeat", false)
        heartbeatTimer?.schedule(object : java.util.TimerTask() {
            var beat = 0
            override fun run() {
                beat++
                MarkerWriter.write("Heartbeat beat=$beat (${System.currentTimeMillis()})")
            }
        }, 2000, 2000)
        return START_STICKY
    }

    override fun onDestroy() {
        MarkerWriter.write("VpnService.onDestroy()")
        heartbeatTimer?.cancel()
        heartbeatTimer = null
        instance = null
        boxService?.stop()
        MainActivity.boxService = null
        boxService = null
        // Close the TUN fd so Android removes the VPN network & interface.
        // Without this, stop→start leaves a stale fd/tun0 and the next
        // establish() fails to register a VPN network (dumpsys shows no
        // VPN; app traffic hits empty fwmark table → no internet).
        try { currentTunFd?.close() } catch (_: Exception) {}
        currentTunFd = null
        super.onDestroy()
        MarkerWriter.write("VpnService.onDestroy() complete")
        FileLogger.close()
    }

    override fun onRevoke() {
        MarkerWriter.write("VpnService.onRevoke()")
        try { currentTunFd?.close() } catch (_: Exception) {}
        currentTunFd = null
        boxService?.stop()
        MainActivity.boxService = null
        boxService = null
        instance = null
        stopSelf()
        super.onRevoke()
    }

    // ── VPN rebuild ──

    private var currentTunFd: ParcelFileDescriptor? = null

    private fun rebuildVpn() {
        if (boxService == null || !(boxService?.isRunning() ?: false)) return
        Log.d(TAG, "Rebuilding VPN with updated app filter...")
        try {
            // Close existing TUN, engine will call openTun() again
            currentTunFd?.close()
            currentTunFd = null
            // Signal engine to reopen (platform-dependent; relies on engine re-calling openTun)
            // For now, restart the service for filter changes
            boxService?.stop()
            boxService?.start()
        } catch (e: Exception) {
            Log.e(TAG, "rebuildVpn failed", e)
        }
    }

    // ── PlatformInterface ──

    override fun autoDetectInterfaceControl(fd: Int) {
        MarkerWriter.write("  autoDetectInterfaceControl fd=$fd")
        FileLogger.d(TAG, "autoDetectInterfaceControl fd=$fd")
        protect(fd)
        MarkerWriter.write("  protect($fd) returned")
    }

    override fun writeMarker(message: String) {
        MarkerWriter.write("[go] $message")
    }

    override fun openTun(options: TunOptions): Int {
        MarkerWriter.write("PlatformInterface.openTun() mtu=${options.mtu}")

        val builder = Builder()
            .setSession("sing-box")
            .setMtu(options.mtu)
            .setBlocking(true)

        // Use Go engine's TUN address/route/DNS from config
        // TunOptions uses iterators (gomobile bindings)
        val inet4AddrIter = options.inet4Address
        val inet4RouteIter = options.inet4RouteAddress
        // getDNSServerAddress() throws Exception; use method call not property
        val dnsIter = try { options.getDNSServerAddress() } catch (e: Exception) { null }

        var addrAdded = false
        if (inet4AddrIter.hasNext()) {
            val addr = inet4AddrIter.next()
            builder.addAddress(addr.address(), addr.prefix())
            MarkerWriter.write("  addAddress ${addr.address()}/${addr.prefix()}")
            addrAdded = true
        }
        if (!addrAdded) {
            builder.addAddress("172.19.0.1", 30)
            MarkerWriter.write("  addAddress 172.19.0.1/30 (default)")
        }

        var routeAdded = false
        if (inet4RouteIter.hasNext()) {
            val route = inet4RouteIter.next()
            builder.addRoute(route.address(), route.prefix())
            MarkerWriter.write("  addRoute ${route.address()}/${route.prefix()}")
            routeAdded = true
        }
        builder.addRoute("0.0.0.0", 0)
        MarkerWriter.write("  addRoute 0.0.0.0/0")

        var dnsAdded = false
        if (dnsIter != null) {
            while (dnsIter.hasNext()) {
                val dns = dnsIter.next()
                builder.addDnsServer(dns)
                MarkerWriter.write("  addDnsServer $dns")
                dnsAdded = true
            }
        }
        if (!dnsAdded) {
            builder.addDnsServer("172.19.0.2")
            MarkerWriter.write("  addDnsServer 172.19.0.2 (default)")
        }

        // Apply per-app VPN filter
        val allowed = allowedPackages
        val disallowed = disallowedPackages
        if (allowed != null && allowed.isNotEmpty()) {
            MarkerWriter.write("  allowed apps: ${allowed.size}")
            for (pkg in allowed) {
                try {
                    builder.addAllowedApplication(pkg)
                } catch (e: Exception) {
                    MarkerWriter.write("  addAllowedApplication($pkg) warning: ${e.message}")
                }
            }
        } else if (disallowed != null && disallowed.isNotEmpty()) {
            MarkerWriter.write("  disallowed apps: ${disallowed.size}")
            for (pkg in disallowed) {
                try {
                    builder.addDisallowedApplication(pkg)
                } catch (e: Exception) {
                    MarkerWriter.write("  addDisallowedApplication($pkg) warning: ${e.message}")
                }
            }
        }
        try { builder.addDisallowedApplication(packageName) } catch (_: Exception) {}

        MarkerWriter.write("  calling builder.establish()...")
        val pfd = try {
            val established = builder.establish()
            // Inform Android about underlying network to help routing (API 21+)
            try {
                val cm = getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                val activeNetwork = cm.activeNetwork
                if (activeNetwork != null) {
                    builder.setUnderlyingNetworks(arrayOf(activeNetwork))
                    MarkerWriter.write("  setUnderlyingNetworks: active network set")
                }
            } catch (e: Exception) {
                MarkerWriter.write("  setUnderlyingNetworks skipped: ${e.message?.take(60)}")
            }
            established
        } catch (e: Exception) {
            MarkerWriter.write("  builder.establish() FAILED: ${e}")
            throw IllegalStateException("VPN establish failed: ${e.message}")
        }
        pfd ?: throw IllegalStateException("VPN establish returned null")
        currentTunFd = pfd
        val label = if (allowed != null) "VPN (${allowed.size} apps)" else "VPN (all apps)"
        updateNotification(label)
        MarkerWriter.write("  openTun() OK fd=${pfd.fd}")
        return pfd.fd
    }

    override fun sendNotification(n: SfNotification) {
        FileLogger.d(TAG, "sendNotification: title=${n.title}")
        updateNotification(n.title)
    }

    override fun useProcFS(): Boolean = false
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun usePlatformBridge(): Boolean = false
    override fun usePlatformShell(): Boolean = false
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun tailscaleHostname(): String = ""
    override fun readSystemSSHHostKey(): String = ""

    override fun findConnectionOwner(
        ipProtocol: Int, src: String, srcPort: Int,
        dst: String, dstPort: Int
    ): ConnectionOwner = ConnectionOwner()

    override fun readWIFIState(): WIFIState = Libbox.newWIFIState("", "")
    override fun localDNSTransport(): LocalDNSTransport? = null
    override fun lookupSFTPServer(): String = ""
    override fun lookupUser(name: String): PlatformUser = PlatformUser()
    override fun getInterfaces(): NetworkInterfaceIterator? {
        MarkerWriter.write("  getInterfaces() called")
        val list = mutableListOf<LibboxNetworkInterface>()
        runCatching {
            val en = java.net.NetworkInterface.getNetworkInterfaces()
            while (en.hasMoreElements()) {
                val ni = en.nextElement()
                if (!ni.isUp) continue
                val iface = LibboxNetworkInterface()
                iface.setIndex(ni.index)
                iface.setMTU(ni.mtu)
                iface.setName(ni.name)
                iface.setFlags(linuxLinkFlags(ni))
                iface.setType(interfaceType(ni.name))
                iface.setAddresses(EmptyStringIterator())
                iface.setDNSServer(EmptyStringIterator())
                iface.setMetered(false)
                list.add(iface)
            }
        }
        MarkerWriter.write("  getInterfaces() -> ${list.size} interfaces")
        return SimpleNetworkInterfaceIterator(list)
    }

    private fun interfaceType(name: String): Int {
        // libbox.InterfaceTypeWIFI=1, CELLULAR=2, ETHERNET=3, OTHER=4
        return when {
            name.startsWith("wlan") -> 1
            name.startsWith("rmnet") || name.startsWith("ccmni") -> 2
            name.startsWith("eth") -> 3
            else -> 4
        }
    }

    private fun linuxLinkFlags(ni: java.net.NetworkInterface): Int {
        // syscall IFF_* constants. Note: isMulticast() is API 25+, skipped
        // for minSdk=24 compatibility (flags only need UP/RUNNING for
        // sing-box interface selection).
        var flags = 0
        if (ni.isUp) flags = flags or 0x1          // IFF_UP
        flags = flags or 0x40                       // IFF_RUNNING
        if (ni.isLoopback) flags = flags or 0x8     // IFF_LOOPBACK
        return flags
    }

    // ── Default interface monitoring (ConnectivityManager) ──
    // sing-box relies on these callbacks for auto_detect_interface on
    // Android: SELinux blocks /proc/net reading (MIUI 10), so without
    // platform-reported interfaces every outbound fails with
    // "no available network interface".

    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null

    override fun startDefaultInterfaceMonitor(l: InterfaceUpdateListener) {
        MarkerWriter.write("  startDefaultInterfaceMonitor()")
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        defaultNetworkCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = reportDefaultInterface(cm, network, l)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                reportDefaultInterface(cm, network, l)
            override fun onLost(network: Network) {
                MarkerWriter.write("  default network lost")
                l.updateDefaultInterface("", -1, false, false)
            }
        }
        defaultNetworkCallback = callback
        runCatching { cm.registerDefaultNetworkCallback(callback) }
        // Report the current default network immediately — startup is when
        // rule-set downloads and first outbounds happen.
        cm.activeNetwork?.let { reportDefaultInterface(cm, it, l) }
    }

    override fun closeDefaultInterfaceMonitor(l: InterfaceUpdateListener) {
        MarkerWriter.write("  closeDefaultInterfaceMonitor()")
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        defaultNetworkCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        defaultNetworkCallback = null
    }

    private fun reportDefaultInterface(
        cm: ConnectivityManager, network: Network, l: InterfaceUpdateListener
    ) {
        val lp = cm.getLinkProperties(network) ?: return
        val name = lp.interfaceName ?: return

        // After the VPN activates, Android's default network becomes tun0
        // (our own TUN). Reporting it makes sing-box bind outbound sockets
        // to tun0 → loop → "no available network interface". Skip tun*
        // interfaces and fall back to the underlying physical network.
        if (name.startsWith("tun")) {
            MarkerWriter.write("  default interface is $name (own TUN), searching physical...")
            cm.allNetworks.forEach { n ->
                val nl = cm.getLinkProperties(n) ?: return@forEach
                val nn = nl.interfaceName ?: return@forEach
                if (nn.startsWith("tun")) return@forEach
                val caps = cm.getNetworkCapabilities(n)
                if (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true) {
                    reportInterface(cm, n, nn, l)
                    return
                }
            }
            MarkerWriter.write("  no physical default found")
            return
        }
        reportInterface(cm, network, name, l)
    }

    private fun reportInterface(
        cm: ConnectivityManager, network: Network, name: String, l: InterfaceUpdateListener
    ) {
        val index = findInterfaceIndex(name)
        val caps = cm.getNetworkCapabilities(network)
        // isMetered() is API 29+; use NET_CAPABILITY_NOT_METERED (API 21) to
        // keep minSdk=24 compatibility.
        val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
        val constrained = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) == false
        MarkerWriter.write("  default interface: $name idx=$index")
        l.updateDefaultInterface(name, index, expensive, constrained)
    }

    private fun findInterfaceIndex(name: String): Int {
        runCatching {
            val en = java.net.NetworkInterface.getNetworkInterfaces()
            while (en.hasMoreElements()) {
                val ni = en.nextElement()
                if (ni.name == name) return ni.index
            }
        }
        return -1
    }
    override fun registerMyInterface(name: String) {}
    override fun checkPlatformShell() {}
    override fun clearDNSCache() {}

    override fun createBridge(opts: BridgeOptions): BridgeSession? = null
    override fun startNeighborMonitor(l: NeighborUpdateListener) {}
    override fun closeNeighborMonitor(l: NeighborUpdateListener) {}

    override fun openShellSession(
        user: PlatformUser, command: String, environ: StringIterator,
        term: String, rows: Int, cols: Int
    ): ShellSession? = null

    override fun protect(fd: Int): Boolean {
        MarkerWriter.write("  protect($fd)")
        val result = super.protect(fd)
        MarkerWriter.write("  protect($fd) -> $result")
        return result
    }

    // ── Notification ──

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "VPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "sing-box VPN is running"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(content: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingOpen = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("sing-box")
            .setContentText(content)
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentIntent(pendingOpen)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(content: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, buildNotification(content))
    }
}

/** gomobile proxy iterators for libbox interface reporting */
class SimpleNetworkInterfaceIterator(
    private val items: List<LibboxNetworkInterface>
) : NetworkInterfaceIterator {
    private var idx = 0
    override fun hasNext(): Boolean = idx < items.size
    override fun next(): LibboxNetworkInterface = items[idx++]
}

class EmptyStringIterator : StringIterator {
    override fun hasNext(): Boolean = false
    override fun len(): Int = 0
    override fun next(): String = ""
}
