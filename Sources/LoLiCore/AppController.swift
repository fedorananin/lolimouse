// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import Combine
import CoreGraphics
import Foundation
import HIDKit
import HIDPP
import os.log

/// Ties everything together: configuration, devices, hardware reconciliation
/// and the event pipeline.
public final class AppController: ObservableObject {
    private static let log = LoLiLog.app

    public static let shared = AppController()

    public let store = ConfigurationStore()
    public let registry = DeviceRegistry()
    public let reconciler = HardwareReconciler()
    public let actions = ActionRunner()

    @Published public private(set) var hasAccessibility = false
    @Published public private(set) var hasInputMonitoring = false
    @Published public private(set) var isRunning = false

    private lazy var router = DivertedButtonRouter(actions: actions)
    private var eventTap: EventTap?

    /// The event thread's view of the world. Guarded by `snapshotLock`;
    /// everything else in this class stays on the main thread.
    private let snapshotLock = NSLock()
    private var snapshot = EventSnapshot()

    /// One scroll processor per device, so accumulator state is not shared
    /// between a mouse and a trackball plugged in at the same time.
    private var scrollProcessors: [String: ScrollProcessor] = [:]
    /// One modifier transformer per device, for the same reason — pinch state
    /// must not leak between devices.
    private var modifierTransformers: [String: ModifierKeyTransformer] = [:]
    /// Only ever touched from the event thread.
    private var swallowedButtons: Set<Int> = []

    private var subscriptions = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var batteryTimer: Timer?

    private init() {
        actions.onDeviceAction = { [weak self] action, device in
            self?.performDeviceAction(action, device: device)
        }
        router.configurationProvider = { [weak self] key in
            self?.store.configuration.device(key) ?? DeviceConfiguration()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        refreshPermissions()

        registry.onDevicesChanged = { [weak self] devices, arrived in
            self?.devicesChanged(devices, arrived: arrived)
        }
        registry.start()

        store.$configuration
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] configuration in
                self?.configurationChanged(configuration)
            }
            .store(in: &subscriptions)

        updateEventTap()

        // Permissions are granted outside the app, so poll for the moment they
        // appear rather than making the user restart.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }

        startBatteryTimer()

        // A sleeping Mac still wakes briefly on its own (DarkWake) and any HID
        // request we make then can turn that into a full wake. So the battery
        // poll and the reconciler are both parked until the real wake. Learned
        // from OpenLogi, which hit exactly this.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            os_log("going to sleep; pausing HID traffic", log: Self.log, type: .info)
            batteryTimer?.invalidate()
            batteryTimer = nil
            reconciler.suspend()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Waking from sleep is the single most reliable way to lose every
            // volatile hardware setting at once.
            os_log("woke from sleep; reapplying everything", log: Self.log, type: .info)
            reconciler.resume()
            reconcileAll(confirm: true, reason: "system wake")
            registry.refreshBatteries()
            startBatteryTimer()
        }
    }

    /// Battery drains over hours; ten minutes keeps the reading honest without
    /// waking the mouse's radio for nothing.
    private func startBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.registry.refreshBatteries()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        permissionTimer?.invalidate()
        permissionTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        removeEventTap()
        router.detachAll()
        // Quitting while asleep is rare but must still put the mouse back.
        reconciler.resume()
        reconciler.restoreAll(devices: registry.devices)
        registry.stop()
        store.flush()
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        let accessibility = EventTap.hasAccessibilityPermission
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        // Opening any HID device requires Input Monitoring, so a device list
        // that came back empty while devices are plainly attached is the signal.
        let inputMonitoring = registry.devices.contains { $0.endpoint?.isValid == true }
            || hidAccess == kIOHIDAccessTypeGranted

        if !hasLoggedPermissions || accessibility != hasAccessibility || inputMonitoring != hasInputMonitoring {
            hasLoggedPermissions = true
            os_log("""
            permissions: accessibility=%{public}@ inputMonitoring=%{public}@ \
            (IOHIDCheckAccess=%{public}d) bundle=%{public}@ path=%{public}@
            """,
            log: Self.log, type: .info,
            accessibility ? "granted" : "denied",
            inputMonitoring ? "granted" : "denied",
            hidAccess.rawValue,
            Bundle.main.bundleIdentifier ?? "(none)",
            Bundle.main.bundlePath)
        }

        if accessibility != hasAccessibility || inputMonitoring != hasInputMonitoring {
            hasAccessibility = accessibility
            hasInputMonitoring = inputMonitoring
            if accessibility { updateEventTap() }
        }
    }

    /// Ensures the permission state is logged at least once per launch, even
    /// when nothing changes — otherwise a permanently denied grant is silent.
    private var hasLoggedPermissions = false

    public func requestAccessibility() {
        EventTap.requestAccessibilityPermission()
    }

    public func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Events

    /// Installs or removes the event tap to match what the configuration
    /// actually needs.
    ///
    /// An active tap at the HID level sits in the path of every input event on
    /// the machine, so LoLiMouse only installs one while at least one device
    /// has scrolling or button settings switched on. With nothing configured
    /// the app has no presence in the input path at all — which is both the
    /// safe default and the honest one.
    private func updateEventTap() {
        let configuration = store.configuration
        let needed = configuration.enabled && registry.devices.contains { device in
            let deviceConfiguration = configuration.device(device.key)
            return deviceConfiguration.scrolling.managesAnything
                || deviceConfiguration.buttons.mappings.enabled
        }

        if !needed {
            if eventTap != nil {
                os_log("no scrolling or button settings are active; removing the event tap",
                       log: Self.log, type: .info)
                removeEventTap()
            }
            return
        }

        // `flagsChanged` is watched only while some device binds a modifier to
        // pinch zoom — it is what ends the synthesised gesture. Every other
        // configuration keeps the narrower mask.
        var watched = EventTap.defaultWatchedEvents
        let wantsFlags = configuration.enabled && registry.devices.contains {
            configuration.device($0.key).scrolling.wantsFlagsChanged
        }
        if wantsFlags { watched.append(.flagsChanged) }

        if let eventTap, eventTap.watchedEvents != watched {
            os_log("the set of watched events changed; replacing the event tap",
                   log: Self.log, type: .info)
            removeEventTap()
        }

        guard eventTap == nil, EventTap.hasAccessibilityPermission else { return }

        let tap = EventTap(watchedEvents: watched) { [weak self] event, type in
            self?.handle(event: event, type: type) ?? event
        }
        tap.onPermissionLost = { [weak self] in
            self?.eventTap = nil
            self?.refreshPermissions()
        }
        _ = tap.start()
        eventTap = tap
    }

    /// Stops the tap and ends any synthesised gesture still in flight, so an
    /// application never sees a pinch that began and never ended.
    private func removeEventTap() {
        eventTap?.stop()
        eventTap = nil
        for transformer in modifierTransformers.values {
            transformer.deactivate()
        }
    }

    /// Runs on the event thread for every input event in the system. Anything
    /// slow here is felt as input lag, so the fast path is kept short.
    ///
    /// The tap callback runs on its own thread while devices and configuration
    /// live on the main thread, so it never reads either directly. Instead it
    /// takes one lock, copies out an immutable snapshot, and works from that.
    private func handle(event: CGEvent, type: CGEventType) -> CGEvent? {
        guard !event.isSynthetic else { return event }

        snapshotLock.lock()
        let snapshot = self.snapshot
        snapshotLock.unlock()

        guard snapshot.enabled else { return event }

        switch type {
        case .scrollWheel:
            return handleScroll(event, snapshot: snapshot)
        case .flagsChanged:
            // A modifier was pressed or released. Devices cannot be told apart
            // here (the event comes from the keyboard), so every transformer
            // gets the chance to end its pinch. Never swallowed.
            for transformer in snapshot.modifierTransformers.values {
                _ = transformer.process(event, type: type)
            }
            return event
        case .otherMouseDown, .otherMouseUp:
            return handleButton(event, type: type, snapshot: snapshot)
        default:
            return event
        }
    }

    private func handleScroll(_ event: CGEvent, snapshot: EventSnapshot) -> CGEvent? {
        guard let key = snapshot.deviceKey(for: event) else { return event }

        var current = event
        if let transformer = snapshot.modifierTransformers[key] {
            guard let transformed = transformer.process(current, type: .scrollWheel) else { return nil }
            current = transformed
        }
        guard let processor = snapshot.processors[key] else { return current }
        return processor.process(current)
    }

    private func handleButton(_ event: CGEvent, type: CGEventType, snapshot: EventSnapshot) -> CGEvent? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        if type == .otherMouseUp {
            // Release must be swallowed too, or applications see an unmatched
            // mouse-up and some of them get confused about drag state.
            if swallowedButtons.remove(button) != nil { return nil }
            return event
        }

        guard let key = snapshot.deviceKey(for: event),
              let mapping = ButtonMapping.bestMatch(
                  in: snapshot.buttonMappings[key] ?? [],
                  button: button,
                  held: ModifierKey.held(in: event.flags)
              )
        else {
            return event
        }

        guard actions.run(mapping.action, device: snapshot.devices[key]) else { return event }
        swallowedButtons.insert(button)
        return nil
    }

    /// An immutable view of everything the event thread needs, published from
    /// the main thread whenever devices or configuration change.
    private struct EventSnapshot {
        var enabled = false
        var senderToKey: [UInt64: String] = [:]
        /// The only configured device, used when macOS cannot tell us which
        /// device produced an event. With several configured devices, guessing
        /// would be worse than doing nothing.
        var soleConfiguredKey: String?
        var processors: [String: ScrollProcessor] = [:]
        var modifierTransformers: [String: ModifierKeyTransformer] = [:]
        var buttonMappings: [String: [ButtonMapping]] = [:]
        var devices: [String: ManagedDevice] = [:]

        func deviceKey(for event: CGEvent) -> String? {
            if let senderID = event.senderID, let key = senderToKey[senderID] {
                return key
            }
            return soleConfiguredKey
        }
    }

    // MARK: - Reacting to change

    private func devicesChanged(_ devices: [ManagedDevice], arrived: [ManagedDevice]) {
        router.retain(devices)
        rebuildProcessors(devices)
        updateEventTap()

        for device in devices {
            let configuration = store.configuration.device(device.key)
            if !configuration.buttons.divertedControls.isEmpty {
                router.attach(device)
            }
            // Remember the name so an unplugged device still has a label.
            if store.configuration.devices[device.key] != nil,
               store.configuration.device(device.key).displayName != device.displayName {
                store.updateDevice(device.key) { $0.displayName = device.displayName }
            }
        }

        // A device that has just appeared gets the confirming second pass; the
        // rest only need reconciling if something actually changed.
        for device in arrived {
            reconciler.reconcile(
                device: device,
                configuration: store.configuration.device(device.key),
                globallyEnabled: store.configuration.enabled,
                confirm: true,
                reason: "device arrived"
            )
        }

        refreshPermissions()
    }

    private func configurationChanged(_ configuration: Configuration) {
        rebuildProcessors(registry.devices)
        updateEventTap()

        for device in registry.devices {
            let deviceConfiguration = configuration.device(device.key)
            if deviceConfiguration.buttons.divertedControls.isEmpty {
                router.detach(device.key)
            } else {
                router.attach(device)
            }
            reconciler.reconcile(
                device: device,
                configuration: deviceConfiguration,
                globallyEnabled: configuration.enabled,
                reason: "configuration changed"
            )
        }
    }

    /// Rebuilds the event thread's snapshot. Main thread only.
    private func rebuildProcessors(_ devices: [ManagedDevice]) {
        let configuration = store.configuration

        var processors: [String: ScrollProcessor] = [:]
        var transformers: [String: ModifierKeyTransformer] = [:]
        var senderToKey: [UInt64: String] = [:]
        var buttonMappings: [String: [ButtonMapping]] = [:]
        var deviceMap: [String: ManagedDevice] = [:]

        for device in devices {
            let deviceConfiguration = configuration.device(device.key)

            // Reuse the existing processor so accumulator state survives a
            // settings change made in the middle of a scroll.
            let processor = scrollProcessors[device.key] ?? ScrollProcessor()
            processor.settings = deviceConfiguration.scrolling
            processor.highResolutionMultiplier = multiplier(for: device)
            processors[device.key] = processor

            // Same for the modifier transformer: replacing it mid-pinch would
            // strand the gesture without its "ended" event.
            if let actions = deviceConfiguration.scrolling.modifiers.effective, !actions.isEmpty {
                let transformer = modifierTransformers[device.key] ?? ModifierKeyTransformer()
                transformer.actions = actions
                transformers[device.key] = transformer
            } else if let existing = modifierTransformers[device.key] {
                existing.deactivate()
            }

            for senderID in device.senderIDs {
                senderToKey[senderID] = device.key
            }
            if let mappings = deviceConfiguration.buttons.mappings.effective, !mappings.isEmpty {
                buttonMappings[device.key] = mappings
            }
            deviceMap[device.key] = device
        }

        scrollProcessors = processors
        modifierTransformers = transformers

        let configured = devices.filter { configuration.devices[$0.key] != nil }

        snapshotLock.lock()
        snapshot = EventSnapshot(
            enabled: configuration.enabled,
            senderToKey: senderToKey,
            soleConfiguredKey: configured.count == 1 ? configured.first?.key : nil,
            processors: processors,
            modifierTransformers: transformers,
            buttonMappings: buttonMappings,
            devices: deviceMap
        )
        snapshotLock.unlock()
    }

    /// The wheel's high-resolution multiplier, needed to fold increments back
    /// into detents. Cached on the device so this stays off the event path.
    private var multiplierCache: [String: Int] = [:]

    private func multiplier(for device: ManagedDevice) -> Int {
        if let cached = multiplierCache[device.key] { return cached }
        guard let target = device.target else { return 1 }

        // Reading the wheel costs a round trip, so do it once, off the main
        // thread, and cache the answer.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let capabilities = try? target.wheelCapabilities().get() else { return }
            let mode = try? target.wheelMode().get()
            let value = (mode?.resolution == .high) ? Int(capabilities.multiplier) : 1
            DispatchQueue.main.async {
                guard let self else { return }
                self.multiplierCache[device.key] = max(value, 1)
                self.rebuildProcessors(self.registry.devices)
            }
        }
        return 1
    }

    public func invalidateMultiplier(for key: String) {
        multiplierCache.removeValue(forKey: key)
        rebuildProcessors(registry.devices)
    }

    private func reconcileAll(confirm: Bool, reason: String) {
        multiplierCache.removeAll()
        for device in registry.devices {
            reconciler.reconcile(
                device: device,
                configuration: store.configuration.device(device.key),
                globallyEnabled: store.configuration.enabled,
                confirm: confirm,
                reason: reason
            )
        }
    }

    // MARK: - Device-level actions

    private func performDeviceAction(_ action: Action, device: ManagedDevice?) {
        guard let device else { return }
        let key = device.key

        switch action {
        case .cycleDPIPresets:
            var configuration = store.configuration.device(key)
            guard configuration.hardware.dpiPresets.enabled else {
                os_log("DPI presets are switched off for %{public}@; ignoring",
                       log: Self.log, type: .info, device.displayName)
                return
            }
            configuration.hardware.dpiPresets.value = configuration.hardware.dpiPresets.value.next()
            store.updateDevice(key) { $0 = configuration }

        case let .dpiPreset(index):
            guard store.configuration.device(key).hardware.dpiPresets.enabled else { return }
            store.updateDevice(key) { $0.hardware.dpiPresets.value.activeIndex = index }

        case .toggleWheelRatchet:
            var configuration = store.configuration.device(key)
            guard configuration.hardware.wheelRatchet.enabled else {
                os_log("wheel ratchet control is switched off for %{public}@; ignoring",
                       log: Self.log, type: .info, device.displayName)
                return
            }
            let current = configuration.hardware.wheelRatchet.value
            configuration.hardware.wheelRatchet.value.mode = current.mode == .freeSpin
                ? .alwaysRatchet
                : .freeSpin
            store.updateDevice(key) { $0 = configuration }

        default:
            break
        }
    }
}
