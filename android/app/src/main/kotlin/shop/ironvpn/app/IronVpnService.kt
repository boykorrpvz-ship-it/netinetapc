package shop.ironvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log

class IronVpnService : VpnService() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startTunnel(intent)
            ACTION_STOP -> stopTunnel()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun startTunnel(intent: Intent) {
        val configJson = intent.getStringExtra(EXTRA_CONFIG_JSON).orEmpty()
        val profileName = intent.getStringExtra(EXTRA_PROFILE_NAME).orEmpty().ifBlank { "IronVPN" }

        state = "connecting"
        startForeground(NOTIFICATION_ID, notification("Запуск $profileName"))

        if (!SingBoxBridge.isAvailable()) {
            Log.e(TAG, "VPN core is not available")
            state = "unsupported"
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        try {
            SingBoxBridge.start(this, configJson)
            state = "connected"
            startForeground(NOTIFICATION_ID, notification("$profileName подключён"))
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to start VPN", error)
            state = "error"
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun stopTunnel() {
        state = "disconnecting"
        SingBoxBridge.stop()
        state = "disconnected"
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun notification(text: String): Notification {
        ensureNotificationChannel()
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle("IronVPN")
                .setContentText(text)
                .setContentIntent(openIntent)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle("IronVPN")
                .setContentText(text)
                .setContentIntent(openIntent)
                .setOngoing(true)
                .build()
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "IronVPN connection",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    companion object {
        private const val TAG = "IronVpnService"

        const val ACTION_START = "shop.ironvpn.app.START"
        const val ACTION_STOP = "shop.ironvpn.app.STOP"
        const val EXTRA_CONFIG_JSON = "configJson"
        const val EXTRA_PROFILE_NAME = "profileName"

        private const val CHANNEL_ID = "ironvpn_connection"
        private const val NOTIFICATION_ID = 7101

        @Volatile
        var state: String = "disconnected"
    }
}
