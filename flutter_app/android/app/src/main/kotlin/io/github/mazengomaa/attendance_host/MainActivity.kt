package io.github.mazengomaa.attendance_host

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges what Dart can't do on its own: the foreground service, the
 * nativeLibraryDir (the only place Android lets an app execute its own binary,
 * where cloudflared is unpacked as libcloudflared.so), permission prompts and
 * device info for the Debug screen.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "attendance/host")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "paths" -> result.success(mapOf(
                            "nativeLibDir" to applicationInfo.nativeLibraryDir,
                            "filesDir" to filesDir.absolutePath,
                        ))
                        "startService" -> {
                            val i = Intent(this, HostService::class.java)
                                .putExtra(HostService.EXTRA_TEXT, call.argument<String>("text"))
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            result.success(true)
                        }
                        "stopService" -> {
                            stopService(Intent(this, HostService::class.java))
                            result.success(true)
                        }
                        "updateNotification" -> {
                            HostService.update(this, call.argument<String>("text") ?: "")
                            result.success(true)
                        }
                        "requestNotifications" -> {
                            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(
                                    Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                            }
                            result.success(true)
                        }
                        "requestBatteryExemption" -> {
                            if (!ignoringBatteryOptimizations()) {
                                startActivity(Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")))
                            }
                            result.success(true)
                        }
                        "deviceInfo" -> result.success(deviceInfo())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("host", e.toString(), null)
                }
            }
    }

    private fun ignoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun deviceInfo(): Map<String, Any?> {
        val notificationsGranted = Build.VERSION.SDK_INT < 33 || checkSelfPermission(
            Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val pkg = packageManager.getPackageInfo(packageName, 0)
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.joinToString(","),
            "appVersion" to "${pkg.versionName} (${
                if (Build.VERSION.SDK_INT >= 28) pkg.longVersionCode
                else @Suppress("DEPRECATION") pkg.versionCode.toLong()})",
            "batteryOptimizationIgnored" to ignoringBatteryOptimizations(),
            "notificationsGranted" to notificationsGranted,
            "serviceRunning" to HostService.running,
        )
    }
}
