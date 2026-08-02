// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import LoLiCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var registry: DeviceRegistry

    @State private var selection: SidebarItem?
    @StateObject private var loginItem = LoginItem()

    enum SidebarItem: Hashable {
        case device(String)
        case permissions
        case about
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .onAppear(perform: selectSomething)
        .onChange(of: registry.devices.count) { _ in selectSomething() }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Devices") {
                if registry.devices.isEmpty {
                    Label("Looking for mice…", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(registry.devices) { device in
                        DeviceRow(device: device)
                            .tag(SidebarItem.device(device.key))
                    }
                }
            }

            Section {
                Label("Permissions", systemImage: permissionsOK ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(permissionsOK ? Color.primary : Color.orange)
                    .tag(SidebarItem.permissions)
                Label("About", systemImage: "info.circle")
                    .tag(SidebarItem.about)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("LoLiMouse enabled", isOn: Binding(
                    get: { store.configuration.enabled },
                    set: { newValue in store.update { $0.enabled = newValue } }
                ))
                .toggleStyle(.switch)

                Toggle("Start at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { newValue in loginItem.setEnabled(newValue) }
                ))
                .toggleStyle(.checkbox)

                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.bar)
        }
        // The user can flip the login item in System Settings behind our back,
        // so re-read it whenever the window comes forward.
        .onAppear { loginItem.refresh() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .device(key):
            if let device = registry.device(key: key) {
                DeviceDetailView(device: device)
                    .id(key)
            } else {
                ContentUnavailableMessage(
                    title: "Device disconnected",
                    message: "Its settings are kept and will be reapplied automatically when it comes back."
                )
            }
        case .permissions:
            PermissionsView()
        case .about:
            AboutView()
        case nil:
            ContentUnavailableMessage(
                title: "No device selected",
                message: "Pick a mouse on the left to configure it."
            )
        }
    }

    private var permissionsOK: Bool {
        controller.hasAccessibility && controller.hasInputMonitoring
    }

    private func selectSomething() {
        guard selection == nil else { return }
        if let first = registry.devices.first {
            selection = .device(first.key)
        } else if !permissionsOK {
            selection = .permissions
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var device: ManagedDevice
    @EnvironmentObject private var store: ConfigurationStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "computermouse")
                .foregroundStyle(device.supportsHardwareSettings ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let configuration = store.configuration.devices[device.key]
        if configuration?.managesAnything == true { return "Configured" }
        return device.supportsHardwareSettings ? "Logitech HID++" : "Basic support"
    }
}

struct ContentUnavailableMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.medium))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceDetailView: View {
    @ObservedObject var device: ManagedDevice
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var reconciler: HardwareReconciler

    var body: some View {
        let model = DeviceSettingsModel(device: device, store: store)

        return VStack(spacing: 0) {
            header
            Divider()
            TabView {
                ScrollView { WheelSection(model: model).padding(20) }
                    .tabItem { Label("Wheel", systemImage: "circle.dashed") }
                ScrollView { ScrollingSection(model: model).padding(20) }
                    .tabItem { Label("Scrolling", systemImage: "arrow.up.and.down") }
                ScrollView { PointerSection(model: model).padding(20) }
                    .tabItem { Label("Pointer", systemImage: "cursorarrow") }
                ScrollView { ButtonsSection(model: model).padding(20) }
                    .tabItem { Label("Buttons", systemImage: "hand.point.up.left") }
            }
            .padding(.top, 8)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.title2.weight(.semibold))
                Text(device.supportsHardwareSettings
                    ? "Logitech HID++ — hardware settings available"
                    : "Generic pointing device — scrolling and buttons only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            batteryBadge
            statusBadge
        }
        .padding(20)
    }

    @ViewBuilder
    private var batteryBadge: some View {
        if let battery = device.battery, let percentage = battery.percentage {
            Label("\(percentage)%", systemImage: batteryIcon(percentage, charging: battery.charging))
                .foregroundStyle(percentage <= 10 && !battery.charging ? Color.orange : Color.secondary)
                .help(battery.charging ? "Charging" : "Battery level")
        }
    }

    private func batteryIcon(_ percentage: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percentage {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch reconciler.statuses[device.key] ?? .idle {
        case .idle:
            EmptyView()
        case .applying:
            Label("Applying…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .applied:
            Label("Applied", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .waitingForDevice:
            Label("Waiting for the device to wake", systemImage: "moon.zzz").foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}
