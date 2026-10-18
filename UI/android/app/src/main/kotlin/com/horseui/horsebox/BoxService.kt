package com.horseui.horsebox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetSocketAddress

/**
 * 回滚版本：SFA 改造之前的 VpnService 实现。
 *
 * 保留系统默认网络 + 单网卡 + protect 的思路，不使用 SFA 的
 * DefaultNetworkMonitor / LocalResolver。
 */
class BoxService : VpnService() {

    private var commandServer: CommandServer? = null
    private var tunPfd: ParcelFileDescriptor? = null
    private var defaultCallback: ConnectivityManager.NetworkCallback? = null
    private var stopping = false
    private var allowedPackages: List<String> = emptyList()
    private var directPackages: List<String> = emptyList()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 系统当前默认网络的接口，不做全量枚举。 */
    @Volatile
    private var systemInterface: io.nekohasekai.libbox.NetworkInterface? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCore()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                allowedPackages = intent.getStringArrayListExtra(EXTRA_ALLOWED_PACKAGES) ?: emptyList()
                directPackages = intent.getStringArrayListExtra(EXTRA_DIRECT_PACKAGES) ?: emptyList()
                startForegroundCompat()
                val config = intent.getStringExtra(EXTRA_CONFIG)
                if (config.isNullOrBlank()) {
                    Log.e(TAG, "缺少配置")
                    stopCore()
                    return START_NOT_STICKY
                }
                Thread {
                    try {
                        startCore(config)
                    } catch (t: Throwable) {
                        Log.e(TAG, "内核启动失败", t)
                        isRunning = false
                        VpnPlugin.notifyState(false)
                        stopCore()
                    }
                }.start()
                return START_REDELIVER_INTENT
            }
        }
        return START_NOT_STICKY
    }

    private fun startCore(config: String) {
        closeServer()
        Libbox.setup(
            SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = filesDir.absolutePath
                tempPath = cacheDir.absolutePath
                fixAndroidStack = true
                logMaxLines = 2000
                debug = false
                appVersion = "0.1.0"
            },
        )

        val server = Libbox.newCommandServer(
            object : CommandServerHandler {
                override fun serviceReload() = Unit

                override fun serviceStop() {
                    mainHandler.post { stopCore() }
                }

                override fun setSystemProxyEnabled(enabled: Boolean) = Unit

                override fun getSystemProxyStatus(): SystemProxyStatus =
                    SystemProxyStatus().apply {
                        available = false
                        enabled = false
                    }

                override fun connectSSHAgent(): Int = -1
                override fun triggerNativeCrash() = Unit

                override fun writeDebugMessage(message: String) {
                    Log.d(TAG, message)
                }
            },
            Platform(),
        )
        val overrides = OverrideOptions().apply {
            includePackage = StringListIterator(emptyList())
            excludePackage = StringListIterator(emptyList())
        }
        server.startOrReloadService(config, overrides)
        commandServer = server
        isRunning = true
        VpnPlugin.notifyState(true)
        Log.i(TAG, "内核已启动")
    }

    private fun stopCore() {
        if (stopping) return
        stopping = true
        isRunning = false
        VpnPlugin.notifyState(false)
        // 先关 TUN，让系统立刻撤销 VPN 路由和状态栏图标。
        try {
            tunPfd?.close()
        } catch (_: Throwable) {
        }
        tunPfd = null
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } catch (_: Throwable) {
        }
        Thread {
            closeServer()
            stopping = false
        }.start()
    }

    private fun closeServer() {
        try {
            tunPfd?.close()
        } catch (_: Throwable) {
        }
        tunPfd = null
        try {
            commandServer?.closeService()
        } catch (t: Throwable) {
            Log.w(TAG, "停止服务失败", t)
        }
        try {
            commandServer?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "关闭内核失败", t)
        }
        commandServer = null
        try {
            defaultCallback?.let {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)
            }
        } catch (_: Throwable) {
        }
        defaultCallback = null
    }

    override fun onDestroy() {
        isRunning = false
        VpnPlugin.notifyState(false)
        Thread { closeServer() }.start()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopCore()
        super.onRevoke()
    }

    // ---------------------------------------------------------------- libbox 平台实现

    private inner class Platform : PlatformInterface {
        override fun openTun(options: TunOptions): Int = createTun(options)

        override fun autoDetectInterfaceControl(fd: Int) {
            if (!protect(fd)) {
                Log.e(TAG, "protect(fd=$fd) 失败")
                throw IllegalStateException("protect(fd) failed")
            }
        }

        override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
        override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
        override fun usePlatformBridge(): Boolean = false
        override fun usePlatformShell(): Boolean = false
        override fun includeAllNetworks(): Boolean = false
        override fun underNetworkExtension(): Boolean = false

        override fun localDNSTransport(): LocalDNSTransport? = null
        override fun readWIFIState(): WIFIState? = null
        override fun clearDNSCache() = Unit
        override fun checkPlatformShell() = Unit
        override fun lookupSFTPServer(): String = ""
        override fun readSystemSSHHostKey(): String = ""
        override fun tailscaleHostname(): String = ""

        override fun sendNotification(notification: io.nekohasekai.libbox.Notification) = Unit
        override fun cancelNotification(identifier: String, typeID: Int) = Unit

        override fun findConnectionOwner(
            ipProtocol: Int,
            sourceAddress: String,
            sourcePort: Int,
            destinationAddress: String,
            destinationPort: Int,
        ): ConnectionOwner {
            val owner = ConnectionOwner()
            owner.userId = Process.INVALID_UID
            owner.userName = ""
            owner.setAndroidPackageNames(StringListIterator(emptyList()))

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return owner
            try {
                val cm = getSystemService(ConnectivityManager::class.java)
                val uid = cm.getConnectionOwnerUid(
                    ipProtocol,
                    InetSocketAddress(sourceAddress, sourcePort),
                    InetSocketAddress(destinationAddress, destinationPort),
                )
                if (uid == Process.INVALID_UID) return owner
                val packages = packageManager.getPackagesForUid(uid)
                owner.userId = uid
                owner.userName = packages?.firstOrNull() ?: ""
                owner.setAndroidPackageNames(
                    StringListIterator(packages?.toList() ?: emptyList()),
                )
            } catch (t: Throwable) {
                Log.w(TAG, "查询连接归属失败", t)
            }
            return owner
        }

        override fun getInterfaces(): NetworkInterfaceIterator = systemInterfaceIterator()

        override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
            try {
                val cm = getSystemService(ConnectivityManager::class.java)
                val callback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) = refreshSystemInterface(cm, listener)

                    override fun onLinkPropertiesChanged(
                        network: Network,
                        linkProperties: LinkProperties,
                    ) = refreshSystemInterface(cm, listener)

                    override fun onCapabilitiesChanged(
                        network: Network,
                        capabilities: android.net.NetworkCapabilities,
                    ) = refreshSystemInterface(cm, listener)

                    override fun onLost(network: Network) = refreshSystemInterface(cm, listener)
                }
                defaultCallback = callback
                cm.registerDefaultNetworkCallback(callback)
                refreshSystemInterface(cm, listener)
            } catch (t: Throwable) {
                Log.w(TAG, "监听默认网卡失败", t)
            }
        }

        override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
            defaultCallback?.let {
                runCatching {
                    getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)
                }
            }
            defaultCallback = null
        }

        override fun startNeighborMonitor(listener: NeighborUpdateListener) = Unit
        override fun closeNeighborMonitor(listener: NeighborUpdateListener) = Unit
        override fun registerMyInterface(name: String) = Unit
        override fun lookupUser(username: String): PlatformUser? = null

        override fun openShellSession(
            user: PlatformUser?,
            command: String,
            args: StringIterator?,
            terminal: String,
            columns: Int,
            rows: Int,
        ): ShellSession? = null

        override fun createBridge(options: BridgeOptions): BridgeSession? = null
    }

    private fun refreshSystemInterface(
        cm: ConnectivityManager,
        listener: InterfaceUpdateListener,
    ) {
        try {
            val network = cm.activeNetwork ?: return
            val props = cm.getLinkProperties(network) ?: return
            val name = props.interfaceName ?: return
            val index = runCatching {
                java.net.NetworkInterface.getByName(name)?.index
            }.getOrNull() ?: 1
            val entry = buildSystemInterface(name, index, props)
            systemInterface = entry
            Log.i(
                TAG,
                "系统接口 $name index=$index mtu=${entry.mtu} " +
                    "addrs=${props.linkAddresses.joinToString { "${it.address.hostAddress}/${it.prefixLength}" }}",
            )
            listener.updateDefaultInterface(name, index, cm.isActiveNetworkMetered, false)
            listener.updateNetworkPath("")
        } catch (t: Throwable) {
            Log.w(TAG, "读取系统接口失败", t)
        }
    }

    private fun buildSystemInterface(
        name: String,
        index: Int,
        props: LinkProperties,
    ): io.nekohasekai.libbox.NetworkInterface {
        val addresses = props.linkAddresses.mapNotNull { la ->
            val host = la.address.hostAddress?.substringBefore('%') ?: return@mapNotNull null
            "$host/${la.prefixLength}"
        }
        val dns = props.dnsServers.mapNotNull { it.hostAddress?.substringBefore('%') }
        val mtu = runCatching { props.mtu }.getOrDefault(1500)
        return io.nekohasekai.libbox.NetworkInterface().apply {
            this.index = index
            this.name = name
            this.mtu = if (mtu > 0) mtu else 1500
            this.flags = 1
            this.type = interfaceType(name)
            this.addresses = StringListIterator(addresses)
            this.dnsServer = StringListIterator(dns)
            this.gateway = StringListIterator(emptyList())
            this.metered = false
        }
    }

    private fun systemInterfaceIterator(): NetworkInterfaceIterator {
        var entry = systemInterface
        if (entry == null) {
            try {
                val cm = getSystemService(ConnectivityManager::class.java)
                val network = cm.activeNetwork
                val props = network?.let { cm.getLinkProperties(it) }
                val name = props?.interfaceName
                if (props != null && name != null) {
                    val index = runCatching {
                        java.net.NetworkInterface.getByName(name)?.index
                    }.getOrNull() ?: 1
                    entry = buildSystemInterface(name, index, props)
                    systemInterface = entry
                }
            } catch (t: Throwable) {
                Log.w(TAG, "读取系统接口失败", t)
            }
        }
        val list = listOfNotNull(entry)
        Log.i(TAG, "系统接口数量 ${list.size}：" + list.joinToString { "${it.name}#${it.index}" })
        return object : NetworkInterfaceIterator {
            private var cursor = 0
            override fun hasNext(): Boolean = cursor < list.size
            override fun next(): io.nekohasekai.libbox.NetworkInterface = list[cursor++]
        }
    }

    private fun interfaceType(name: String): Int = when {
        name.startsWith("wlan") || name.startsWith("wifi") -> Libbox.InterfaceTypeWIFI
        name.startsWith("rmnet") || name.startsWith("ccmni") ||
            name.startsWith("pdp") || name.startsWith("radio") -> Libbox.InterfaceTypeCellular
        name.startsWith("eth") -> Libbox.InterfaceTypeEthernet
        else -> Libbox.InterfaceTypeOther
    }

    private fun createTun(options: TunOptions): Int {
        val builder = Builder()
            .setSession("HorseBox")
            .setMtu(options.mtu)
            .setBlocking(false)

        forEachPrefix(options.inet4Address) { builder.addAddress(it.address(), it.prefix()) }
        var hasIpv6 = false
        forEachPrefix(options.inet6Address) {
            builder.addAddress(it.address(), it.prefix())
            hasIpv6 = true
        }

        runCatching {
            val dns = options.dnsServerAddress
            while (dns.hasNext()) builder.addDnsServer(dns.next())
        }

        forEachPrefix(options.inet4RouteAddress) { builder.addRoute(it.address(), it.prefix()) }
        if (hasIpv6) {
            forEachPrefix(options.inet6RouteAddress) { builder.addRoute(it.address(), it.prefix()) }
        }
        if (options.autoRoute) {
            builder.addRoute("0.0.0.0", 0)
            if (hasIpv6) {
                runCatching { builder.addRoute("::", 0) }
            }
        }

        runCatching {
            val include = options.includePackage
            while (include.hasNext()) builder.addAllowedApplication(include.next())
        }
        runCatching {
            val exclude = options.excludePackage
            while (exclude.hasNext()) builder.addDisallowedApplication(exclude.next())
        }
        applyAllowedApplications(builder)

        val descriptor = builder.establish() ?: throw IllegalStateException("建立 TUN 失败")
        tunPfd = descriptor
        return descriptor.fd
    }

    private fun applyAllowedApplications(builder: Builder) {
        val pm = packageManager
        val installed = pm.getInstalledApplications(0)
        val allPackages = installed.asSequence().map { it.packageName }.toSet()
        val userApps = installed.asSequence()
            .filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 }
            .map { it.packageName }
            .toSet()
        val direct = directPackages.filter { it in allPackages }.toSet()
        // 用户显式勾选的应用优先，包括 GMS 这类系统应用；未勾选时只代理用户应用。
        val explicit = allowedPackages.filter { it in allPackages }.toSet()
        val selected = if (explicit.isNotEmpty()) explicit else userApps
        val effective = selected - direct
        if (effective.isEmpty()) {
            // 没有可代理的应用时退化为“全部用户应用”，但仍强制直连列表。
            for (pkg in direct) {
                if (pkg == packageName) continue
                runCatching { builder.addDisallowedApplication(pkg) }
            }
            return
        }
        for (pkg in effective) {
            if (pkg == packageName) continue
            runCatching { builder.addAllowedApplication(pkg) }
        }
    }

    private inline fun forEachPrefix(
        iterator: RoutePrefixIterator?,
        action: (RoutePrefix) -> Unit,
    ) {
        if (iterator == null) return
        while (iterator.hasNext()) {
            action(iterator.next())
        }
    }

    private class StringListIterator(private val items: List<String>) : StringIterator {
        private var cursor = 0
        override fun hasNext(): Boolean = cursor < items.size
        override fun len(): Int = items.size - cursor
        override fun next(): String = items[cursor++]
    }

    // ---------------------------------------------------------------- 通知

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "HorseBox 代理",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持代理连接"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, BoxService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("HorseBox 正在运行")
            .setContentText("流量已由 sing-box 接管")
            .setSmallIcon(R.drawable.ic_stat_horsebox)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "断开代理", stop)
            .build()
    }

    companion object {
        private const val TAG = "HorseBox"
        private const val CHANNEL_ID = "horsebox_vpn"
        private const val NOTIFICATION_ID = 1
        const val ACTION_START = "com.horseui.horsebox.START"
        const val ACTION_STOP = "com.horseui.horsebox.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_ALLOWED_PACKAGES = "allowed_packages"
        const val EXTRA_DIRECT_PACKAGES = "direct_packages"

        @Volatile
        var isRunning: Boolean = false
            private set
    }
}
