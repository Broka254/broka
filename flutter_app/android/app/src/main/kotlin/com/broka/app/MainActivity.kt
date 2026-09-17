package com.broka.app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CALL_SERVICE_CHANNEL = "com.broka.app/call_service"
    private val RINGTONE_CHANNEL = "com.broka.app/ringtone"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RINGTONE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Returns true if the device did something (rang, or
                    // vibrated, or is deliberately silent). Dart falls back
                    // to the bundled tone only on false, so a genuine
                    // silent-mode phone is never overridden.
                    "play" -> result.success(SystemRingtone.play(applicationContext))
                    "stop" -> {
                        SystemRingtone.stop(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_SERVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val peerName = call.argument<String>("peerName") ?: "Call"
                        val isVideo = call.argument<Boolean>("isVideo") ?: false
                        val intent = Intent(this, CallForegroundService::class.java).apply {
                            putExtra(CallForegroundService.EXTRA_PEER_NAME, peerName)
                            putExtra(CallForegroundService.EXTRA_IS_VIDEO, isVideo)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, CallForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
