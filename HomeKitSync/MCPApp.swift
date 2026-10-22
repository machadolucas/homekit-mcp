import HomeKit
import SwiftUI
import UIKit

/// Runs as a background server: no Dock icon (`LSUIElement`), a menu-bar item from the
/// AppKit plug-in, and a status window that opens only from that menu. Closing the
/// window leaves the server running (the plug-in stops Catalyst from quitting the app
/// when its last window closes).
@main
struct HomeKitMCPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(server: appDelegate.server)
                .frame(minWidth: 420, minHeight: 320)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject, StatusBarHost {
    let server = AppWrapper()
    private var statusBar: StatusBarPlugin?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        loadStatusBarPlugin()
        return true
    }

    private func loadStatusBarPlugin() {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("StatusBarPlugin.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let pluginClass = bundle.principalClass as? StatusBarPlugin.Type else {
            // Without the plug-in nothing hides the window, so it stays as the only UI.
            log("Status-bar plug-in not loaded; keeping the status window")
            return
        }
        let plugin = pluginClass.init()
        plugin.install(host: self)
        statusBar = plugin
        log("Menu-bar item installed")
    }

    // MARK: - StatusBarHost

    func statusLines() -> [String] {
        server.statusLines()
    }

    /// Called by the plug-in when no status window exists (it was closed): opens a new one.
    func showStatusWindow() {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
    }

    func logPath() -> String {
        // Not sandboxed, so this is the real home folder. The LaunchAgent's `open --stdout` writes here.
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/homekit-mcp.log")
    }

    private func log(_ message: String) {
        print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        fflush(stdout)
    }
}

struct ContentView: View {
    @ObservedObject var server: AppWrapper

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HomeKit MCP Server")
                .font(.title)
                .bold()

            Text("Listening on http://127.0.0.1:\(String(server.port))/mcp (loopback only)")
                .font(.body)

            Text("Organisation tools only: no accessory control.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Tools")
                .font(.headline)
                .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(server.toolNames, id: \.self) { name in
                        Text("• \(name)")
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text("Closing this window keeps the server running. Use the menu-bar item to reopen it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

final class AppWrapper: ObservableObject {
    private let httpServer = HTTPMCPServer()

    var port: UInt16 { httpServer.port }
    var toolNames: [String] { ToolCatalog.tools.compactMap { $0["name"] as? String } }

    func statusLines() -> [String] { httpServer.statusLines() }
}
