package shop.ironvpn.app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.provider.Settings
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
                        result.success(currentVpnState())
                    }
                    "status" -> result.success(currentVpnState())
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
        return currentVpnState()
    }

    private fun startVpn(
        configJson: String,
        profileName: String,
        protocol: String,
        routeRussianServicesDirect: Boolean,
    ) {
        VpnStateStore.set(this, "connecting")
        val intent = Intent(this, IronVpnService::class.java).apply {
            action = IronVpnService.ACTION_START
            putExtra(IronVpnService.EXTRA_CONFIG_JSON, configJson)
            putExtra(IronVpnService.EXTRA_PROFILE_NAME, profileName)
            putExtra(IronVpnService.EXTRA_PROTOCOL, protocol)
            putExtra(
                IronVpnService.EXTRA_ROUTE_RUSSIAN_SERVICES_DIRECT,
                routeRussianServicesDirect,
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopTunnels() {
        VpnStateStore.set(this, "disconnecting")
        stopVpn()
    }

    private fun stopVpn() {
        val intent = Intent(this, IronVpnService::class.java).apply {
            action = IronVpnService.ACTION_STOP
        }
        startService(intent)
    }

    private fun currentVpnState(): String {
        return VpnStateStore.get(this)
    }

    private fun stableDeviceId(): String {
        val androidId = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ANDROID_ID,
        ).orEmpty()
        return if (androidId.isBlank()) "" else "android_$androidId"
    }

    companion object {
        private const val REQUEST_VPN_PREPARE = 4201
    }
}
