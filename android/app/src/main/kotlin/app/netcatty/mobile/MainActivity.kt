package app.netcatty.mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.netcatty.mobile/connection",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setActive" -> {
                    val active = call.argument<Boolean>("active") == true
                    if (active) {
                        requestNotificationPermission()
                        ContextCompat.startForegroundService(
                            this,
                            Intent(this, SshKeepAliveService::class.java),
                        )
                    } else {
                        stopService(Intent(this, SshKeepAliveService::class.java))
                    }
                    result.success(null)
                }
                "beginBackgroundGrace", "endBackgroundGrace" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermission() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                701,
            )
        }
    }
}
