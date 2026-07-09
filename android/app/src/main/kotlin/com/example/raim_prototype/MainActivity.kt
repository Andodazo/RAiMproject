package com.example.raim_prototype

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.system.exitProcess

class MainActivity : FlutterActivity() {
    private val appControlChannelName = "raim_app_control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appControlChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "exitToHomeAndRemoveTask" -> {
                    result.success(null)
                    exitToHomeAndRemoveTask()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun exitToHomeAndRemoveTask() {
        // 認証に使ったブラウザへ戻らず、ホーム画面へ戻してからRAiMのタスクを履歴から外します。
        val homeIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(homeIntent)
        finishAndRemoveTask()

        // finishAndRemoveTask() はタスク履歴から外す処理であり、debug 実行中のプロセスが
        // すぐに終了するとは限りません。検証時に `flutter run` / PowerShell が待ち続けないよう、
        // MethodChannel の応答を返した後、少し遅らせてプロセスも明示的に終了します。
        Handler(Looper.getMainLooper()).postDelayed({
            Process.killProcess(Process.myPid())
            exitProcess(0)
        }, 300)
    }
}
