import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Apps built with the iOS 27 SDK launch only with the scene life cycle,
  // which Flutter 3.24 does not set up: the app delegate owns the engine and
  // SceneDelegate shows it in the scene's window.
  lazy var flutterEngine = FlutterEngine(name: "main")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)
    dummyMethodToEnforceBundling();
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var pointer: NikoPointer?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let app = UIApplication.shared.delegate as? AppDelegate
    else { return }
    let window = UIWindow(windowScene: windowScene)
    let controller = FlutterViewController(
      engine: app.flutterEngine, nibName: nil, bundle: nil)
    pointer = NikoPointer(controller: controller)
    window.rootViewController = controller
    // Plugins find the view controller to present from on the app delegate.
    app.window = window
    self.window = window
    window.makeKeyAndVisible()
    open(connectionOptions.urlContexts)
  }

  // nikodesk:// links arrive at the scene; the plugins listen on the app delegate.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    open(URLContexts)
  }

  private func open(_ contexts: Set<UIOpenURLContext>) {
    guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
    for context in contexts {
      _ = app.application(UIApplication.shared, open: context.url, options: [:])
    }
  }
}

/// Shapes the iPad pointer as the app's Flutter mouse cursors ask: hidden
/// over the remote screen, where the session paints the remote cursor, and a
/// text beam over text. The iOS embedder has no handler for Flutter's
/// mouse-cursor channel, so the pointer otherwise stays a plain dot.
final class NikoPointer: NSObject, UIPointerInteractionDelegate {
  private var kind = "basic"
  private weak var interaction: UIPointerInteraction?

  init(controller: FlutterViewController) {
    super.init()
    let interaction = UIPointerInteraction(delegate: self)
    controller.view.addInteraction(interaction)
    self.interaction = interaction
    FlutterMethodChannel(name: "flutter/mousecursor", binaryMessenger: controller.binaryMessenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "activateSystemCursor",
          let kind = (call.arguments as? [String: Any])?["kind"] as? String
        else { return result(FlutterMethodNotImplemented) }
        self?.show(kind)
        result(nil)
      }
  }

  private func show(_ kind: String) {
    guard kind != self.kind else { return }
    self.kind = kind
    interaction?.invalidate()
  }

  // One region per cursor kind: a new kind is a new region, so UIKit asks for
  // its style again instead of keeping the last one.
  func pointerInteraction(
    _ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
    defaultRegion: UIPointerRegion
  ) -> UIPointerRegion? {
    UIPointerRegion(rect: defaultRegion.rect, identifier: kind)
  }

  func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion)
    -> UIPointerStyle?
  {
    switch kind {
    case "none": return .hidden()
    case "text": return UIPointerStyle(shape: .verticalBeam(length: 22), constrainedAxes: [])
    case "verticalText":
      return UIPointerStyle(shape: .horizontalBeam(length: 22), constrainedAxes: [])
    default: return .system()
    }
  }
}
