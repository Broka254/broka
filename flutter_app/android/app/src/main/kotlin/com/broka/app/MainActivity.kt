package com.broka.app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CALL_SERVICE_CHANNEL = "com.broka.app/call_service"
    private val RINGTONE_CHANNEL = "com.broka.app/ringtone"
    private val SMS_RETRIEVER_CHANNEL = "com.broka.app/sms_retriever"
    private val SMS_RETRIEVER_EVENTS = "com.broka.app/sms_retriever_events"

    private var smsRetriever: SmsRetrieverBridge? = null

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

        // ── OTP auto-capture (SMS Retriever API) ─────────────────────────
        // Lets the verify-code screen fill itself with no prompt and no SMS
        // permission. See SmsRetrieverBridge.kt and
        // lib/services/sms_autofill_service.dart.
        val sms = SmsRetrieverBridge(applicationContext)
        smsRetriever = sms

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_RETRIEVER_EVENTS)
            .setStreamHandler(sms)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_RETRIEVER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppSignature" -> result.success(SmsRetrieverBridge.appSignature(applicationContext))
                    "start" -> sms.start { ok -> result.success(ok) }
                    "stop" -> {
                        sms.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // The receiver is registered against the application context, so
        // without this it would outlive the activity on a config change.
        smsRetriever?.stop()
        smsRetriever = null
        super.onDestroy()
    }
}
