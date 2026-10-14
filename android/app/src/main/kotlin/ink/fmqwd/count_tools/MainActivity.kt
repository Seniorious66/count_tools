package com.seniorious66.counttools

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var exportBytes: ByteArray? = null
    private val maxBytes = 128 * 1024 * 1024
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.seniorious66.counttools/backup").setMethodCallHandler { call, result ->
            if (call.method != "exportBackup" && call.method != "exportCsv" && call.method != "importBackup") {
                result.notImplemented()
            } else if (pending != null) {
                result.error("busy", "文件选择正在进行", null)
            } else {
                val intent: Intent
                val request: Int
                if (call.method == "exportBackup" || call.method == "exportCsv") {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.size > maxBytes) {
                        result.error("invalid", "导出数据无效", null)
                        return@setMethodCallHandler
                    }
                    exportBytes = bytes
                    intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (call.method == "exportCsv") "text/csv" else "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "Cheki.chekibackup")
                    }
                    request = 661
                } else {
                    intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    request = 662
                }
                pending = result
                try { startActivityForResult(intent, request) }
                catch (e: Exception) { pending = null; exportBytes = null; result.error("picker", "无法打开文件选择器", null) }
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 661 && requestCode != 662) return
        val result = pending ?: return
        val bytes = exportBytes
        val uri = data?.data
        // Keep pending until IO finishes, so a second call cannot overwrite the first.
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null; exportBytes = null
            result.success(if (requestCode == 661) false else null)
            return
        }
        Thread {
            try {
                if (requestCode == 661) {
                    contentResolver.openOutputStream(uri, "w").use { output ->
                        if (output == null || bytes == null) throw IllegalStateException()
                        output.write(bytes); output.flush()
                    }
                    runOnUiThread { pending = null; exportBytes = null; result.success(true) }
                } else {
                    val output = ByteArrayOutputStream()
                    contentResolver.openInputStream(uri).use { input ->
                        if (input == null) throw IllegalStateException()
                        val buffer = ByteArray(65536)
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            if (output.size() + n > maxBytes) throw IllegalStateException()
                            output.write(buffer, 0, n)
                        }
                    }
                    runOnUiThread { pending = null; result.success(output.toByteArray()) }
                }
            } catch (e: Exception) {
                runOnUiThread { pending = null; exportBytes = null; result.error("file", "文件读写失败，请保留原文件重试", null) }
            }
        }.start()
    }
}
