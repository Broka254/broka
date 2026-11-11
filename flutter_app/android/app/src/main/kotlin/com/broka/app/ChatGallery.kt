package com.broka.app

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Saving a chat photo to the phone's gallery (lib/services/chat_gallery.dart):
 * Pictures/BROKA, where the gallery app shows it.
 *
 * Not a plugin, for the reason ChatDocuments isn't one: CI builds with a
 * pinned Flutter and Android Gradle Plugin, and this is the whole of what is
 * needed. Android 10 and newer take it through MediaStore with no
 * permission. Android 9 and older write the file to Pictures and scan it in,
 * which needs WRITE_EXTERNAL_STORAGE (the manifest declares it up to API 28
 * only): without it the answer is "permission", and Dart asks for it.
 *
 * The server re-encodes chat photos to WebP. One is saved as a JPEG: every
 * gallery opens that, and so does every app it may be shared on to.
 */
class ChatGallery(private val context: Context) {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** Answers "saved", "permission" or "failed", on the main thread. */
    fun save(bytes: ByteArray, name: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {
            result.success("permission")
            return
        }
        io.execute {
            val outcome = try {
                write(bytes, name)
                "saved"
            } catch (e: Exception) {
                Log.w(TAG, "could not save a photo: ${e.javaClass.simpleName}")
                "failed"
            }
            main.post { result.success(outcome) }
        }
    }

    private fun write(bytes: ByteArray, name: String) {
        val photo = forGallery(bytes)
        val fileName = "${safeName(name)}.${photo.extension}"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, photo.mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/BROKA")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("no gallery entry")
            try {
                val out = resolver.openOutputStream(uri) ?: throw IllegalStateException("no stream")
                out.use { it.write(photo.bytes) }
                val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            } catch (e: Exception) {
                // No half-written photo left in the gallery.
                resolver.delete(uri, null, null)
                throw e
            }
        } else {
            @Suppress("DEPRECATION")
            val pictures = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            val dir = File(pictures, "BROKA")
            if (!dir.exists() && !dir.mkdirs()) throw IllegalStateException("no folder")
            val file = File(dir, fileName)
            file.outputStream().use { it.write(photo.bytes) }
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf(photo.mime), null)
        }
    }

    private class GalleryPhoto(val bytes: ByteArray, val mime: String, val extension: String)

    private fun forGallery(bytes: ByteArray): GalleryPhoto {
        if (startsWith(bytes, byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47))) {
            return GalleryPhoto(bytes, "image/png", "png")
        }
        val webp = startsWith(bytes, "RIFF".toByteArray()) &&
            startsWith(bytes, "WEBP".toByteArray(), 8)
        if (!webp) return GalleryPhoto(bytes, "image/jpeg", "jpg")
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: return GalleryPhoto(bytes, "image/webp", "webp")
        return try {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
            GalleryPhoto(out.toByteArray(), "image/jpeg", "jpg")
        } finally {
            bitmap.recycle()
        }
    }

    private fun startsWith(bytes: ByteArray, signature: ByteArray, at: Int = 0): Boolean {
        if (bytes.size < at + signature.size) return false
        for (i in signature.indices) {
            if (bytes[at + i] != signature[i]) return false
        }
        return true
    }

    private fun safeName(name: String): String {
        val cleaned = name.replace(Regex("[^A-Za-z0-9_ -]"), "_").trim()
        return if (cleaned.isEmpty()) "BROKA" else cleaned.take(80)
    }

    companion object {
        private const val TAG = "ChatGallery"
    }
}
