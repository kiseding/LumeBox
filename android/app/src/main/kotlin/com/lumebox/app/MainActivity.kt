package com.lumebox.app

import android.app.Activity
import android.content.Intent
import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportText: String? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "lumebox/app_icon")
            .setMethodCallHandler { call, result ->
                val names = listOf("default", "Aurora", "Obsidian", "Solar", "Orbit", "Prism", "Spark")
                fun component(name: String) = ComponentName(packageName, "$packageName.icons.${if (name == "default") "Default" else name}")
                if (call.method == "current") {
                    val current = names.firstOrNull { name ->
                        val state = packageManager.getComponentEnabledSetting(component(name))
                        state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
                            (name == "default" && state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT)
                    }
                    result.success(current ?: "default")
                } else if (call.method == "set") {
                    val selected = call.arguments as? String
                    if (selected !in names) { result.error("icon", "Unknown icon", null); return@setMethodCallHandler }
                    try {
                        // Enable the destination first, so a failed switch never removes every launcher.
                        packageManager.setComponentEnabledSetting(component(selected!!), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                        names.filter { it != selected }.forEach { name ->
                            packageManager.setComponentEnabledSetting(component(name), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
                        }
                        result.success(true)
                    } catch (error: Exception) { result.error("icon", error.message, null) }
                } else { result.notImplemented() }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "lumebox/configuration")
            .setMethodCallHandler { call, result ->
                if (call.method != "export") { result.notImplemented(); return@setMethodCallHandler }
                if (exportResult != null) { result.error("busy", "Export already open", null); return@setMethodCallHandler }
                val text = call.argument<String>("text")
                val name = call.argument<String>("name")
                if (text == null || name == null) { result.error("arguments", "Missing backup", null); return@setMethodCallHandler }
                exportText = text
                exportResult = result
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, 4271)
                } catch (error: Exception) {
                    exportText = null; exportResult = null
                    result.error("export", error.message, null)
                }
            }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4271) return
        val result = exportResult ?: return
        val text = exportText
        exportResult = null; exportText = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || text == null) { result.success(false); return }
        try {
            val stream = contentResolver.openOutputStream(uri) ?: throw IllegalStateException("Cannot open destination")
            stream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
            result.success(true)
        } catch (error: Exception) { result.error("export", error.message, null) }
    }
}
