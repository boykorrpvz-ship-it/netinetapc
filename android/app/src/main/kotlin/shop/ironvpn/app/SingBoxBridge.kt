package shop.ironvpn.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringBox
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.NetworkInterface
import java.net.InetAddress
import java.security.KeyStore
import java.util.Base64
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface

object SingBoxBridge {
    private const val TAG = "SingBoxBridge"

    private var initialized = false
    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null

    fun isAvailable(): Boolean = true

    @Synchronized
    fun isRunning(): Boolean = commandServer != null && tunDescriptor != null

    @Synchronized
    fun start(service: VpnService, configJson: String) {
        setup(service)
        Libbox.checkConfig(configJson)
        stop()

        val platform = AndroidPlatform(service)
        val handler = object : CommandServerHandler {
            override fun serviceStop() {
                closeTun()
            }

            override fun serviceReload() {
                // Reloads are driven by the Flutter side with a fresh config.
            }

            override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
                available = false
                enabled = false
            }

            override fun setSystemProxyEnabled(isEnabled: Boolean) {
                // Android system proxy is not used by this client.
            }

            override fun writeDebugMessage(message: String) {
                Log.d(TAG, message)
            }
        }

        val server = CommandServer(handler, platform)
        server.start()
        server.startOrReloadService(configJson, OverrideOptions())
        commandServer = server
    }

    @Synchronized
    fun stop() {
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        closeTun()
    }

    private fun setup(context: Context) {
        if (initialized) {
            return
        }

        val workingDir = context.getExternalFilesDir(null) ?: context.filesDir
        Libbox.setup(
            SetupOptions().apply {
                basePath = context.filesDir.path
                this.workingPath = workingDir.path
                tempPath = context.cacheDir.path
                fixAndroidStack = true
                logMaxLines = 1000
                debug = true
            },
        )
        initialized = true
    }

    private fun setTun(descriptor: ParcelFileDescriptor) {
        closeTun()
        tunDescriptor = descriptor
    }

    private fun closeTun() {
        runCatching { tunDescriptor?.close() }
        tunDescriptor = null
    }

    private class AndroidPlatform(private val service: VpnService) : PlatformInterface {
        override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

        override fun autoDetectInterfaceControl(fd: Int) {
            service.protect(fd)
        }

        override fun openTun(options: TunOptions): Int {
            if (VpnService.prepare(service) != null) {
                error("android: missing vpn permission")
            }

            val builder = service.Builder()
                .setSession("IronVPN")
                .setMtu(options.mtu.takeIf { it > 0 } ?: 9000)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            addAddresses(builder, options.inet4Address)
            addAddresses(builder, options.inet6Address)
            addDnsServers(builder, options.dnsServerAddress)

            if (options.autoRoute) {
                addRoutes(builder, options.inet4RouteAddress)
                addRoutes(builder, options.inet6RouteAddress)
                addRoutes(builder, options.inet4RouteRange)
                addRoutes(builder, options.inet6RouteRange)

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    excludeRoutes(builder, options.inet4RouteExcludeAddress)
                    excludeRoutes(builder, options.inet6RouteExcludeAddress)
                }

                addAllowedPackages(builder, options.includePackage)
                addDisallowedPackages(builder, options.excludePackage)
            }

            val descriptor = builder.establish() ?: error("android: failed to establish vpn")
            setTun(descriptor)
            return descriptor.fd
        }

        override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

        override fun findConnectionOwner(
            ipProtocol: Int,
            sourceAddress: String,
            sourcePort: Int,
            destinationAddress: String,
            destinationPort: Int,
        ): ConnectionOwner = ConnectionOwner()

        override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
            updateDefaultInterface(listener)
        }

        override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        }

        override fun getInterfaces(): NetworkInterfaceIterator {
            val connectivity =
                service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val javaInterfaces = NetworkInterface.getNetworkInterfaces().toList()
            val items = mutableListOf<BoxNetworkInterface>()

            for (network in connectivity.allNetworks) {
                val linkProperties = connectivity.getLinkProperties(network) ?: continue
                val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    continue
                }
                val interfaceName = linkProperties.interfaceName ?: continue
                val networkInterface = javaInterfaces.find { it.name == interfaceName } ?: continue

                val item = BoxNetworkInterface().apply {
                    name = interfaceName
                    index = networkInterface.index
                    mtu = runCatching { networkInterface.mtu }.getOrDefault(1500)
                    type = when {
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                        else -> Libbox.InterfaceTypeOther
                    }
                    addresses = StringArray(
                        networkInterface.interfaceAddresses.mapNotNull { address ->
                            val host = cleanHostAddress(address.address) ?: return@mapNotNull null
                            "$host/${address.networkPrefixLength}"
                        },
                    )
                    dnsServer = StringArray(linkProperties.dnsServers.mapNotNull(::cleanHostAddress))
                    metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                    flags = buildInterfaceFlags(networkInterface, capabilities)
                }
                Log.d(
                    TAG,
                    "network interface: ${item.name}/${item.index} addresses=${item.addresses.len()} dns=${item.dnsServer.len()}",
                )
                items.add(item)
            }

            return NetworkInterfaceArray(items)
        }

        override fun underNetworkExtension(): Boolean = false

        override fun includeAllNetworks(): Boolean = false

        override fun clearDNSCache() {
        }

        override fun readWIFIState(): WIFIState = WIFIState("", "")

        override fun localDNSTransport(): LocalDNSTransport? = null

        override fun systemCertificates(): StringIterator {
            val certificates = mutableListOf<String>()
            runCatching {
                val keyStore = KeyStore.getInstance("AndroidCAStore")
                keyStore.load(null, null)
                val aliases = keyStore.aliases()
                while (aliases.hasMoreElements()) {
                    val certificate = keyStore.getCertificate(aliases.nextElement())
                    certificates.add(
                        "-----BEGIN CERTIFICATE-----\n" +
                            Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(certificate.encoded) +
                            "\n-----END CERTIFICATE-----",
                    )
                }
            }.onFailure {
                Log.w(TAG, "Failed to read Android certificates", it)
            }
            return StringArray(certificates)
        }

        override fun sendNotification(notification: Notification) {
            Log.d(TAG, "libbox notification: ${notification.title} ${notification.body}")
        }

        private fun addAddresses(builder: VpnService.Builder, iterator: RoutePrefixIterator) {
            while (iterator.hasNext()) {
                val route = iterator.next()
                builder.addAddress(route.address(), route.prefix())
            }
        }

        private fun addRoutes(builder: VpnService.Builder, iterator: RoutePrefixIterator) {
            while (iterator.hasNext()) {
                val route = iterator.next()
                builder.addRoute(route.address(), route.prefix())
            }
        }

        private fun excludeRoutes(builder: VpnService.Builder, iterator: RoutePrefixIterator) {
            while (iterator.hasNext()) {
                val route = iterator.next()
                builder.excludeRoute(android.net.IpPrefix(InetAddress.getByName(route.address()), route.prefix()))
            }
        }

        private fun addDnsServers(builder: VpnService.Builder, dnsServers: StringBox) {
            val raw = dnsServers.value ?: return
            raw.split('\n', ',', ' ')
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .forEach { builder.addDnsServer(it) }
        }

        private fun addAllowedPackages(builder: VpnService.Builder, iterator: StringIterator) {
            while (iterator.hasNext()) {
                runCatching { builder.addAllowedApplication(iterator.next()) }
            }
        }

        private fun addDisallowedPackages(builder: VpnService.Builder, iterator: StringIterator) {
            while (iterator.hasNext()) {
                runCatching { builder.addDisallowedApplication(iterator.next()) }
            }
        }

        private fun cleanHostAddress(address: InetAddress?): String? {
            val host = when (address) {
                null -> return null
                is Inet6Address -> Inet6Address.getByAddress(address.address).hostAddress
                else -> address.hostAddress
            }

            return host
                ?.substringBefore('%')
                ?.takeIf { it.isNotBlank() }
        }

        private fun buildInterfaceFlags(
            networkInterface: NetworkInterface,
            capabilities: NetworkCapabilities,
        ): Int {
            var flags = 0
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (networkInterface.isLoopback) {
                flags = flags or OsConstants.IFF_LOOPBACK
            }
            if (networkInterface.isPointToPoint) {
                flags = flags or OsConstants.IFF_POINTOPOINT
            }
            if (networkInterface.supportsMulticast()) {
                flags = flags or OsConstants.IFF_MULTICAST
            }
            return flags
        }

        private fun updateDefaultInterface(listener: InterfaceUpdateListener) {
            val connectivity =
                service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = buildList {
                connectivity.activeNetwork?.let { add(it) }
                addAll(connectivity.allNetworks.filterNot { it == connectivity.activeNetwork })
            }

            for (network in networks) {
                val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    continue
                }
                if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                    continue
                }
                val interfaceName = connectivity.getLinkProperties(network)?.interfaceName ?: continue
                val index = runCatching { NetworkInterface.getByName(interfaceName).index }.getOrNull()
                    ?: continue
                listener.updateDefaultInterface(interfaceName, index, false, false)
                Log.d(TAG, "default interface: $interfaceName/$index")
                return
            }

            listener.updateDefaultInterface("", -1, false, false)
            Log.w(TAG, "default interface not found")
        }
    }

    private class StringArray(private val values: List<String>) : StringIterator {
        private val iterator = values.iterator()

        override fun len(): Int = values.size

        override fun hasNext(): Boolean = iterator.hasNext()

        override fun next(): String = iterator.next()
    }

    private class NetworkInterfaceArray(private val values: List<BoxNetworkInterface>) : NetworkInterfaceIterator {
        private val iterator = values.iterator()

        override fun hasNext(): Boolean = iterator.hasNext()

        override fun next(): BoxNetworkInterface = iterator.next()
    }
}
