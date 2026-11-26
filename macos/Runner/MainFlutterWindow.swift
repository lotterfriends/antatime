import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerAutostartChannel(flutterViewController.engine.binaryMessenger)
    registerUpdateChannel(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// Updates (lib/update/): Die App läuft in der Sandbox und kann sich nicht
  /// selbst ersetzen – der Browser lädt das Disk-Image der neuen Version.
  private func registerUpdateChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "antatime/update", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "open":
        if let text = call.arguments as? String, let url = URL(string: text),
           url.scheme == "https" || url.scheme == "http" {
          result(NSWorkspace.shared.open(url))
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Start mit dem System als Anmeldeobjekt (lib/desktop/autostart_io.dart).
  private func registerAutostartChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "antatime/autostart", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(macOS 13.0, *) else {
        if call.method == "setEnabled" {
          result(FlutterError(code: "unsupported",
                              message: "Autostart erfordert macOS 13 oder neuer", details: nil))
        } else {
          result(false)
        }
        return
      }
      let service = SMAppService.mainApp
      switch call.method {
      case "isEnabled":
        result(service.status == .enabled)
      case "setEnabled":
        do {
          if call.arguments as? Bool == true {
            try service.register()
          } else {
            try service.unregister()
          }
          result(nil)
        } catch {
          result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        }
      case "launchedAtLogin":
        // Anmeldeobjekte erhalten keine Argumente: Start in den ersten
        // Minuten nach dem Hochfahren gilt als Autostart.
        result(service.status == .enabled && ProcessInfo.processInfo.systemUptime < 300)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
