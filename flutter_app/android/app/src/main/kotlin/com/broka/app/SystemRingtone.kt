package com.broka.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * Plays the user's OWN ringtone for an incoming BROKA call.
 *
 * Previously the app shipped a bundled two-tone chime (assets/audio/
 * ringtone.mp3) and played it through audioplayers for every incoming call,
 * on every device, regardless of what the user had configured. Three things
 * were wrong with that beyond it simply not being their ringtone:
 *
 *  - It ignored ringer mode. Silent and vibrate-only were not honoured, so
 *    a phone explicitly set to silent would still make noise. audioplayers'
 *    AndroidUsageType.notificationRingtone routes to the ring stream but
 *    does not by itself implement the silent/vibrate policy.
 *  - It never vibrated. A phone on vibrate gave no indication at all.
 *  - A user cannot recognise it. Part of what makes a ringtone useful is
 *    that you know it is YOUR phone, and which app.
 *
 * RingtoneManager.getActualDefaultRingtoneUri(TYPE_RINGTONE) is the exact
 * sound the user picked in Settings > Sound > Phone ringtone, so this
 * resolves to whatever they chose, including a custom file.
 *
 * Deliberately not a new Flutter package: the project's pubspec already
 * carries unverified version guesses, and this needs ~80 lines of the
 * platform API it would be wrapping anyway.
 */
object SystemRingtone {
    private const val TAG = "BrokaRingtone"

    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var loopWatchdog: Runnable? = null

    // Roughly the cadence of a standard phone ring: buzz, pause, repeat.
    private val VIBRATE_PATTERN = longArrayOf(0, 1000, 1000)

    /**
     * @return true if anything at all was started (sound OR vibration), so
     *         the Dart side knows whether it still needs its own fallback.
     *         Silent mode returns true as well: the phone is doing exactly
     *         what its owner asked, which is not a failure to fall back
     *         from.
     */
    fun play(context: Context): Boolean {
        stop(context)
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return false

        return when (audio.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> {
                Log.i(TAG, "ringer is silent - not ringing")
                true
            }
            AudioManager.RINGER_MODE_VIBRATE -> {
                startVibration(context)
                true
            }
            else -> {
                val sound = startRingtone(context)
                // Vibrate alongside the ringtone, as the system dialer does.
                startVibration(context)
                sound || vibrator != null
            }
        }
    }

    private fun startRingtone(context: Context): Boolean {
        val uri: Uri = RingtoneManager
            .getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE)
            // A device with no ringtone configured at all (rare, but real on
            // some stripped ROMs and on emulators) would otherwise ring with
            // nothing. Fall through to the notification sound rather than
            // silence.
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: return false

        return try {
            val r = RingtoneManager.getRingtone(context, uri) ?: return false
            r.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                r.isLooping = true
            }
            r.play()
            ringtone = r

            // Ringtone.isLooping only exists from API 28. Below that a
            // ringtone plays once and stops, which for an incoming call
            // means it rings for four seconds and then the phone goes quiet
            // while still ringing on the caller's end. Poll and restart.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                val tick = object : Runnable {
                    override fun run() {
                        val current = ringtone ?: return
                        if (!current.isPlaying) {
                            try { current.play() } catch (e: Exception) {
                                Log.w(TAG, "loop restart failed: ${e.message}")
                            }
                        }
                        handler.postDelayed(this, 500)
                    }
                }
                loopWatchdog = tick
                handler.postDelayed(tick, 500)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "could not play system ringtone: ${e.message}")
            false
        }
    }

    private fun startVibration(context: Context) {
        try {
            val v: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val mgr = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                        as? VibratorManager
                mgr?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (v == null || !v.hasVibrator()) return

            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // repeat index 0 == loop the whole pattern until cancelled.
                v.vibrate(VibrationEffect.createWaveform(VIBRATE_PATTERN, 0), attrs)
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(VIBRATE_PATTERN, 0, attrs)
            }
            vibrator = v
        } catch (e: Exception) {
            Log.w(TAG, "could not vibrate: ${e.message}")
        }
    }

    fun stop(context: Context) {
        loopWatchdog?.let { handler.removeCallbacks(it) }
        loopWatchdog = null
        try { ringtone?.stop() } catch (e: Exception) {
            Log.w(TAG, "ringtone stop failed: ${e.message}")
        }
        ringtone = null
        try { vibrator?.cancel() } catch (e: Exception) {
            Log.w(TAG, "vibrator cancel failed: ${e.message}")
        }
        vibrator = null
    }
}
