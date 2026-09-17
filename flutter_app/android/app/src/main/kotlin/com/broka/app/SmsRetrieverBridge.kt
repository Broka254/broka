package com.broka.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import com.google.android.gms.auth.api.phone.SmsRetriever
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Status
import io.flutter.plugin.common.EventChannel
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.NoSuchAlgorithmException
import java.util.regex.Pattern

/**
 * Bridges Google Play Services' SMS Retriever API to Flutter.
 *
 * The Retriever hands the app the body of exactly one incoming SMS — the one
 * ending in this build's app-signature hash — with no SMS permission and no
 * user prompt. That is what lets the OTP screen fill itself silently instead
 * of going through the platform Autofill framework's confirmation dialog.
 *
 * See services/sms_autofill_service.dart for the Dart half and the reasoning.
 */
class SmsRetrieverBridge(private val context: Context) : EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    companion object {
        private const val TAG = "BrokaSmsRetriever"

        /** Hash length mandated by the SMS Retriever contract. */
        private const val HASH_LENGTH = 11

        /**
         * First run of 4-8 digits in the message. Deliberately not anchored
         * to the start: the message begins with "<#>" and the code's position
         * within the sentence is free to change.
         */
        private val CODE_PATTERN: Pattern = Pattern.compile("(\\d{4,8})")

        /**
         * Computes the app-signature hash for this package + signing
         * certificate, following Google's documented AppSignatureHelper
         * recipe: sha256(packageName + " " + signingCertificate), base64
         * without padding, truncated to 11 characters.
         *
         * The value differs between debug, release and Play-signed builds,
         * which is exactly why it is read at runtime and sent to the server
         * with each OTP request rather than hardcoded anywhere.
         */
        fun appSignature(context: Context): String? {
            return try {
                val packageName = context.packageName
                val signatures = signingCertificates(context) ?: return null
                for (signature in signatures) {
                    val hash = hash(packageName, signature)
                    if (hash != null) return hash
                }
                null
            } catch (e: Exception) {
                Log.w(TAG, "Could not compute app signature", e)
                null
            }
        }

        @Suppress("DEPRECATION")
        private fun signingCertificates(context: Context): List<String>? {
            val pm = context.packageManager
            val packageName = context.packageName
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val info = pm.getPackageInfo(
                        packageName,
                        PackageManager.GET_SIGNING_CERTIFICATES
                    )
                    val signing = info.signingInfo ?: return null
                    val certs = if (signing.hasMultipleSigners()) {
                        signing.apkContentsSigners
                    } else {
                        signing.signingCertificateHistory
                    }
                    certs?.map { it.toCharsString() }
                } else {
                    val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                    info.signatures?.map { it.toCharsString() }
                }
            } catch (e: PackageManager.NameNotFoundException) {
                Log.w(TAG, "Package not found while reading signatures", e)
                null
            }
        }

        private fun hash(packageName: String, signature: String): String? {
            val input = "$packageName $signature"
            return try {
                val md = MessageDigest.getInstance("SHA-256")
                md.update(input.toByteArray(StandardCharsets.UTF_8))
                val digest = md.digest()
                val base64 = Base64.encodeToString(
                    digest,
                    Base64.NO_PADDING or Base64.NO_WRAP
                )
                base64.substring(0, HASH_LENGTH)
            } catch (e: NoSuchAlgorithmException) {
                Log.w(TAG, "SHA-256 unavailable", e)
                null
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stop()
    }

    /**
     * Arms the Retriever for the next matching message.
     *
     * One call covers one message, so this is invoked again on every resend;
     * the previous receiver is torn down first so a resend cannot leave two
     * registered.
     */
    fun start(onResult: (Boolean) -> Unit) {
        stop()
        val client = SmsRetriever.getClient(context)
        client.startSmsRetriever()
            .addOnSuccessListener {
                registerReceiver()
                onResult(true)
            }
            .addOnFailureListener { e ->
                // Play Services missing or out of date. The Dart side treats
                // false as "user types the code", which still works.
                Log.w(TAG, "startSmsRetriever failed", e)
                onResult(false)
            }
    }

    fun stop() {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Already unregistered; nothing to undo.
            }
        }
        receiver = null
    }

    private fun registerReceiver() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != SmsRetriever.SMS_RETRIEVED_ACTION) return
                val extras: Bundle = intent.extras ?: return

                val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    extras.getParcelable(SmsRetriever.EXTRA_STATUS, Status::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    extras.get(SmsRetriever.EXTRA_STATUS) as? Status
                } ?: return

                when (status.statusCode) {
                    CommonStatusCodes.SUCCESS -> {
                        val message = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            extras.getString(SmsRetriever.EXTRA_SMS_MESSAGE)
                        } else {
                            @Suppress("DEPRECATION")
                            extras.get(SmsRetriever.EXTRA_SMS_MESSAGE) as? String
                        }
                        extractCode(message)?.let { code -> sink?.success(code) }
                    }
                    CommonStatusCodes.TIMEOUT -> {
                        // Five minutes with no matching SMS. Not an error the
                        // user needs to see — the code can still be typed.
                        Log.d(TAG, "SMS Retriever timed out")
                    }
                    else -> Log.d(TAG, "SMS Retriever status ${status.statusCode}")
                }
                stop()
            }
        }
        receiver = r

        val filter = IntentFilter(SmsRetriever.SMS_RETRIEVED_ACTION)
        // The broadcast originates in Google Play Services, i.e. outside this
        // app, so on Android 14+ the receiver has to be declared exported or
        // registration throws.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(r, filter)
        }
    }

    private fun extractCode(message: String?): String? {
        if (message.isNullOrBlank()) return null
        val matcher = CODE_PATTERN.matcher(message)
        return if (matcher.find()) matcher.group(1) else null
    }
}
