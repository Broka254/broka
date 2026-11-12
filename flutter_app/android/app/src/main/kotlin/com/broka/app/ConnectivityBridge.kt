package com.broka.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Tells Dart when the phone's default network comes and goes
 * (lib/services/connectivity_monitor.dart): "online" or "offline", once when
 * Dart starts listening and again on every change. Dart runs the offline
 * message sync when it sees offline turn into online.
 *
 * "online" means the default network can reach the internet
 * (NET_CAPABILITY_INTERNET) - not that BROKA's server answers; the sync
 * retries if it doesn't.
 */
class ConnectivityBridge(private val context: Context) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val manager = context.getSystemService(ConnectivityManager::class.java)
        if (manager == null) {
            return
        }
        post(if (isOnline(manager)) "online" else "offline")
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                post(if (isOnline(manager)) "online" else "offline")
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                post(if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) "online" else "offline")
            }

            override fun onLost(network: Network) {
                post(if (isOnline(manager)) "online" else "offline")
            }
        }
        try {
            manager.registerDefaultNetworkCallback(cb)
            callback = cb
        } catch (e: Exception) {
            // Without ACCESS_NETWORK_STATE, or past the per-app callback
            // limit: Dart falls back to syncing on resume.
            callback = null
        }
    }

    override fun onCancel(arguments: Any?) {
        stop()
        sink = null
    }

    fun stop() {
        val cb = callback ?: return
        callback = null
        try {
            context.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb)
        } catch (e: Exception) {
            // Already unregistered.
        }
    }

    private fun isOnline(manager: ConnectivityManager): Boolean {
        val network = manager.activeNetwork ?: return false
        val caps = manager.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // Network callbacks arrive on a ConnectivityManager thread; an
    // EventSink may only be used on the main thread.
    private fun post(state: String) {
        main.post { sink?.success(state) }
    }
}
