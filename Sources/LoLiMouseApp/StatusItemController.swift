// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import Combine
import LoLiCore

/// Owns the menu bar item.
///
/// This is deliberately AppKit rather than SwiftUI's `MenuBarExtra`: a
/// `MenuBarExtra` is a *scene*, and when the user hides it (System Settings ›
/// Menu Bar, or ⌘-dragging it off) SwiftUI treats the app as having nothing
/// left to show and terminates it — taking every managed mouse setting down
/// with it. A plain `NSStatusItem` is just a view: hiding it leaves the
/// process, the event tap and the reconciler running.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let store: ConfigurationStore
    /// Brings the settings window forward; supplied by the app delegate, which
    /// owns the reopen logic.
    private let openSettings: () -> Void

    private var statusItem: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController, openSettings: @escaping () -> Void) {
        self.controller = controller
        store = controller.store
        self.openSettings = openSettings
        super.init()

        store.$configuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configuration in self?.apply(configuration) }
            .store(in: &cancellables)
    }

    private func apply(_ configuration: Configuration) {
        if configuration.showMenuBarIcon {
            let item = statusItem ?? makeStatusItem()
            statusItem = item
            if !item.isVisible { item.isVisible = true }
            item.button?.image = NSImage(
                systemSymbolName: configuration.enabled ? "computermouse.fill" : "computermouse",
                accessibilityDescription: "LoLiMouse"
            )
        } else if let item = statusItem, item.isVisible {
            item.isVisible = false
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // `removalAllowed` lets the user ⌘-drag the item off the bar. What must
        // never be set here is `terminationOnRemoval` — removing the icon has
        // to hide the icon, not kill the app.
        item.behavior = .removalAllowed
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // The user can hide the item behind our back (⌘-drag, or the Menu Bar
        // section of System Settings), so mirror that back into the
        // configuration to keep the in-app checkbox honest. Writing the value
        // it already has is a no-op in the store, which breaks the loop with
        // `apply(_:)`.
        visibilityObservation = item.observe(\.isVisible) { [weak self] item, _ in
            guard let self else { return }
            let visible = item.isVisible
            DispatchQueue.main.async {
                self.store.update { $0.showMenuBarIcon = visible }
            }
        }
        return item
    }

    // MARK: - Menu

    /// The menu is rebuilt every time it opens; device names and battery
    /// levels change too often for a static one to stay truthful.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enable = NSMenuItem(title: "Enable LoLiMouse", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.target = self
        enable.state = store.configuration.enabled ? .on : .off
        menu.addItem(enable)

        menu.addItem(.separator())

        let devices = controller.registry.devices
        if devices.isEmpty {
            menu.addItem(disabledItem("No mice detected"))
        } else {
            for device in devices {
                menu.addItem(disabledItem(label(for: device)))
            }
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let rescan = NSMenuItem(title: "Re-scan devices", action: #selector(rescanDevices), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit LoLiMouse", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func label(for device: ManagedDevice) -> String {
        guard let battery = device.battery, let percentage = battery.percentage else {
            return device.displayName
        }
        return "\(device.displayName) — \(percentage)%\(battery.charging ? " ⚡" : "")"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        store.update { $0.enabled.toggle() }
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func rescanDevices() {
        controller.registry.rescan()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
