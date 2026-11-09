package com.broka.app

import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Documents in a chat (lib/services/chat_documents.dart): picking the files
 * to send, and opening one that was sent.
 *
 * Not a Flutter plugin, for the reason the share channel in MainActivity
 * isn't one: CI builds with a pinned Flutter and Android Gradle Plugin, and
 * this is the whole of what is needed - Android's own document picker
 * (Storage Access Framework, no storage permission) and an ACTION_VIEW
 * through the FileProvider the manifest already declares.
 *
 * Picked files are copied into the app's cache before Dart sees them: a
 * content:// grant can lapse once the picker is gone, and Dart reads plain
 * files. A file bigger than the chat accepts is not copied at all - it is
 * reported with `tooLarge`, so a 2 GB video picked by mistake costs nothing.
 */
class ChatDocuments(private val context: Context) {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** Copies what the picker returned; answers on the main thread. */
    fun copyPicked(uris: List<Uri>, maxBytes: Long, result: MethodChannel.Result) {
        io.execute {
            val picked = ArrayList<Map<String, Any?>>()
            for (uri in uris) {
                try {
                    picked.add(copyOne(uri, maxBytes))
                } catch (e: Exception) {
                    Log.w(TAG, "could not read a picked document: ${e.javaClass.simpleName}")
                    picked.add(mapOf("name" to displayName(uri), "unreadable" to true))
                }
            }
            main.post { result.success(picked) }
        }
    }

    private fun copyOne(uri: Uri, maxBytes: Long): Map<String, Any?> {
        val resolver: ContentResolver = context.contentResolver
        val name = displayName(uri)
        val declared = declaredSize(uri)
        val mime = resolver.getType(uri)
        if (declared != null && declared > maxBytes) {
            return mapOf("name" to name, "size" to declared, "mime" to mime, "tooLarge" to true)
        }
        val dir = File(context.cacheDir, "picked_docs/${UUID.randomUUID()}")
        dir.mkdirs()
        val target = File(dir, safeName(name))
        var copied = 0L
        resolver.openInputStream(uri).use { input ->
            if (input == null) throw IllegalStateException("no stream")
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    copied += n
                    if (copied > maxBytes) {
                        // A provider that didn't say its size, or said less.
                        output.close()
                        target.delete()
                        return mapOf("name" to name, "size" to copied, "mime" to mime, "tooLarge" to true)
                    }
                    output.write(buffer, 0, n)
                }
            }
        }
        return mapOf("path" to target.absolutePath, "name" to name, "size" to copied, "mime" to mime)
    }

    private fun displayName(uri: Uri): String {
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val i = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (i >= 0) cursor.getString(i)?.let { if (it.isNotBlank()) return it }
                    }
                }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "document"
    }

    private fun declaredSize(uri: Uri): Long? {
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val i = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (i >= 0 && !cursor.isNull(i)) return cursor.getLong(i)
                    }
                }
        } catch (_: Exception) {
        }
        return null
    }

    /**
     * Opens [path] in whichever app the user chooses. The file is copied
     * under the cache first when it is elsewhere (the app's documents
     * folder, where sent and downloaded files are kept), since the
     * FileProvider shares only the cache and external storage.
     * Answers "opened", "no_app" (nothing installed opens this type) or
     * "missing".
     */
    fun open(path: String, mime: String?, result: MethodChannel.Result) {
        io.execute {
            val shared: File? = try {
                val source = File(path)
                when {
                    !source.exists() -> null
                    source.canonicalPath.startsWith(context.cacheDir.canonicalPath) -> source
                    else -> {
                        val dir = File(context.cacheDir, "shared_docs/${UUID.randomUUID()}")
                        dir.mkdirs()
                        File(dir, safeName(source.name)).also { source.copyTo(it, overwrite = true) }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "could not stage a document: ${e.javaClass.simpleName}")
                null
            }
            main.post {
                if (shared == null) {
                    result.success("missing")
                    return@post
                }
                try {
                    val uri = FileProvider.getUriForFile(
                        context, "${context.packageName}.fileprovider", shared)
                    // Straight to the viewer: Android asks which app when
                    // several can, and says nothing can when none does -
                    // which is when Dart offers sharing it instead.
                    context.startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mime ?: "application/octet-stream")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                    result.success("opened")
                } catch (e: ActivityNotFoundException) {
                    result.success("no_app")
                } catch (e: Exception) {
                    Log.w(TAG, "could not open a document: ${e.javaClass.simpleName}")
                    result.success("no_app")
                }
            }
        }
    }

    private fun safeName(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").trim().trim('.')
        return if (cleaned.isEmpty()) "document" else cleaned.take(120)
    }

    companion object {
        private const val TAG = "ChatDocuments"
    }
}
