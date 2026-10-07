package io.github.mazengomaa.attendance_host

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the Flutter engine for the whole process instead of letting the activity
 * own it. The Dart server and tunnels run in that engine, so swiping the app
 * away (which destroys the activity) no longer stops the session: the
 * foreground service keeps the process alive and reopening the app reattaches
 * to the same running engine. Only the in-app Stop button ends a session.
 */
class AttendanceApp : Application() {
    /** The visible activity, if any: needed for permission prompts. */
    var currentActivity: Activity? = null

    /** A file-picker request waiting for MainActivity.onActivityResult. */
    private var pendingPick: MethodChannel.Result? = null

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        MethodChannel(engine.dartExecutor.binaryMessenger, "attendance/host")
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
                        "alert" -> {
                            HostService.alert(this, call.argument<String>("title") ?: "",
                                call.argument<String>("text") ?: "")
                            result.success(true)
                        }
                        "requestNotifications" -> {
                            val a = currentActivity
                            if (a != null && Build.VERSION.SDK_INT >= 33 &&
                                a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED) {
                                a.requestPermissions(
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                            }
                            result.success(true)
                        }
                        "requestBatteryExemption" -> {
                            if (!ignoringBatteryOptimizations()) {
                                startActivity(Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            }
                            result.success(true)
                        }
                        "saveImage" -> result.success(saveImage(
                            call.argument<ByteArray>("bytes")!!,
                            call.argument<String>("name")!!))
                        "saveToDownloads" -> result.success(saveToDownloads(
                            call.argument<String>("path")!!,
                            call.argument<String>("mime") ?: "text/csv"))
                        "pickTextFile" -> pickTextFile(result)
                        "openSettings" -> result.success(
                            openSettings(call.argument<String>("kind") ?: "app"))
                        "openUrl" -> {
                            startActivity(Intent(Intent.ACTION_VIEW,
                                Uri.parse(call.argument<String>("url")))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        }
                        "deviceInfo" -> result.success(deviceInfo())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("host", e.toString(), null)
                }
            }
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    /**
     * Opens a settings screen. kind: "app" (this app's info page),
     * "notifications", or "brand" (the phone maker's own background/auto-start
     * screen, which differs per brand and One UI/MIUI/ColorOS version: each
     * known location is tried in turn, then the app info page). Returns which
     * screen was opened.
     */
    private fun openSettings(kind: String): String {
        fun tryStart(i: Intent): Boolean = try {
            startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
        val appInfo = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:$packageName"))
        when (kind) {
            "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                tryStart(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))) return "notifications"
            "brand" -> {
                val m = Build.MANUFACTURER.lowercase()
                val candidates = when {
                    "samsung" in m -> listOf(
                        "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
                        "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity",
                        "com.samsung.android.sm" to "com.samsung.android.sm.battery.ui.BatteryActivity")
                    "xiaomi" in m || "redmi" in m || "poco" in m -> listOf(
                        "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity")
                    "oppo" in m || "realme" in m || "oneplus" in m -> listOf(
                        "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                        "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
                        "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity")
                    "vivo" in m || "iqoo" in m -> listOf(
                        "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                        "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")
                    "huawei" in m || "honor" in m -> listOf(
                        "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                        "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity")
                    else -> emptyList()
                }
                for ((pkg, cls) in candidates) {
                    if (tryStart(Intent().setComponent(android.content.ComponentName(pkg, cls)))) {
                        return "brand"
                    }
                }
            }
        }
        return if (tryStart(appInfo)) "app" else "none"
    }

    /** System file picker (no storage permission needed); answers with
     *  {name, bytes}, or null if the user backed out. */
    private fun pickTextFile(result: MethodChannel.Result) {
        val a = currentActivity
        if (a == null) {
            result.error("host", "app is not in the foreground", null)
            return
        }
        pendingPick?.success(null)
        pendingPick = result
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                "text/csv", "text/comma-separated-values", "text/plain",
                "application/csv", "application/vnd.ms-excel"))
        a.startActivityForResult(i, PICK_REQUEST)
    }

    fun onPickResult(uri: Uri?) {
        val r = pendingPick ?: return
        pendingPick = null
        if (uri == null) {
            r.success(null)
            return
        }
        try {
            var name = uri.lastPathSegment ?: "roster"
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                null, null, null)?.use { c -> if (c.moveToFirst()) name = c.getString(0) }
            val bytes = contentResolver.openInputStream(uri)!!.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(8192)
                var total = 0
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                    if (total > 2 * 1024 * 1024) throw IllegalStateException("file larger than 2 MB")
                    out.write(buf, 0, n)
                }
                out.toByteArray()
            }
            r.success(mapOf("name" to name, "bytes" to bytes))
        } catch (e: Exception) {
            r.error("host", e.toString(), null)
        }
    }

    /** Saves a PNG into Pictures/Attendance; returns where it went. */
    private fun saveImage(bytes: ByteArray, name: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/Attendance")
            }
            val uri = contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
            return "Pictures/Attendance/$name"
        }
        // Android 9 and older: shared storage needs a permission we don't ask
        // for, so keep it in the app's own pictures folder (Share still works).
        val dir = getExternalFilesDir(Environment.DIRECTORY_PICTURES)!!
        val f = java.io.File(dir, name)
        f.writeBytes(bytes)
        return f.absolutePath
    }

    /** Copies an exported file into Download/Attendance; returns where it went. */
    private fun saveToDownloads(path: String, mime: String): String {
        val src = java.io.File(path)
        val name = src.name
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/Attendance")
            }
            val uri = contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)!!.use { out ->
                src.inputStream().use { it.copyTo(out) }
            }
            return "Download/Attendance/$name"
        }
        val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)!!
        val dest = java.io.File(dir, name)
        src.copyTo(dest, overwrite = true)
        return dest.absolutePath
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
            "uiAttached" to (currentActivity != null),
        )
    }

    companion object {
        const val ENGINE_ID = "main"
        const val PICK_REQUEST = 4242
    }
}
