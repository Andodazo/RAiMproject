import Flutter
import Darwin
import SafariServices
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

    let browserChannel = FlutterMethodChannel(
      name: "raim_ios_auth_browser",
      binaryMessenger: registrar.messenger()
    )
    browserChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "openAuthBrowser":
        guard
          let arguments = call.arguments as? [String: Any],
          let urlString = arguments["url"] as? String,
          let url = URL(string: urlString)
        else {
          result(FlutterError(code: "INVALID_URL", message: "認証URLが不正です", details: nil))
          return
        }
        self?.presentAuthBrowser(url: url) { value in
          result(value)
        }
      case "closeAuthBrowser":
        self?.dismissAuthBrowser { value in
          result(value)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
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

  private var authBrowser: SFSafariViewController?

  private func presentAuthBrowser(url: URL, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let rootViewController = self.rootViewController() else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "表示先が見つかりません", details: nil))
        return
      }

      self.authBrowser?.dismiss(animated: false)
      let safariViewController = SFSafariViewController(url: url)
      self.authBrowser = safariViewController
      self.topViewController(from: rootViewController).present(
        safariViewController,
        animated: true
      ) {
        result(true)
      }
    }
  }

  private func dismissAuthBrowser(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let authBrowser = self.authBrowser else {
        result(nil)
        return
      }

      authBrowser.dismiss(animated: true) {
        self.authBrowser = nil
        result(nil)
      }
    }
  }

  private func rootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })?
      .rootViewController
  }

  private func topViewController(from viewController: UIViewController) -> UIViewController {
    if let presented = viewController.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigationController = viewController as? UINavigationController,
       let visible = navigationController.visibleViewController {
      return topViewController(from: visible)
    }
    if let tabBarController = viewController as? UITabBarController,
       let selected = tabBarController.selectedViewController {
      return topViewController(from: selected)
    }
    return viewController
  }
}
