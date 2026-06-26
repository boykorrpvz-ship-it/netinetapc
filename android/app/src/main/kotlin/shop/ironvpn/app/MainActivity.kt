package shop.ironvpn.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "shop.ironvpn/vpn"
    private var pendingPrepareResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceId" -> result.success(stableDeviceId())
                    "prepare" -> prepareVpn(result)
                    "start" -> {
                        val configJson = call.argument<String>("configJson").orEmpty()
                        val profileName = call.argument<String>("profileName").orEmpty()
                        val protocol = call.argument<String>("protocol").orEmpty()
                        val routeRussianServicesDirect =
                            call.argument<Boolean>("routeRussianServicesDirect") ?: true
                        result.success(
                            startTunnel(
                                configJson,
                                profileName,
                                protocol,
                                routeRussianServicesDirect,
                            ),
                        )
                    }
                    "stop" -> {
                        stopTunnels()
                        result.success(currentVpnState(reconcile = false))
                    }
                    "status" -> result.success(currentVpnState(reconcile = true))
                    else -> result.notImplemented()
                }
            }
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }

        pendingPrepareResult = result
        startActivityForResult(intent, REQUEST_VPN_PREPARE)
    }

    @Deprecated("Deprecated by Android, still compatible with FlutterActivity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN_PREPARE) {
            pendingPrepareResult?.success(resultCode == Activity.RESULT_OK)
            pendingPrepareResult = null
        }
    }

    private fun startTunnel(
        configJson: String,
        profileName: String,
        protocol: String,
        routeRussianServicesDirect: Boolean,
    ): String {
        startVpn(configJson, profileName, protocol, routeRussianServicesDirect)
        return currentVpnState(reconcile = false)
    }

    private fun startVpn(
        configJson: String,
        profileName: String,
        protocol: String,
        routeRussianServicesDirect: Boolean,
    ) {
        maybeRequestBatteryExemption()
        VpnStateStore.set(this, "connecting")
        VpnStateStore.setProtocol(this, protocol)
        val intent = Intent(this, serviceClassFor(protocol)).apply {
            action = IronVpnService.ACTION_START
            putExtra(IronVpnService.EXTRA_CONFIG_JSON, configJson)
            putExtra(IronVpnService.EXTRA_PROFILE_NAME, profileName)
            putExtra(IronVpnService.EXTRA_PROTOCOL, protocol)
            putExtra(
                IronVpnService.EXTRA_ROUTE_RUSSIAN_SERVICES_DIRECT,
                routeRussianServicesDirect,
            )
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Throwable) {
            // Some OEMs (notably MIUI) can refuse to launch a service whose
            // process they have flagged as "bad" after repeated background
            // kills, throwing SecurityException("process is bad"). Surface a
            // clean error state instead of letting the exception cross the
            // MethodChannel as an unhandled failure.
            Log.e(TAG, "Failed to start VPN service", error)
            VpnStateStore.set(this, "error")
        }
    }

    // Asks the system (once) to exempt the app from battery optimization so OEM
    // power managers (notably MIUI) are less likely to kill the background VPN
    // process. Reducing those kills is what keeps the process from being flagged
    // a "bad process" and refused a start ("Ошибка запуска"). Note: MIUI's
    // separate "Autostart" permission can only be granted by the user in system
    // settings — this just covers the standard battery-optimization side.
    @SuppressLint("BatteryLife")
    private fun maybeRequestBatteryExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (power.isIgnoringBatteryOptimizations(packageName)) {
            return
        }
        val prefs = getSharedPreferences("vpn_prefs", Context.MODE_PRIVATE)
        if (prefs.getBoolean("battery_opt_asked", false)) {
            return
        }
        prefs.edit().putBoolean("battery_opt_asked", true).apply()
        runCatching {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }.onFailure { Log.w(TAG, "Battery optimization request failed", it) }
    }

    private fun stopTunnels() {
        VpnStateStore.set(this, "disconnecting")
        stopVpn()
    }

    private fun stopVpn() {
        val protocol = VpnStateStore.getProtocol(this)
        val intent = Intent(this, serviceClassFor(protocol)).apply {
            action = IronVpnService.ACTION_STOP
        }
        startService(intent)
    }

    // Routes a start/stop intent to the per-protocol service process. AmneziaWG
    // and sing-box each run in their own process so their Go runtimes never
    // share a process (which would crash natively on a type switch).
    private fun serviceClassFor(protocol: String?): Class<*> {
        return if (protocol == PROTOCOL_AMNEZIA_WG) {
            AwgVpnService::class.java
        } else {
            BoxVpnService::class.java
        }
    }

    private fun currentVpnState(reconcile: Boolean): String {
        val stored = VpnStateStore.get(this)
        if (!reconcile) {
            return stored
        }

        val running = SingBoxBridge.isRunning() || AmneziaWgBridge.isRunning()
        val systemVpnActive = isSystemVpnActive()
        if (running || systemVpnActive) {
            if (stored == "disconnecting") {
                return stored
            }
            if (stored != "connected") {
                VpnStateStore.set(this, "connected")
            }
            return "connected"
        }

        if (stored == "connecting" || stored == "disconnecting") {
            val updatedAt = VpnStateStore.updatedAt(this)
            val elapsedMs = System.currentTimeMillis() - updatedAt
            if (updatedAt > 0L && elapsedMs < TRANSIENT_STATE_TTL_MS) {
                return stored
            }
        }

        if (stored == "connected" || stored == "connecting" || stored == "disconnecting") {
            VpnStateStore.set(this, "disconnected")
            return "disconnected"
        }

        return stored
    }

    private fun isSystemVpnActive(): Boolean {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return manager.allNetworks.any { network ->
            val capabilities = manager.getNetworkCapabilities(network) ?: return@any false
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }

    private fun stableDeviceId(): String {
        val androidId = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ANDROID_ID,
        ).orEmpty()
        return if (androidId.isBlank()) "" else "android_$androidId"
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val REQUEST_VPN_PREPARE = 4201
        private const val TRANSIENT_STATE_TTL_MS = 8_000L
        private const val PROTOCOL_AMNEZIA_WG = "amneziawg"
    }
}
