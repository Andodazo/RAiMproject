import Flutter
import Darwin
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
