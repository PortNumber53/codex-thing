package dev.codexthing.mobile

import android.app.Application
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class CodexApplication : Application() {
    companion object {
        const val ENGINE_ID = "codex_mobile_engine"
        private const val BACKGROUND_CHANNEL =
            "dev.codexthing.mobile/background_connection"
    }

    var currentActivity: MainActivity? = null

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        configureBackgroundChannel(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    private fun configureBackgroundChannel(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, BackgroundConnectionService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        currentActivity?.requestNotificationPermission()
                        result.success(true)
                    }

                    "stop" -> {
                        stopService(Intent(this, BackgroundConnectionService::class.java))
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error(
                    "BACKGROUND_CONNECTION_FAILED",
                    error.message ?: "Android could not update the background connection.",
                    null,
                )
            }
        }
    }
}
