// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Combine
import Foundation
import HIDKit
import HIDPP
import os.log

/// Brings each device's hardware into line with its configuration, and keeps it
/// there.
///
/// Three things make this different from just writing settings when the user
/// clicks something:
///
/// 1. **Volatile settings.** SmartShift, DPI, wheel mode and button diversion
///    live in the mouse's RAM. A power cycle — switching the mouse off, letting
///    it sleep, moving it between receivers — silently reverts every one of
///    them. So the desired state is reapplied on every arrival, not just once.
///
/// 2. **The boot race.** A mouse that has just reconnected will accept a HID++
///    write and then finish booting, discarding it. A single confirming reapply
///    a few seconds later costs nothing and closes that window.
///
/// 3. **Restoring on disable.** The first time a setting is written, the value
///    that was there before is remembered. Switching the setting off puts that
///    value back, so LoLiMouse leaves no trace of features you stopped using.
public final class HardwareReconciler: ObservableObject {
    private static let log = LoLiLog.reconcile

    /// What happened on the last attempt, for the UI to show.
    public enum Status: Equatable {
        case idle
        case applying
        case applied
        case waitingForDevice
        case failed(String)
    }

    @Published public private(set) var statuses: [String: Status] = [:]

    private let queue = DispatchQueue(label: "\(LoLiLog.subsystem).reconcile", qos: .utility)
    private let stateLock = NSLock()
    private var baselines: [String: Baseline] = [:]
    private var pendingRetries: [String: DispatchWorkItem] = [:]
    private var attemptCounts: [String: Int] = [:]

    /// Backoff schedule. The device is usually simply asleep, so the early
    /// retries are quick and the later ones back off to avoid waking it
    /// pointlessly.
    private static let retryDelays: [TimeInterval] = [1, 3, 8, 20]
    /// Delay before the confirming reapply that beats the firmware boot race.
    private static let confirmDelay: TimeInterval = 3

    public init() {}

    /// Values as they were before LoLiMouse first wrote them.
    private struct Baseline {
        var smartShift: HIDPPSmartShift?
        var wheelMode: HIDPPWheelMode?
        var dpi: UInt16?
        var reportRate: Int?
        var pointerResolution: Double?
        var pointerAcceleration: Double?
        var linearScaling: Int?
        var divertedControls: [HIDPPControlID: Bool] = [:]
    }

    // MARK: - Entry points

    /// Applies `configuration` to `device`.
    ///
    /// `confirm` schedules the extra pass that guards against the boot race and
    /// should be set when the device has just appeared.
    public func reconcile(
        device: ManagedDevice,
        configuration: DeviceConfiguration,
        globallyEnabled: Bool,
        confirm: Bool = false,
        reason: String
    ) {
        cancelRetry(for: device.key)
        setStatus(.applying, for: device.key)

        queue.async { [weak self] in
            guard let self else { return }
            os_log("reconciling %{public}@ (%{public}@)",
                   log: Self.log, type: .info, device.displayName, reason)

            let outcome = apply(device: device,
                                configuration: configuration,
                                globallyEnabled: globallyEnabled)

            switch outcome {
            case .success:
                attemptCounts[device.key] = 0
                setStatus(.applied, for: device.key)
                if confirm {
                    scheduleConfirm(device: device,
                                    configuration: configuration,
                                    globallyEnabled: globallyEnabled)
                }
            case .nothingToDo:
                attemptCounts[device.key] = 0
                setStatus(.idle, for: device.key)
            case let .retryable(message):
                scheduleRetry(device: device,
                              configuration: configuration,
                              globallyEnabled: globallyEnabled,
                              message: message)
            case let .permanent(message):
                attemptCounts[device.key] = 0
                setStatus(.failed(message), for: device.key)
            }
        }
    }

    /// Restores everything LoLiMouse ever wrote to these devices and forgets the
    /// baselines. Used when the app is quitting or the master switch goes off.
    ///
    /// Bounded on purpose. This runs from `applicationWillTerminate`, where the
    /// work is blocking HID traffic against a device that may be asleep and
    /// will simply time out. macOS gives a terminating app limited time before
    /// killing it, and being killed mid-teardown is how devices get left in a
    /// bad state — so we give up rather than hang.
    public func restoreAll(devices: [ManagedDevice], timeout: TimeInterval = 2) {
        for device in devices {
            cancelRetry(for: device.key)
        }

        // Nothing was ever written, so there is nothing to put back.
        let needingRestore = devices.filter { hasBaseline($0.key) }
        guard !needingRestore.isEmpty else { return }

        let finished = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            for device in needingRestore {
                self?.restore(device: device)
            }
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            os_log("gave up restoring device settings after %{public}.0fs",
                   log: Self.log, type: .error, timeout)
        }
    }

    // MARK: - Application

    private enum Outcome {
        case success
        case nothingToDo
        case retryable(String)
        case permanent(String)
    }

    private func apply(
        device: ManagedDevice,
        configuration: DeviceConfiguration,
        globallyEnabled: Bool
    ) -> Outcome {
        var didSomething = false
        var transientFailure: String?
        var permanentFailure: String?

        // Pointer settings go through macOS and never fail transiently.
        if let service = device.pointerService {
            applyPointer(service: service,
                         key: device.key,
                         settings: globallyEnabled ? configuration.pointer : PointerSettings())
            didSomething = didSomething || configuration.pointer.managesAnything
        }

        guard let target = device.target else {
            return didSomething ? .success : .nothingToDo
        }

        let hardware = globallyEnabled ? configuration.hardware : HardwareSettings()
        let buttons = globallyEnabled ? configuration.buttons : ButtonSettings()

        guard hardware.managesAnything || buttons.divertedControls.isEmpty == false || hasBaseline(device.key)
        else {
            return .nothingToDo
        }

        // A sleeping device answers nothing; there is no point issuing five
        // writes that will each wait out their own timeout.
        guard target.ping() else {
            return .retryable("device is not responding")
        }

        func record(_ result: Result<some Any, HIDPPError>, _ what: String) {
            switch result {
            case .success:
                didSomething = true
            case let .failure(error):
                if error.isTransient {
                    transientFailure = "\(what): \(error.description)"
                } else if case .featureUnsupported = error {
                    // Not an error worth showing: the device simply lacks it.
                    os_log("%{public}@ does not support %{public}@",
                           log: Self.log, type: .info, device.displayName, what)
                } else {
                    permanentFailure = "\(what): \(error.description)"
                }
            }
        }

        record(applyWheelRatchet(target: target, key: device.key, setting: hardware.wheelRatchet), "wheel ratchet")
        record(applyWheelMode(target: target,
                              key: device.key,
                              highResolution: hardware.highResolutionWheel,
                              inverted: hardware.invertScrollInFirmware), "wheel mode")
        record(applyDPI(target: target, key: device.key, hardware: hardware), "DPI")
        record(applyReportRate(target: target, key: device.key, setting: hardware.reportRate), "report rate")
        record(applyDiversion(target: target, key: device.key, buttons: buttons), "button diversion")

        if let permanentFailure {
            return .permanent(permanentFailure)
        }
        if let transientFailure {
            return .retryable(transientFailure)
        }
        return didSomething ? .success : .nothingToDo
    }

    // MARK: - Individual settings

    private func applyWheelRatchet(
        target: HIDPPTarget,
        key: String,
        setting: Setting<WheelRatchetSetting>
    ) -> Result<Void, HIDPPError> {
        guard target.supportsSmartShift else {
            return .failure(.featureUnsupported(.smartShift))
        }

        guard let desired = setting.effective else {
            // Switched off: put back whatever the device had before we started.
            guard let baseline = baseline(key)?.smartShift else { return .success(()) }
            let result = target.setSmartShift(mode: baseline.mode,
                                              autoDisengage: baseline.autoDisengage,
                                              torque: baseline.torque)
            mutateBaseline(key) { $0.smartShift = nil }
            return result.map { _ in () }
        }

        let current = try? target.smartShift().get()
        captureBaselineIfNeeded(key, current, \.smartShift)

        // Skip the write when the device already holds the desired state. This
        // keeps a reapply on every scan essentially free.
        if let current,
           current.mode == desired.hidppMode,
           current.autoDisengage == desired.hidppAutoDisengage,
           desired.torque == nil || current.torque == desired.torque.map({ UInt8(clamping: $0) }) {
            return .success(())
        }

        return target.setSmartShift(
            mode: desired.hidppMode,
            autoDisengage: desired.hidppAutoDisengage,
            torque: desired.torque.map { UInt8(clamping: $0) }
        ).map { _ in () }
    }

    private func applyWheelMode(
        target: HIDPPTarget,
        key: String,
        highResolution: Setting<Bool>,
        inverted: Setting<Bool>
    ) -> Result<Void, HIDPPError> {
        guard highResolution.enabled || inverted.enabled || baseline(key)?.wheelMode != nil else {
            return .success(())
        }
        guard target.supports(.hiResWheel) else {
            return .failure(.featureUnsupported(.hiResWheel))
        }

        let currentResult = target.wheelMode()
        guard case let .success(current) = currentResult else {
            return currentResult.map { _ in () }
        }
        captureBaselineIfNeeded(key, current, \.wheelMode)

        let baselineMode = baseline(key)?.wheelMode
        let desiredResolution: HIDPPWheelResolution = highResolution.effective.map { $0 ? .high : .low }
            ?? baselineMode?.resolution ?? current.resolution
        let desiredInverted = inverted.effective ?? baselineMode?.inverted ?? current.inverted

        if !highResolution.enabled, !inverted.enabled {
            mutateBaseline(key) { $0.wheelMode = nil }
        }

        // Reporting is always steered back to native: diverting the wheel would
        // hand scrolling to us wholesale, which is not what any of this is for.
        if current.resolution == desiredResolution,
           current.inverted == desiredInverted,
           current.target == .native {
            return .success(())
        }

        return target.setWheelMode(target: .native,
                                   resolution: desiredResolution,
                                   inverted: desiredInverted).map { _ in () }
    }

    private func applyDPI(
        target: HIDPPTarget,
        key: String,
        hardware: HardwareSettings
    ) -> Result<Void, HIDPPError> {
        // Presets win when enabled: the active preset is the DPI in force.
        let desired: Int? = hardware.dpiPresets.effective?.active ?? hardware.dpi.effective

        guard desired != nil || baseline(key)?.dpi != nil else { return .success(()) }
        guard target.supports(.adjustableDPI) else {
            return .failure(.featureUnsupported(.adjustableDPI))
        }

        let currentResult = target.dpi()
        guard case let .success(current) = currentResult else {
            return currentResult.map { _ in () }
        }
        captureBaselineIfNeeded(key, current.current, \.dpi)

        guard let desired else {
            guard let baselineDPI = baseline(key)?.dpi else { return .success(()) }
            let result = target.setDPI(baselineDPI)
            mutateBaseline(key) { $0.dpi = nil }
            return result
        }

        let value = UInt16(clamping: desired)
        if current.current == value { return .success(()) }
        return target.setDPI(value)
    }

    private func applyReportRate(
        target: HIDPPTarget,
        key: String,
        setting: Setting<Int>
    ) -> Result<Void, HIDPPError> {
        guard setting.enabled || baseline(key)?.reportRate != nil else { return .success(()) }
        guard target.supports(.reportRate) else {
            return .failure(.featureUnsupported(.reportRate))
        }

        let currentResult = target.reportRate()
        guard case let .success(current) = currentResult else {
            return currentResult.map { _ in () }
        }
        captureBaselineIfNeeded(key, current, \.reportRate)

        guard let desired = setting.effective else {
            guard let baselineRate = baseline(key)?.reportRate else { return .success(()) }
            let result = target.setReportRate(baselineRate)
            mutateBaseline(key) { $0.reportRate = nil }
            return result
        }

        if current == desired { return .success(()) }
        return target.setReportRate(desired)
    }

    /// Diverts exactly the controls the configuration needs, and un-diverts
    /// everything it previously diverted but no longer wants.
    ///
    /// This is what keeps the wheel-mode button toggling SmartShift and the
    /// thumb button opening Mission Control by themselves until the moment the
    /// user asks LoLiMouse to take them over.
    private func applyDiversion(
        target: HIDPPTarget,
        key: String,
        buttons: ButtonSettings
    ) -> Result<Void, HIDPPError> {
        let desired = buttons.divertedControls
        let previouslyDiverted = Set(baseline(key)?.divertedControls.keys ?? [:].keys)

        guard !desired.isEmpty || !previouslyDiverted.isEmpty else { return .success(()) }
        guard target.supportsReprogrammableControls, target.supportsLongReports else {
            return .failure(.featureUnsupported(.reprogrammableControlsV4))
        }

        // Which controls this device actually has. Asking for a control it does
        // not implement is harmless but pointless.
        let available = Set(target.controlTable().filter(\.isDivertable).map(\.controlID))

        var lastError: HIDPPError?

        for control in desired.intersection(available) {
            if baseline(key)?.divertedControls[control] == nil,
               case let .success(reporting) = target.controlReporting(control) {
                mutateBaseline(key) { $0.divertedControls[control] = reporting.diverted }
            }
            // Raw XY is only needed for the gesture button, and only when
            // gestures are actually configured.
            let needsRawXY = HIDPPControl.gestureCapable.contains(control)
            let change = HIDPPControlReportingChange(diverted: true, rawXY: needsRawXY)
            if case let .failure(error) = target.setControlReporting(control, change) {
                lastError = error
            }
        }

        for control in previouslyDiverted.subtracting(desired) {
            let original = baseline(key)?.divertedControls[control] ?? false
            let change = HIDPPControlReportingChange(diverted: original, rawXY: false)
            if case let .failure(error) = target.setControlReporting(control, change) {
                lastError = error
            } else {
                mutateBaseline(key) { $0.divertedControls.removeValue(forKey: control) }
            }
        }

        if let lastError { return .failure(lastError) }
        return .success(())
    }

    private func applyPointer(service: PointerService, key: String, settings: PointerSettings) {
        captureBaselineIfNeeded(key, service.pointerResolution, \.pointerResolution)
        captureBaselineIfNeeded(key, service.pointerAcceleration, \.pointerAcceleration)
        captureBaselineIfNeeded(key, service.linearScalingEnabled, \.linearScaling)

        if let speed = settings.speed.effective {
            // The slider runs 0…1 with 1 as fastest; macOS wants a resolution
            // in counts per inch where *lower* is faster.
            let clamped = min(max(speed, 0), 1)
            service.pointerResolution = 1600 - clamped * 1500
        } else if let original = baseline(key)?.pointerResolution {
            service.pointerResolution = original
            mutateBaseline(key) { $0.pointerResolution = nil }
        }

        if settings.disableAcceleration.effective == true {
            if service.supportsLinearScaling {
                service.linearScalingEnabled = 1
            } else {
                service.pointerAcceleration = -1
            }
        } else {
            if service.supportsLinearScaling, baseline(key)?.linearScaling != nil {
                service.linearScalingEnabled = baseline(key)?.linearScaling ?? 0
                if !settings.disableAcceleration.enabled {
                    mutateBaseline(key) { $0.linearScaling = nil }
                }
            }
            if let acceleration = settings.acceleration.effective {
                service.pointerAcceleration = acceleration
            } else if let original = baseline(key)?.pointerAcceleration {
                service.pointerAcceleration = original
                mutateBaseline(key) { $0.pointerAcceleration = nil }
            }
        }
    }

    private func restore(device: ManagedDevice) {
        guard let baseline = baseline(device.key) else { return }

        if let service = device.pointerService {
            if let resolution = baseline.pointerResolution { service.pointerResolution = resolution }
            if let linear = baseline.linearScaling { service.linearScalingEnabled = linear }
            if let acceleration = baseline.pointerAcceleration { service.pointerAcceleration = acceleration }
        }

        if let target = device.target, target.ping() {
            if let smartShift = baseline.smartShift {
                _ = target.setSmartShift(mode: smartShift.mode,
                                         autoDisengage: smartShift.autoDisengage,
                                         torque: smartShift.torque)
            }
            if let wheelMode = baseline.wheelMode {
                _ = target.setWheelMode(target: .native,
                                        resolution: wheelMode.resolution,
                                        inverted: wheelMode.inverted)
            }
            if let dpi = baseline.dpi { _ = target.setDPI(dpi) }
            if let rate = baseline.reportRate { _ = target.setReportRate(rate) }
            for (control, wasDiverted) in baseline.divertedControls {
                _ = target.setControlReporting(
                    control,
                    HIDPPControlReportingChange(diverted: wasDiverted, rawXY: false)
                )
            }
        }

        stateLock.lock()
        baselines.removeValue(forKey: device.key)
        stateLock.unlock()
    }

    // MARK: - Retry and confirmation

    private func scheduleRetry(
        device: ManagedDevice,
        configuration: DeviceConfiguration,
        globallyEnabled: Bool,
        message: String
    ) {
        stateLock.lock()
        let attempt = attemptCounts[device.key] ?? 0
        attemptCounts[device.key] = attempt + 1
        stateLock.unlock()

        guard attempt < Self.retryDelays.count else {
            os_log("giving up on %{public}@ after %{public}d attempts: %{public}@",
                   log: Self.log, type: .error, device.displayName, attempt, message)
            setStatus(.failed(message), for: device.key)
            return
        }

        let delay = Self.retryDelays[attempt]
        setStatus(.waitingForDevice, for: device.key)
        os_log("%{public}@ not ready (%{public}@); retrying in %{public}.0fs",
               log: Self.log, type: .info, device.displayName, message, delay)

        let item = DispatchWorkItem { [weak self] in
            self?.reconcile(device: device,
                            configuration: configuration,
                            globallyEnabled: globallyEnabled,
                            reason: "retry \(attempt + 1)")
        }
        stateLock.lock()
        pendingRetries[device.key] = item
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleConfirm(
        device: ManagedDevice,
        configuration: DeviceConfiguration,
        globallyEnabled: Bool
    ) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            os_log("confirming settings on %{public}@", log: Self.log, type: .info, device.displayName)
            _ = apply(device: device, configuration: configuration, globallyEnabled: globallyEnabled)
        }
        stateLock.lock()
        pendingRetries[device.key] = item
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + Self.confirmDelay, execute: item)
    }

    private func cancelRetry(for key: String) {
        stateLock.lock()
        pendingRetries.removeValue(forKey: key)?.cancel()
        stateLock.unlock()
    }

    // MARK: - Baseline bookkeeping

    private func baseline(_ key: String) -> Baseline? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return baselines[key]
    }

    private func hasBaseline(_ key: String) -> Bool {
        baseline(key) != nil
    }

    private func mutateBaseline(_ key: String, _ transform: (inout Baseline) -> Void) {
        stateLock.lock()
        var current = baselines[key] ?? Baseline()
        transform(&current)
        baselines[key] = current
        stateLock.unlock()
    }

    /// Records the pre-existing value the first time a setting is written.
    /// Later observations are ignored — by then the value on the device may
    /// already be ours.
    private func captureBaselineIfNeeded<T>(
        _ key: String,
        _ value: T?,
        _ path: WritableKeyPath<Baseline, T?>
    ) {
        guard let value else { return }
        stateLock.lock()
        var current = baselines[key] ?? Baseline()
        if current[keyPath: path] == nil {
            current[keyPath: path] = value
            baselines[key] = current
        }
        stateLock.unlock()
    }

    private func setStatus(_ status: Status, for key: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statuses[key] = status
        }
    }
}
