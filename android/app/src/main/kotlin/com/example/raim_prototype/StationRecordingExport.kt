package com.example.raim_prototype

import android.app.Activity
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 【確認用・後で消す】駅アラームの録音を「ダウンロード/RAiM」へ写す
 * （lib/services/station/station_recorder.dart から呼ぶ）。
 *
 * アプリ専用のフォルダ（Android/data/...）は「ファイル」アプリから見られないので、
 * 乗車が終わったら誰でも見られる「ダウンロード」に写す。
 * Android 10 以降は権限なしで書ける（MediaStore）。9 以前は写さずに false を返す。
 */
object StationRecordingExport {
    private const val CHANNEL = "raim_station_recording"
    private const val FOLDER = "RAiM"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyToDownloads" -> {
                    val path = call.argument<String>("path")
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    if (path == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    // 1時間で100MB を超えるので、画面を止めないよう別のスレッドで写す
                    Thread {
                        val ok = copyToDownloads(activity, File(path), mime)
                        activity.runOnUiThread { result.success(ok) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun copyToDownloads(activity: Activity, source: File, mime: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        if (!source.exists()) return false
        return insertIntoDownloads(activity, source, mime)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun insertIntoDownloads(activity: Activity, source: File, mime: String): Boolean {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, source.name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return false

        return try {
            resolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { it.copyTo(out) }
            } ?: throw IllegalStateException("openOutputStream returned null")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            true
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            false
        }
    }
}
