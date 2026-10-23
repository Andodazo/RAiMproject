package com.example.raim_prototype

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.system.exitProcess

class MainActivity : FlutterActivity() {
    private val appControlChannelName = "raim_app_control"
    private val hapticsChannelName = "raim_haptics"

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

        // 【確認用・後で消す】駅アラームの録音を「ダウンロード」へ写す
        StationRecordingExport.register(this, flutterEngine.dartExecutor.binaryMessenger)

        // 振動（lib/services/haptics.dart）。
        // Flutter の HapticFeedback は「タップ時の振動」の設定に従うので、
        // OFF の端末では「ねえライム」の合図も駅アラームも震えなかった。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            hapticsChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "vibrate" -> {
                    val pattern = (call.argument<List<Number>>("pattern") ?: emptyList())
                        .map { it.toLong() }
                        .toLongArray()
                    val alarm = call.argument<Boolean>("alarm") ?: false
                    result.success(vibrate(pattern, alarm))
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * [pattern]（待つ, 震える, 待つ, ... のミリ秒）で一度だけ震わせる。
     * [alarm] が true なら目覚ましの扱いにする。画面が消えていても、
     * アプリが裏に回っていても震える（駅アラーム用）。
     * 震わせられたら true。
     */
    @Suppress("DEPRECATION")
    private fun vibrate(pattern: LongArray, alarm: Boolean): Boolean {
        if (pattern.size < 2) return false
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        if (vibrator == null || !vibrator.hasVibrator()) return false

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val effect = VibrationEffect.createWaveform(pattern, -1)
                when {
                    !alarm -> vibrator.vibrate(effect)
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                        vibrator.vibrate(
                            effect,
                            VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM)
                        )
                    else -> vibrator.vibrate(effect, alarmAudioAttributes())
                }
            } else {
                if (alarm) {
                    vibrator.vibrate(pattern, -1, alarmAudioAttributes())
                } else {
                    vibrator.vibrate(pattern, -1)
                }
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun alarmAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

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
