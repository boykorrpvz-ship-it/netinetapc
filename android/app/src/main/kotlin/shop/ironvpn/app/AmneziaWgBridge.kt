package shop.ironvpn.app

import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.system.OsConstants
import android.util.Log
import org.amnezia.awg.config.Config
import java.io.ByteArrayInputStream
import java.net.Inet6Address
import java.net.InetAddress
import java.net.Inet4Address

object AmneziaWgBridge {
    private const val TAG = "AmneziaWgBridge"
    private const val DEFAULT_MTU = 1280

    init {
        System.loadLibrary("am")
        System.loadLibrary("am-quick")
        System.loadLibrary("am-go")
    }

    @Volatile
    private var tunnelHandle = -1

    @Synchronized
    fun isRunning(): Boolean = tunnelHandle >= 0

    @Synchronized
    fun start(
        service: VpnService,
        configText: String,
        profileName: String,
        routeRussianServicesDirect: Boolean,
    ) {
        stop()

        if (VpnService.prepare(service) != null) {
            error("android: missing vpn permission")
        }

        val config = ByteArrayInputStream(configText.toByteArray(Charsets.UTF_8)).use {
            Config.parse(it)
        }
        val tunnelName = profileName.toTunnelName()
        val awgQuickConfig = config.toAwgQuickStringResolved(false, false, true, service)
        val directAddresses = if (routeRussianServicesDirect) {
            resolveDirectServiceAddresses()
        } else {
            emptySet()
        }
        val builder = service.Builder()
            .setSession(tunnelName)

        addApplications(builder, config)
        addAddresses(builder, config)
        addDns(builder, config)
        addRoutes(builder, config, directAddresses)

        builder.setMtu(config.`interface`.mtu.orElse(DEFAULT_MTU))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
            builder.setBlocking(true)
        }
        builder.setUnderlyingNetworks(null)

        val descriptor = builder.establish() ?: error("android: failed to establish vpn")
        var detachedFd: Int? = null
        try {
            detachedFd = descriptor.detachFd()
            val nextHandle = org.amnezia.awg.GoBackend.awgTurnOn(
                tunnelName,
                detachedFd,
                awgQuickConfig,
                service.dataDir.absolutePath,
            )
            if (nextHandle < 0) {
                error("amneziawg: failed to start native backend, code=$nextHandle")
            }

            detachedFd = null
            tunnelHandle = nextHandle
            protectSocket(service, org.amnezia.awg.GoBackend.awgGetSocketV4(nextHandle))
            protectSocket(service, org.amnezia.awg.GoBackend.awgGetSocketV6(nextHandle))
            Log.i(TAG, "AmneziaWG started: $tunnelName")
        } catch (error: Throwable) {
            detachedFd?.let {
                runCatching { android.os.ParcelFileDescriptor.adoptFd(it).close() }
            }
            stop()
            throw error
        } finally {
            runCatching { descriptor.close() }
        }
    }

    @Synchronized
    fun stop() {
        val activeHandle = tunnelHandle
        if (activeHandle < 0) {
            return
        }

        tunnelHandle = -1
        runCatching {
            org.amnezia.awg.GoBackend.awgTurnOff(activeHandle)
        }.onFailure {
            Log.w(TAG, "Failed to stop AmneziaWG", it)
        }
    }

    private fun addApplications(builder: VpnService.Builder, config: Config) {
        for (packageName in config.`interface`.excludedApplications) {
            runCatching { builder.addDisallowedApplication(packageName) }
        }
        for (packageName in config.`interface`.includedApplications) {
            runCatching { builder.addAllowedApplication(packageName) }
        }
    }

    private fun addAddresses(builder: VpnService.Builder, config: Config) {
        for (address in config.`interface`.addresses) {
            builder.addAddress(address.address, address.mask)
        }
    }

    private fun addDns(builder: VpnService.Builder, config: Config) {
        for (server in config.`interface`.dnsServers) {
            val host = cleanHostAddress(server) ?: continue
            builder.addDnsServer(host)
        }
        for (domain in config.`interface`.dnsSearchDomains) {
            builder.addSearchDomain(domain)
        }
    }

    private fun addRoutes(
        builder: VpnService.Builder,
        config: Config,
        directAddresses: Set<InetAddress>,
    ) {
        var hasDefaultRoute = false
        val legacyExcludedIpv4 = directAddresses.filterIsInstance<Inet4Address>().toSet()

        for (peer in config.peers) {
            for (route in peer.allowedIps) {
                if (route.mask == 0) {
                    hasDefaultRoute = true
                }

                if (
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU &&
                    legacyExcludedIpv4.isNotEmpty() &&
                    route.address is Inet4Address &&
                    route.mask == 0
                ) {
                    addIpv4RoutesExcluding(builder, legacyExcludedIpv4)
                    continue
                }

                builder.addRoute(route.address, route.mask)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            for (address in directAddresses) {
                val prefixLength = if (address is Inet6Address) 128 else 32
                runCatching {
                    builder.excludeRoute(IpPrefix(address, prefixLength))
                }.onFailure {
                    Log.w(TAG, "Failed to exclude direct route for $address", it)
                }
            }
        }

        if (!hasDefaultRoute || config.peers.size != 1) {
            builder.allowFamily(OsConstants.AF_INET)
            builder.allowFamily(OsConstants.AF_INET6)
        }
    }

    private fun resolveDirectServiceAddresses(): Set<InetAddress> {
        val addresses = linkedSetOf<InetAddress>()
        for (domain in DIRECT_SERVICE_DOMAINS) {
            runCatching {
                InetAddress.getAllByName(domain).forEach(addresses::add)
            }.onFailure {
                Log.w(TAG, "Failed to resolve direct service domain: $domain", it)
            }
        }
        Log.i(TAG, "Resolved ${addresses.size} direct service addresses")
        return addresses
    }

    private fun addIpv4RoutesExcluding(
        builder: VpnService.Builder,
        excluded: Set<Inet4Address>,
    ) {
        val blocked = excluded
            .map(::ipv4ToLong)
            .distinct()
            .sorted()
        var cursor = 0L
        val maxAddress = 0xffffffffL

        for (address in blocked) {
            if (cursor < address) {
                addIpv4Range(builder, cursor, address - 1)
            }
            if (address == maxAddress) {
                cursor = maxAddress + 1
                break
            }
            cursor = address + 1
        }

        if (cursor <= maxAddress) {
            addIpv4Range(builder, cursor, maxAddress)
        }
    }

    private fun addIpv4Range(
        builder: VpnService.Builder,
        firstAddress: Long,
        lastAddress: Long,
    ) {
        var start = firstAddress
        while (start <= lastAddress) {
            var blockSize = if (start == 0L) {
                1L shl 32
            } else {
                start and -start
            }
            val remaining = lastAddress - start + 1
            while (blockSize > remaining) {
                blockSize = blockSize shr 1
            }

            val prefixLength =
                32 - java.lang.Long.numberOfTrailingZeros(blockSize)
            builder.addRoute(longToIpv4(start), prefixLength)
            start += blockSize
        }
    }

    private fun ipv4ToLong(address: Inet4Address): Long {
        return address.address.fold(0L) { value, byte ->
            (value shl 8) or (byte.toInt() and 0xff).toLong()
        }
    }

    private fun longToIpv4(value: Long): InetAddress {
        val bytes = byteArrayOf(
            ((value shr 24) and 0xff).toByte(),
            ((value shr 16) and 0xff).toByte(),
            ((value shr 8) and 0xff).toByte(),
            (value and 0xff).toByte(),
        )
        return InetAddress.getByAddress(bytes)
    }

    private fun protectSocket(service: VpnService, socketFd: Int) {
        if (socketFd >= 0 && !service.protect(socketFd)) {
            Log.w(TAG, "Failed to protect AmneziaWG socket fd=$socketFd")
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

    private fun String.toTunnelName(): String {
        val cleaned = filter { it.isLetterOrDigit() || it == '_' || it == '-' }
            .take(15)
        return cleaned.ifBlank { "IronAWG" }
    }

    private val DIRECT_SERVICE_DOMAINS = listOf(
        "ozon.ru",
        "wildberries.ru",
        "avito.ru",
        "gosuslugi.ru",
        "yandex.ru",
        "ya.ru",
        "vk.com",
        "ok.ru",
        "mail.ru",
        "sberbank.ru",
        "tbank.ru",
        "tinkoff.ru",
        "alfabank.ru",
        "vtb.ru",
        "2ip.ru",
        "www.2ip.ru",
        "faceit.com",
        "steamcommunity.com",
        "steampowered.com",
        "steamstatic.com",
    )
}
