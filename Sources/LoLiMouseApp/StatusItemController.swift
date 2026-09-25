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
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let store: ConfigurationStore
    /// Brings the settings window forward; supplied by the app delegate, which
    /// owns the reopen logic.
    private let openSettings: () -> Void
    private let loginItem = LoginItem()

    private var statusItem: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    /// One subscription per device, because `battery` is published on
    /// `ManagedDevice` rather than on the registry. Keyed by object identity,
    /// not by `device.key`: a rescan builds *new* `ManagedDevice` instances
    /// for the same mice, and keying by the stable key made this hold on to
    /// the discarded object — the title then froze at the level read during
    /// that scan while the menu, which reads the live device, moved on.
    private var batteryObservations: [ObjectIdentifier: AnyCancellable] = [:]
    /// A DPI reading that replaces the whole title for a moment after a preset
    /// change, then gives the charge readings back.
    private var dpiFlash: String?
    private var dpiFlashReset: DispatchWorkItem?
    private static let dpiFlashDuration: TimeInterval = 2

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

        controller.dpiAnnouncements
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dpi in self?.flashDPI(dpi) }
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
        let identities = Set(devices.map { ObjectIdentifier($0) })
        for identity in batteryObservations.keys.filter({ !identities.contains($0) }) {
            batteryObservations.removeValue(forKey: identity)
        }
        for device in devices where batteryObservations[ObjectIdentifier(device)] == nil {
            batteryObservations[ObjectIdentifier(device)] = device.$battery
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateBatteryTitle() }
        }
        updateBatteryTitle()
    }

    /// Which devices are shown is the user's call, one checkbox per device in
    /// its settings page; see `MenuBarBattery` for the formatting rules.
    private func updateBatteryTitle() {
        guard let button = statusItem?.button else { return }
        if let dpiFlash {
            button.title = dpiFlash
            return
        }
        let configuration = store.configuration
        button.title = MenuBarBattery.title(for: controller.registry.devices.map { device in
            (shown: configuration.device(device.key).showBatteryInMenuBar, battery: device.battery)
        })
    }

    // MARK: - DPI

    /// Pressing the button again while a reading is up restarts the timer, so
    /// the title only goes back once the user stops cycling.
    private func flashDPI(_ dpi: Int) {
        dpiFlash = MenuBarBattery.label(forDPI: dpi)
        dpiFlashReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.dpiFlash = nil
            self?.updateBatteryTitle()
        }
        dpiFlashReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dpiFlashDuration, execute: reset)
        updateBatteryTitle()
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

        // Re-read on every opening: the user can change the login item in
        // System Settings while the app runs.
        loginItem.refresh()
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItem.isEnabled ? .on : .off
        menu.addItem(login)

        // Always ticked while the menu can be opened at all; unticking it hides
        // the icon, and the settings window is the way back.
        let menuBar = NSMenuItem(title: "Show in menu bar", action: #selector(toggleMenuBarIcon), keyEquivalent: "")
        menuBar.target = self
        menuBar.state = store.configuration.showMenuBarIcon ? .on : .off
        menu.addItem(menuBar)

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

    @objc private func toggleLoginItem() {
        loginItem.setEnabled(!loginItem.isEnabled)
    }

    @objc private func toggleMenuBarIcon() {
        store.update { $0.showMenuBarIcon.toggle() }
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
