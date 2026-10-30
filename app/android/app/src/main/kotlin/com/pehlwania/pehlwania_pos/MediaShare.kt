package com.pehlwania.pehlwania_pos

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import androidx.activity.result.ActivityResultLauncher
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Calculator results:
 *  - saveImage: writes a PNG into the phone's Gallery (Pictures/Pehlwania POS) with MediaStore.
 *    Android 10+ needs no permission; Android 7–9 asks for storage permission once.
 *  - share: sends text + image straight to WhatsApp (or WhatsApp Business); if neither is
 *    installed, opens the normal Android share sheet.
 */
class MediaShare(private val activity: FragmentActivity) {
    companion object {
        const val ALBUM = "Pehlwania POS"
        private val WHATSAPP = listOf("com.whatsapp", "com.whatsapp.w4b")
    }

    private val io = Executors.newSingleThreadExecutor()
    private var pendingSave: (() -> Unit)? = null
    private var pendingResult: MethodChannel.Result? = null
    lateinit var permissionLauncher: ActivityResultLauncher<String>

    fun onPermissionResult(granted: Boolean) {
        val run = pendingSave
        val r = pendingResult
        pendingSave = null
        pendingResult = null
        if (granted) run?.invoke() else r?.error("PERMISSION", "Storage permission is needed to save to the Gallery", null)
    }

    fun saveImage(base64: String, fileName: String, result: MethodChannel.Result) {
        val bytes = try { Base64.decode(base64, Base64.DEFAULT) } catch (e: Exception) {
            result.error("BAD_IMAGE", "Image data is invalid", null); return
        }
        val name = safeName(fileName, "png")
        val doSave = {
            io.execute {
                try {
                    val where = writeToGallery(bytes, name)
                    activity.runOnUiThread { result.success(mapOf("album" to "Pictures/$ALBUM", "uri" to where, "fileName" to name)) }
                } catch (e: Exception) {
                    activity.runOnUiThread { result.error("SAVE_FAILED", e.message ?: "Could not save the image", null) }
                }
            }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            pendingSave = doSave
            pendingResult = result
            permissionLauncher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            doSave()
        }
    }

    private fun writeToGallery(bytes: ByteArray, name: String): String {
        val resolver = activity.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$ALBUM")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                ?: throw IllegalStateException("Gallery is not available")
            try {
                resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IllegalStateException("Cannot write to the Gallery")
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), ALBUM)
        if (!dir.exists() && !dir.mkdirs()) throw IllegalStateException("Cannot create the Pictures/$ALBUM folder")
        val file = File(dir, name)
        file.writeBytes(bytes)
        MediaScannerConnection.scanFile(activity, arrayOf(file.absolutePath), arrayOf("image/png"), null)
        return file.absolutePath
    }

    fun share(text: String, base64: String?, fileName: String?, phone: String?, result: MethodChannel.Result) {
        try {
            val send = Intent(Intent.ACTION_SEND).apply {
                putExtra(Intent.EXTRA_TEXT, text)
                type = "text/plain"
            }
            if (!base64.isNullOrEmpty()) {
                val dir = File(activity.cacheDir, "shared").apply { mkdirs() }
                dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 3_600_000 }?.forEach { it.delete() }
                val f = File(dir, safeName(fileName ?: "estimate.png", "png"))
                f.writeBytes(Base64.decode(base64, Base64.DEFAULT))
                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.pdmfiles", f)
                send.putExtra(Intent.EXTRA_STREAM, uri)
                send.type = "image/png"
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val pm = activity.packageManager
            for (pkg in WHATSAPP) {
                if (pm.getLaunchIntentForPackage(pkg) == null) continue
                val wa = Intent(send).setPackage(pkg)
                if (!phone.isNullOrEmpty()) wa.putExtra("jid", "$phone@s.whatsapp.net") // opens that chat when supported
                try {
                    activity.startActivity(wa)
                    result.success(mapOf("via" to "whatsapp", "package" to pkg))
                    return
                } catch (_: Exception) { /* try the next option */ }
            }
            activity.startActivity(Intent.createChooser(send, "Share estimate").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            result.success(mapOf("via" to "chooser"))
        } catch (e: Exception) {
            result.error("SHARE_FAILED", e.message ?: "Could not share", null)
        }
    }

    private fun safeName(name: String, ext: String): String {
        var n = name.replace(Regex("[^A-Za-z0-9._-]"), "_").take(100)
        if (!n.lowercase().endsWith(".$ext")) n += ".$ext"
        return n
    }
}
