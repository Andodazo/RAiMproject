import Flutter
import Darwin
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // アプリを開いている最中にも、駅アラームの通知をバナーで出すため。
    // これが無いと、iOS はアプリが前面にいるときの通知を表示しない。
    // FlutterAppDelegate が受け取り、flutter_local_notifications へ渡す。
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "RaimNative"
    ) else {
      assertionFailure("Failed to create RaimNative registrar")
      return
    }

    let controlChannel = FlutterMethodChannel(
      name: "raim_app_control",
      binaryMessenger: registrar.messenger()
    )
    controlChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "debugExitProcess":
        #if DEBUG
        result(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          Darwin.exit(0)
        }
        #else
        result(FlutterError(
          code: "RELEASE_BUILD",
          message: "iOSのプロセス終了はDebugビルドでのみ有効です",
          details: nil
        ))
        #endif
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

}

