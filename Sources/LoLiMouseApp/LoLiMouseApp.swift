// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import LoLiCore
import SwiftUI

@main
struct LoLiMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared
    @StateObject private var store = AppController.shared.store

    var body: some Scene {
        mainWindow

        MenuBarExtra("LoLiMouse", systemImage: store.configuration.enabled ? "computermouse.fill" : "computermouse") {
            MenuBarContent()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .environmentObject(controller.registry)
        }
    }

    /// The settings window. Launching the app never opens it by itself —
    /// LoLiMouse starts quietly in the menu bar, which is what makes "start at
    /// login" unobtrusive. Launching the app again (or the menu bar's
    /// Settings…) is what brings the window up.
    private var mainWindow: some Scene {
        Window("LoLiMouse", id: "main") {
            RootView()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .environmentObject(controller.registry)
                .environmentObject(controller.reconciler)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        AppController.shared.start()

        // The Dock icon follows the settings window. LoLiMouse lives in the
        // menu bar; a Dock entry with no window behind it is just clutter, so
        // the activation policy flips to `.accessory` whenever the last real
        // window closes and back to `.regular` when one appears.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)

        // SwiftUI has not restored its windows yet at this point, so the
        // launch-time check has to wait until it has had the chance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updateDockVisibility()
        }
    }

    func applicationWillTerminate(_: Notification) {
        // Put every hardware setting back the way it was found. Leaving a mouse
        // in a state the user never chose, with the app no longer running to
        // explain it, is exactly the kind of thing this project exists to stop.
        AppController.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Launching the app while it is already running as a menu-bar resident
    /// should bring the settings window back rather than appearing to do
    /// nothing.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        NSApp.setActivationPolicy(.regular)
        // SwiftUI keeps the closed window instance around, so reordering it
        // front is enough — no need to route through the openWindow action.
        if let window = NSApp.windows.first(where: Self.isSettingsWindow) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// The windows that should hold a place in the Dock. The menu-bar extra's
    /// item and other borderless helpers are not titled, so this filters them
    /// out.
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isSettingsWindow(window) else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isSettingsWindow(window) else { return }
        // The window still counts as visible while this notification is being
        // delivered; re-check once the close has actually happened.
        DispatchQueue.main.async { [weak self] in
            self?.updateDockVisibility()
        }
    }

    private func updateDockVisibility() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && Self.isSettingsWindow($0) }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var registry: DeviceRegistry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Enable LoLiMouse", isOn: Binding(
            get: { store.configuration.enabled },
            set: { newValue in store.update { $0.enabled = newValue } }
        ))

        Divider()

        if registry.devices.isEmpty {
            Text("No mice detected")
        } else {
            ForEach(registry.devices) { device in
                Text(device.displayName)
            }
        }

        Divider()

        Button("Settings…") {
            // The Dock icon comes back with the window; doing it here rather
            // than waiting for the key-window notification avoids the window
            // opening behind whatever was frontmost.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Re-scan devices") {
            controller.registry.rescan()
        }

        Divider()

        Button("Quit LoLiMouse") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
