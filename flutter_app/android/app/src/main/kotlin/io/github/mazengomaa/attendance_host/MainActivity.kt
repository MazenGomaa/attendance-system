package io.github.mazengomaa.attendance_host

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * A thin window onto the process-wide engine created in AttendanceApp. The
 * engine (and the running session) outlives this activity: closing or swiping
 * the app away only detaches the UI.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        (application as AttendanceApp).currentActivity = this
    }

    override fun onDestroy() {
        val app = application as AttendanceApp
        if (app.currentActivity === this) app.currentActivity = null
        super.onDestroy()
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(AttendanceApp.ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
