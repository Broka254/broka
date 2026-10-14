package com.broka.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Keeps a BROKA call alive when the screen turns off or the app otherwise
 * loses foreground mid-call.
 *
 * Why this exists: from Android 9 (API 28) onward, an app that is not in
 * the foreground - and not running a foreground service - loses access to
 * the microphone and camera outright. On top of that, Doze/App Standby can
 * throttle a background app's network sockets, which would break call
 * signalling over the WebSocket. Neither of those can be fixed from Dart or
 * flutter_webrtc alone; a real foreground service is the documented, correct
 * fix, and is exactly what this class provides for the lifetime of a call.
 *
 * It does two things while a call is active:
 *  1. Runs as a foreground service, declaring the "microphone"/"camera"
 *     types Android 14+ requires, which exempts the app from the background
 *     mic/camera/network restrictions described above.
 *  2. Holds a partial wake lock so the CPU keeps running the WebRTC and
 *     signalling code even with the screen off. This does NOT force the
 *     screen itself to stay on - that's normal, expected behaviour for a
 *     phone call (screen off, audio/video keeps going).
 */
class CallForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val EXTRA_PEER_NAME = "peerName"
        const val EXTRA_IS_VIDEO = "isVideo"
        private const val TAG = "BrokaCallService"
        private const val CHANNEL_ID = "broka_call_service"
        private const val NOTIFICATION_ID = 7721
        private const val WAKE_LOCK_TIMEOUT_MS = 30 * 60 * 1000L // 30 min safety cap
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent is the system recreating the service after the
        // process died. The call died with the process (its peer connection
        // and signalling lived in Dart), so there is nothing to keep alive -
        // and starting a microphone service from the background is refused
        // on Android 14+, which would crash the app again on the way up.
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val peerName = intent.getStringExtra(EXTRA_PEER_NAME) ?: "Call"
        val isVideo = intent.getBooleanExtra(EXTRA_IS_VIDEO, false)

        if (!startForegroundWithNotification(peerName, isVideo)) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        acquireWakeLock()

        // Not sticky: see the null-intent case above.
        return START_NOT_STICKY
    }

    private fun isGranted(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * @return false if Android refused the foreground service. The service
     *         must then stop: the call carries on, just without protection
     *         from the screen locking.
     */
    private fun startForegroundWithNotification(peerName: String, isVideo: Boolean): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ongoing call",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shown while a BROKA call is active"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val label = if (isVideo) "Video call" else "Voice call"
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("BROKA $label in progress")
            .setContentText("Call with $peerName")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .build()

        // On Android 14+ each type is only allowed while its runtime
        // permission is granted; asking for one that isn't throws
        // SecurityException right here and the OS kills the whole app (MIUI
        // then shows "BROKA should be granted Microphone access"). So the
        // camera type is claimed only when the camera was actually granted:
        // a video call whose camera was denied runs audio-only.
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (isVideo && isGranted(Manifest.permission.CAMERA)) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            // SecurityException (microphone not granted, or the app went to
            // the background before the service came up) or, on Android
            // 12+, ForegroundServiceStartNotAllowedException.
            Log.w(TAG, "call service refused: ${e.message}")
            false
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "BrokaApp:CallWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
            // Already released - safe to ignore.
        }
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The user swiped BROKA away from recents mid-call - the call UI is
        // already gone, so don't leave a zombie foreground service or wake
        // lock running behind it.
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}
