package com.lumebox.app

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lumebox/playback_effects")
            .setMethodCallHandler { call, result ->
                if (call.method == "supportsBlur") {
                    result.success(Build.VERSION.SDK_INT >= 31 && window.decorView.isHardwareAccelerated)
                } else {
                    result.notImplemented()
                }
            }
    }
}
