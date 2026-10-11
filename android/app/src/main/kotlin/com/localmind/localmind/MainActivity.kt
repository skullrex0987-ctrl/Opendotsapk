package com.localmind.localmind

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Main activity for LocalMind.
 *
 * Extends the v2 embedding FlutterActivity. The v1 embedding was removed from
 * Flutter, so importing `io.flutter.app.FlutterActivity` (v1) fails the build
 * with "use of deleted Android v1 embedding".
 *
 * It also owns the `com.localmind.localmind/secure_screen` channel, the only
 * reason this class is not empty: while the app's lock is on, notes must not
 * be captured into screenshots or the recents thumbnail, and that is a window
 * flag only native code can set.
 */
class MainActivity : FlutterActivity() {

    private val secureScreenChannel = "com.localmind.localmind/secure_screen"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureScreenChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enableSecure" -> {
                        applySecure(true)
                        result.success(null)
                    }
                    "disableSecure" -> {
                        applySecure(false)
                        result.success(null)
                    }
                    "openSecuritySettings" -> {
                        // Fail-closed screen escape hatch: send the user to the
                        // system settings where a screen lock can be set.
                        try {
                            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_settings_activity", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * FLAG_SECURE keeps this window out of screenshots and screen recordings.
     * On API 33+ the recents thumbnail is a separate opt-out, so toggle both.
     */
    private fun applySecure(enabled: Boolean) {
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                setRecentsScreenshotEnabled(!enabled)
            }
        }
    }
}
