import Foundation

// Interface between the Mac Catalyst app and the AppKit status-bar plug-in
// (StatusBarPlugin.bundle in Contents/PlugIns). Mac Catalyst cannot use
// NSStatusItem directly, so the menu-bar item lives in a small macOS bundle
// that the app loads at launch. This file is compiled into both targets; the
// explicit Objective-C names keep the two copies of each protocol identical
// at runtime. Only Foundation types cross the boundary.

/// Implemented by the Catalyst app, called by the plug-in.
@objc(HKMStatusBarHost)
public protocol StatusBarHost: NSObjectProtocol {
    /// Read-only status lines shown at the top of the menu, refreshed each time it opens.
    func statusLines() -> [String]
    /// Opens a new status window. The plug-in calls it only when none exists.
    func showStatusWindow()
    /// Path of the server log, opened by "Open Log".
    func logPath() -> String
}

/// Implemented by the plug-in's principal class.
@objc(HKMStatusBarPlugin)
public protocol StatusBarPlugin: NSObjectProtocol {
    init()
    func install(host: StatusBarHost)
}
