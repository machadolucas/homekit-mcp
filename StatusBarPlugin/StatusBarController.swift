import AppKit
import ObjectiveC

/// Menu-bar item for HomeKitMCP. Loaded by the Mac Catalyst app from
/// Contents/PlugIns/StatusBarPlugin.bundle (see Shared/StatusBarBridge.swift).
///
/// Besides the status item it changes one piece of app behaviour that only
/// AppKit can reach: Catalyst's application delegate quits the app when its
/// last window closes. This app is a background server, so closing the status
/// window must leave it running.
@objc(HKMStatusBarController)
final class StatusBarController: NSObject, StatusBarPlugin, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var host: StatusBarHost?
    private let menu = NSMenu()
    /// Number of host status lines currently at the top of the menu.
    private var statusLineCount = 0
    private var launchWindowObserver: NSObjectProtocol?

    required override init() {
        super.init()
    }

    func install(host: StatusBarHost) {
        self.host = host
        keepRunningWithoutWindows()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "homekit", accessibilityDescription: "HomeKit MCP")
            ?? NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HomeKit MCP")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "HomeKit MCP"

        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(.separator())
        menu.addItem(actionItem("Show Status Window", #selector(showStatusWindow), key: "s"))
        menu.addItem(actionItem("Open Log", #selector(openLog), key: "l"))
        menu.addItem(.separator())
        let restart = actionItem("Restart Server", #selector(restartServer), key: "r")
        restart.toolTip = "Quits the app; launchd (KeepAlive) starts it again within about 30 seconds."
        menu.addItem(restart)
        item.menu = menu
        statusItem = item
        refreshStatusLines()

        // SwiftUI opens the status window at launch (and macOS may restore earlier
        // ones). Order them out as they appear, until the window is asked for.
        launchWindowObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusWindows().filter(\.isVisible).forEach { $0.orderOut(nil) }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusLines()
    }

    // MARK: - Actions

    @objc private func showStatusWindow() {
        if let observer = launchWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            launchWindowObserver = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = statusWindows().first {
            window.makeKeyAndOrderFront(nil)
        } else {
            host?.showStatusWindow()
        }
    }

    @objc private func openLog() {
        guard let path = host?.logPath() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func restartServer() {
        exit(0)
    }

    // MARK: - Helpers

    private func actionItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// The app's SwiftUI windows (Catalyst's `UINSWindow`), excluding the status item's own window.
    private func statusWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.className == "UINSWindow" }
    }

    private func refreshStatusLines() {
        for _ in 0..<statusLineCount {
            menu.removeItem(at: 0)
        }
        let lines = host?.statusLines() ?? []
        for (index, line) in lines.enumerated() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: index)
        }
        statusLineCount = lines.count
    }

    /// Makes `applicationShouldTerminateAfterLastWindowClosed:` answer NO on
    /// the class of the (Catalyst-provided) application delegate.
    private func keepRunningWithoutWindows() {
        guard let delegate = NSApp.delegate else { return }
        let selector = #selector(NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed(_:))
        let block: @convention(block) (AnyObject, NSApplication) -> Bool = { _, _ in false }
        // Signature: BOOL (id self, SEL _cmd, NSApplication *sender)
        class_replaceMethod(type(of: delegate), selector, imp_implementationWithBlock(block), "c@:@")
    }
}
