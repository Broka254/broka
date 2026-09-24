package com.broka.app

import android.content.ActivityNotFoundException
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
    private val SHARE_CHANNEL = "com.broka.app/share"

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

        // ── Sharing (store links) ────────────────────────────────────────
        // A plain ACTION_SEND rather than a share plugin: CI builds with a
        // pinned Flutter/AGP, and this is the whole of what's needed.
        //   shareText {text, subject?, package?, title?} - with a package,
        //     sends straight to that app ("unavailable" if it isn't
        //     installed, so Dart can fall back); without one, opens the
        //     system share sheet.
        //   openApp {package} - just opens an app (TikTok, whose share
        //     target doesn't take a link).
        // startActivity isn't subject to Android 11 package-visibility
        // filtering, so no <queries> entries are needed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "shareText" -> {
                            val text = call.argument<String>("text") ?: ""
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                call.argument<String>("subject")?.let {
                                    putExtra(Intent.EXTRA_SUBJECT, it)
                                }
                            }
                            val pkg = call.argument<String>("package")
                            if (pkg != null) {
                                send.setPackage(pkg)
                                startActivity(send)
                            } else {
                                startActivity(Intent.createChooser(
                                    send, call.argument<String>("title") ?: "Share"))
                            }
                            result.success("shared")
                        }
                        "openApp" -> {
                            val pkg = call.argument<String>("package")
                            if (pkg == null) {
                                result.success("unavailable")
                            } else {
                                startActivity(Intent(Intent.ACTION_MAIN)
                                    .addCategory(Intent.CATEGORY_LAUNCHER)
                                    .setPackage(pkg)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                result.success("opened")
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: ActivityNotFoundException) {
                    result.success("unavailable")
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
