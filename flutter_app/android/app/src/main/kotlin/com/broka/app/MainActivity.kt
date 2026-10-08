package com.broka.app

import android.Manifest
import android.app.KeyguardManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterFragmentActivity() {
    private val CALL_SERVICE_CHANNEL = "com.broka.app/call_service"
    private val RINGTONE_CHANNEL = "com.broka.app/ringtone"
    private val SMS_RETRIEVER_CHANNEL = "com.broka.app/sms_retriever"
    private val SMS_RETRIEVER_EVENTS = "com.broka.app/sms_retriever_events"
    private val SHARE_CHANNEL = "com.broka.app/share"
    private val LINKS_CHANNEL = "com.broka.app/links"

    private var linksChannel: MethodChannel? = null
    // The store link that launched the app, handed to Dart once.
    private var initialLinkConsumed = false

    private var smsRetriever: SmsRetrieverBridge? = null

    // A call screen is open in Dart (call_service "overLockScreen"). While
    // it is, the app shows over the lock screen - and only then.
    private var callOnScreen = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreation (savedInstanceState) is not a new launch: nothing to
        // unlock for.
        applyLockScreenPolicy(intent, freshLaunch = savedInstanceState == null)
    }

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
                        // The service runs with the microphone type, which
                        // Android 14+ refuses without RECORD_AUDIO - by
                        // throwing inside the service, which kills the app.
                        // Dart starts it only once the mic is open; this is
                        // the backstop. false = not started, the call goes
                        // on without screen-lock protection.
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                                != PackageManager.PERMISSION_GRANTED) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val peerName = call.argument<String>("peerName") ?: "Call"
                        val isVideo = call.argument<Boolean>("isVideo") ?: false
                        val intent = Intent(this, CallForegroundService::class.java).apply {
                            putExtra(CallForegroundService.EXTRA_PEER_NAME, peerName)
                            putExtra(CallForegroundService.EXTRA_IS_VIDEO, isVideo)
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // Android 12+ refuses a foreground service
                            // started while the app is in the background.
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, CallForegroundService::class.java))
                        result.success(null)
                    }
                    // The call screen opened (true) or the last one closed
                    // (false) - see applyLockScreenPolicy.
                    "overLockScreen" -> {
                        callOnScreen = call.argument<Boolean>("on") ?: false
                        showOverLockScreen(callOnScreen, turnScreenOn = false)
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

        // ── Store links (lib/services/deep_link_service.dart) ───────────
        //   getInitialLink - the https link this activity was started with,
        //     once; null afterwards (and for a normal launcher start).
        //   onLink (to Dart) - a link that arrived while the app was running.
        linksChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINKS_CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getInitialLink" -> {
                            val link = if (initialLinkConsumed) null else viewLink(intent)
                            initialLinkConsumed = true
                            result.success(link)
                        }
                        else -> result.notImplemented()
                    }
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyLockScreenPolicy(intent, freshLaunch = true)
        viewLink(intent)?.let { linksChannel?.invokeMethod("onLink", it) }
    }

    // ── Over the lock screen: calls only ─────────────────────────────────
    // The manifest declares showWhenLocked/turnScreenOn. That declaration is
    // what lets Android open the app over the lock screen for a ringing call
    // - the notification's full-screen intent, and Accept pressed on a
    // locked phone, which Android otherwise answers with "unlock first".
    // But it applied all the time: anyone picking up a locked phone that was
    // last left in BROKA got BROKA - chats, payments - without unlocking.
    // So it is overridden here: on for an incoming call's notification, and
    // while a call screen is open (Dart tells us); off otherwise.

    private fun applyLockScreenPolicy(intent: Intent?, freshLaunch: Boolean) {
        // Only a call arriving now: not the intent a recreated activity
        // still holds, nor one replayed when the app is reopened from
        // Recents - that call is long over.
        val call = freshLaunch && isIncomingCallIntent(intent)
        showOverLockScreen(call || callOnScreen, turnScreenOn = call)
        // Any other notification opened from the lock screen (a message, a
        // deal update) is let through by the same declaration - ask to
        // unlock, as for any app, instead of leaving it hidden behind the
        // lock screen with nothing happening.
        if (freshLaunch && !call && !callOnScreen) askToUnlock()
    }

    /** A tap on, the full-screen launch of, or Accept on an incoming-call
     * notification (flutter_local_notifications' launch intents, whose
     * payload NotificationService writes). */
    private fun isIncomingCallIntent(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        if (action != "SELECT_NOTIFICATION" && action != "SELECT_FOREGROUND_NOTIFICATION") {
            return false
        }
        val payload = intent.getStringExtra("payload") ?: return false
        return try {
            JSONObject(payload).optString("type") == "incoming_call"
        } catch (e: Exception) {
            false
        }
    }

    private fun showOverLockScreen(on: Boolean, turnScreenOn: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on && turnScreenOn)
        } else {
            // Before Android 8.1 the manifest attributes don't exist; these
            // flags are how it was done.
            @Suppress("DEPRECATION")
            val show = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
            @Suppress("DEPRECATION")
            val wake = WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(show) else window.clearFlags(show)
            if (on && turnScreenOn) window.addFlags(wake) else window.clearFlags(wake)
        }
    }

    private fun askToUnlock() {
        val keyguard = getSystemService(KeyguardManager::class.java) ?: return
        if (!keyguard.isKeyguardLocked) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            keyguard.requestDismissKeyguard(this, null)
        }
    }

    /** The https link an ACTION_VIEW intent carries, if any. */
    private fun viewLink(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        return if (data.scheme == "https") data.toString() else null
    }

    override fun onDestroy() {
        // The receiver is registered against the application context, so
        // without this it would outlive the activity on a config change.
        smsRetriever?.stop()
        smsRetriever = null
        super.onDestroy()
    }
}
