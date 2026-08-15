package app.netcatty.mobile

import android.Manifest
import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var documentTreeChannel: DocumentTreeChannel? = null
    private var pictureInPictureChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        documentTreeChannel = DocumentTreeChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
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
        pictureInPictureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.netcatty.mobile/picture_in_picture",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPictureInPictureSupported())
                    "enter" -> {
                        if (!isPictureInPictureSupported()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val width = (call.argument<Number>("aspectWidth")?.toInt() ?: 16)
                            .coerceAtLeast(1)
                        val height = (call.argument<Number>("aspectHeight")?.toInt() ?: 9)
                            .coerceAtLeast(1)
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(width, height))
                            .build()
                        result.success(enterPictureInPictureMode(params))
                    }
                    // Android displays the live Flutter surface, so it doesn't need
                    // the text frames used by iOS.
                    "update", "stop" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPictureChannel?.invokeMethod(
            "stateChanged",
            mapOf("active" to isInPictureInPictureMode),
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (documentTreeChannel?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        documentTreeChannel?.dispose()
        documentTreeChannel = null
        pictureInPictureChannel?.setMethodCallHandler(null)
        pictureInPictureChannel = null
        super.onDestroy()
    }

    private fun isPictureInPictureSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

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
