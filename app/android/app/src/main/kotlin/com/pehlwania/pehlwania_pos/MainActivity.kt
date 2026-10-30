package com.pehlwania.pehlwania_pos

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Google authorization (OAuth access tokens for Sheets/Drive) using the
 * Google Identity Services AuthorizationClient. No client secret is used or stored:
 * Google identifies the app by its package name + signing certificate SHA-1,
 * registered as an "Android" OAuth client in Google Cloud.
 */
class MainActivity : FlutterFragmentActivity() {
    private var pending: MethodChannel.Result? = null
    private val io = Executors.newSingleThreadExecutor()
    private val mediaShare = MediaShare(this)
    private val storagePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        mediaShare.onPermissionResult(granted)
    }

    init {
        mediaShare.permissionLauncher = storagePermission
    }

    // must be registered before the activity is started
    private val consentLauncher = registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { res ->
        val r = pending
        pending = null
        if (r == null) return@registerForActivityResult
        try {
            if (res.resultCode != Activity.RESULT_OK) {
                // the intent may carry the real reason (e.g. DEVELOPER_ERROR = not set up in Google Cloud)
                if (res.data != null) Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(res.data)
                r.error("CANCELED", "Google sign-in was cancelled", null)
                return@registerForActivityResult
            }
            val auth = Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(res.data)
            val token = auth.accessToken
            if (token.isNullOrEmpty()) r.error("AUTH_ERROR", "No access token returned", null)
            else r.success(mapOf("accessToken" to token))
        } catch (e: ApiException) {
            r.error(codeFor(e), e.message, e.statusCode)
        } catch (e: Exception) {
            r.error("AUTH_ERROR", e.message, null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdm/google_auth").setMethodCallHandler { call, result ->
            when (call.method) {
                "authorize" -> authorize(
                    call.argument<Boolean>("interactive") ?: false,
                    call.argument<List<String>>("scopes") ?: emptyList(),
                    result,
                )
                "clearToken" -> {
                    val token = call.argument<String>("token")
                    io.execute {
                        try { if (token != null) GoogleAuthUtil.clearToken(applicationContext, token) } catch (_: Exception) {}
                        runOnUiThread { result.success(true) }
                    }
                }
                "signingInfo" -> result.success(mapOf("packageName" to packageName, "sha1" to signingSha1()))
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdm/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> mediaShare.saveImage(
                    call.argument<String>("base64") ?: "", call.argument<String>("fileName") ?: "estimate.png", result)
                "share" -> mediaShare.share(
                    call.argument<String>("text") ?: "", call.argument<String>("base64"),
                    call.argument<String>("fileName"), call.argument<String>("phone"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun authorize(interactive: Boolean, scopes: List<String>, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("AUTH_ERROR", "Another sign-in is already in progress", null)
            return
        }
        val request = AuthorizationRequest.builder().setRequestedScopes(scopes.map { Scope(it) }).build()
        Identity.getAuthorizationClient(this).authorize(request)
            .addOnSuccessListener { ar ->
                if (ar.hasResolution()) {
                    val pi = ar.pendingIntent
                    if (!interactive || pi == null) {
                        result.error("NEEDS_UI", "User consent is required", null)
                    } else {
                        pending = result
                        try {
                            consentLauncher.launch(IntentSenderRequest.Builder(pi.intentSender).build())
                        } catch (e: Exception) {
                            pending = null
                            result.error("AUTH_ERROR", e.message, null)
                        }
                    }
                } else {
                    val token = ar.accessToken
                    if (token.isNullOrEmpty()) result.error("AUTH_ERROR", "No access token returned", null)
                    else result.success(mapOf("accessToken" to token))
                }
            }
            .addOnFailureListener { e ->
                val code = if (e is ApiException) codeFor(e) else "AUTH_ERROR"
                result.error(code, e.message, null)
            }
    }

    private fun codeFor(e: ApiException): String = when (e.statusCode) {
        CommonStatusCodes.DEVELOPER_ERROR -> "NOT_CONFIGURED" // no OAuth client for this package/SHA-1
        CommonStatusCodes.NETWORK_ERROR -> "NETWORK"
        CommonStatusCodes.CANCELED -> "CANCELED"
        CommonStatusCodes.SIGN_IN_REQUIRED -> "NEEDS_UI"
        else -> "AUTH_ERROR"
    }

    @Suppress("DEPRECATION")
    private fun signingSha1(): String = try {
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            info.signingInfo?.apkContentsSigners
        } else {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
        }
        val cert = sigs?.firstOrNull()?.toByteArray()
        if (cert == null) "" else MessageDigest.getInstance("SHA-1").digest(cert).joinToString(":") { "%02X".format(it) }
    } catch (_: Exception) {
        ""
    }
}
