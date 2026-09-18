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
    /// One subscription per device, because `battery` is published on
    /// `ManagedDevice` rather than on the registry.
    private var batteryObservations: [String: AnyCancellable] = [:]

    init(controller: AppController, openSettings: @escaping () -> Void) {
        self.controller = controller
        store = controller.store
        self.openSettings = openSettings
        super.init()

        store.$configuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configuration in self?.apply(configuration) }
            .store(in: &cancellables)

        controller.registry.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in self?.observeBatteries(devices) }
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
            updateBatteryTitle()
        } else if let item = statusItem, item.isVisible {
            item.isVisible = false
        }
    }

    // MARK: - Battery

    /// Keeps one battery subscription alive per device. Devices that have gone
    /// away drop theirs; new ones get one when they are published.
    private func observeBatteries(_ devices: [ManagedDevice]) {
        let keys = Set(devices.map(\.key))
        for key in batteryObservations.keys.filter({ !keys.contains($0) }) {
            batteryObservations.removeValue(forKey: key)
        }
        for device in devices where batteryObservations[device.key] == nil {
            batteryObservations[device.key] = device.$battery
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateBatteryTitle() }
        }
        updateBatteryTitle()
    }

    /// Which devices are shown is the user's call, one checkbox per device in
    /// its settings page; see `MenuBarBattery` for the formatting rules.
    private func updateBatteryTitle() {
        guard let button = statusItem?.button else { return }
        let configuration = store.configuration
        button.title = MenuBarBattery.title(for: controller.registry.devices.map { device in
            (shown: configuration.device(device.key).showBatteryInMenuBar, battery: device.battery)
        })
    }

    private func makeStatusItem() -> NSStatusItem {
        // Variable length so the reading can sit next to the icon. With a
        // square item the title would be clipped away entirely.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // AppKit's default for a status button puts the title first; the
        // reading belongs after the mouse.
        item.button?.imagePosition = .imageLeading
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
        guard let battery = device.battery, let charge = MenuBarBattery.label(for: battery) else {
            return device.displayName
        }
        return "\(device.displayName) — \(charge)"
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
