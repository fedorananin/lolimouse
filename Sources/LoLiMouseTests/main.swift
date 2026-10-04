// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import CoreGraphics
import Foundation
import HIDPP
import IOKitSPI
import LoLiCore

// MARK: - Settings

suite("Setting — the switch that makes everything optional") {
    test("a disabled setting has no effective value but keeps what was configured") {
        let setting = Setting<Int>.off(42)
        expectNil(setting.effective)
        expectEqual(setting.value, 42, "the value must survive being switched off")
    }

    test("an enabled setting exposes its value") {
        expectEqual(Setting<Int>.on(42).effective, 42)
    }

    test("a config file that omits `enabled` decodes as off") {
        let json = Data(#"{"value": 7}"#.utf8)
        guard let setting = try? JSONDecoder().decode(Setting<Int>.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        expectEqual(setting.enabled, false)
        expectEqual(setting.value, 7)
    }

    test("settings round-trip through JSON") {
        let original = Setting<Double>.on(1.5)
        guard let data = try? JSONEncoder().encode(original),
              let decoded = try? JSONDecoder().decode(Setting<Double>.self, from: data)
        else {
            expect(false, "round trip failed")
            return
        }
        expectEqual(decoded, original)
    }
}

// MARK: - Configuration

suite("Configuration") {
    test("a fresh configuration manages nothing at all") {
        // The premise of the whole app: out of the box it touches nothing.
        let configuration = DeviceConfiguration()
        expectEqual(configuration.managesAnything, false)
        expectEqual(configuration.hardware.managesAnything, false)
        expectEqual(configuration.pointer.managesAnything, false)
        expectEqual(configuration.scrolling.managesAnything, false)
        expectEqual(configuration.buttons.managesAnything, false)
    }

    test("no HID++ control is diverted until a button is configured") {
        var buttons = ButtonSettings()
        expectEqual(buttons.divertedControls.isEmpty, true)

        buttons.wheelModeButton.enabled = true
        expectEqual(buttons.divertedControls, [HIDPPControl.wheelModeButton])

        buttons.thumbButton.tap.enabled = true
        expect(buttons.divertedControls.isSuperset(of: HIDPPControl.gestureCapable),
               "configuring the thumb button must divert every gesture-capable control")
    }

    test("switching a button back off stops diverting it") {
        var buttons = ButtonSettings()
        buttons.wheelModeButton.enabled = true
        buttons.wheelModeButton.enabled = false
        expectEqual(buttons.divertedControls.isEmpty, true)
    }

    test("a full configuration round-trips through JSON") {
        var configuration = Configuration()
        configuration.update("unit:DEADBEEF") { device in
            device.displayName = "MX Master 3S"
            device.hardware.wheelRatchet = .on(WheelRatchetSetting(mode: .alwaysRatchet, threshold: 20))
            device.scrolling.vertical.distance = .on(.lines(3))
            device.buttons.thumbButton.gestures = .on([.up: .missionControl, .down: .showDesktop])
        }

        guard let data = try? JSONEncoder().encode(configuration),
              let decoded = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            expect(false, "round trip failed")
            return
        }
        expectEqual(decoded, configuration)
        expectEqual(decoded.device("unit:DEADBEEF").buttons.thumbButton.gestures.value[.up], .missionControl)
    }

    test("a config file from before the menu bar toggle still decodes") {
        // Root-level fields are filled in with defaults when absent, so adding
        // one must never send an old config.json to `.broken`.
        let json = Data(#"{"schemaVersion": 1, "devices": {}, "enabled": false}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(Configuration.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        expectEqual(decoded.enabled, false)
        expectEqual(decoded.showMenuBarIcon, true)
    }

    test("a device entry from before the menu bar battery checkbox still decodes") {
        // Same rule one level down: a new per-device field must default, not
        // reject the file.
        let json = Data(#"{"schemaVersion": 1, "devices": {"unit:1": {"displayName": "MX Master 3S"}}, "enabled": true}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(Configuration.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        expectEqual(decoded.device("unit:1").displayName, "MX Master 3S")
        expectEqual(decoded.device("unit:1").showBatteryInMenuBar, false)
    }

    test("the menu bar shows only opted-in devices that have reported a charge") {
        let mouse = HIDPPBattery(percentage: 60, charging: false)
        let keyboard = HIDPPBattery(percentage: 85, charging: true)
        let unknown = HIDPPBattery(percentage: nil, charging: false)

        expectEqual(MenuBarBattery.title(for: []), "")
        expectEqual(MenuBarBattery.title(for: [(shown: false, battery: mouse)]), "",
                    "nothing is shown until the user ticks a device")
        expectEqual(MenuBarBattery.title(for: [(shown: true, battery: mouse)]), "60%")
        expectEqual(MenuBarBattery.title(for: [(shown: true, battery: keyboard)]), "85% ⚡")
        expectEqual(MenuBarBattery.title(for: [(shown: true, battery: nil), (shown: true, battery: mouse)]), "60%",
                    "a device that has not answered yet must not blank out one that has")
        expectEqual(MenuBarBattery.title(for: [(shown: true, battery: unknown), (shown: true, battery: mouse)]), "60%")
        expectEqual(
            MenuBarBattery.title(for: [(shown: true, battery: keyboard), (shown: false, battery: unknown), (shown: true, battery: mouse)]),
            "85% ⚡ · 60%",
            "several devices keep their display order"
        )
    }

    test("a DPI announcement reads as a plain value with its unit") {
        expectEqual(MenuBarBattery.label(forDPI: 1200), "1200 DPI")
    }

    test("the status menu lists each device with whichever readings are known") {
        let battery = HIDPPBattery(percentage: 90, charging: false)
        let unknown = HIDPPBattery(percentage: nil, charging: false)
        expectEqual(MenuBarBattery.menuLabel(name: "MX Master 3S", battery: battery, dpi: 1200),
                    "MX Master 3S — 90%, 1200 DPI")
        expectEqual(MenuBarBattery.menuLabel(name: "MX Master 3S", battery: battery, dpi: nil),
                    "MX Master 3S — 90%")
        expectEqual(MenuBarBattery.menuLabel(name: "MX Master 3S", battery: unknown, dpi: 1200),
                    "MX Master 3S — 1200 DPI")
        expectEqual(MenuBarBattery.menuLabel(name: "Magic Mouse", battery: nil, dpi: nil), "Magic Mouse")
    }

    test("DPI presets cycle and wrap around") {
        let presets = DPIPresets(values: [800, 1600, 3200], activeIndex: 0)
        expectEqual(presets.active, 800)
        expectEqual(presets.next().active, 1600)
        expectEqual(presets.next().next().active, 3200)
        expectEqual(presets.next().next().next().active, 800, "cycling must wrap")
    }
}

// MARK: - Wheel ratchet

suite("Event fallback — a trackpad gesture must not disarm the mouse") {
    // The morning after finger taps went in, reverse scrolling stopped: the
    // trackpad's new config entry made it a second "configured" device, the
    // sole-device fallback went away, and every scroll event whose sender ID
    // the registry had not seen sailed through untouched.
    var mouse = DeviceConfiguration()
    mouse.scrolling.vertical.reverse = .on(true)
    var trackpad = DeviceConfiguration()
    trackpad.trackpad.threeFingerTap = .on(.mouseButton(2))

    test("finger-tap settings do not use the event tap") {
        expectEqual(trackpad.usesEventTap, false)
        expectEqual(mouse.usesEventTap, true)
        expectEqual(DeviceConfiguration().usesEventTap, false)
    }

    test("the mouse stays the sole fallback next to a trackpad with gestures") {
        let configuration = Configuration(devices: ["mouse": mouse, "pad": trackpad])
        expectEqual(configuration.soleEventTapDevice(among: ["mouse", "pad"]), "mouse")
    }

    test("two devices with scrolling settings leave no fallback") {
        let configuration = Configuration(devices: ["a": mouse, "b": mouse])
        expectNil(configuration.soleEventTapDevice(among: ["a", "b"]))
    }

    test("only attached devices are candidates") {
        let configuration = Configuration(devices: ["mouse": mouse, "other": mouse])
        expectEqual(configuration.soleEventTapDevice(among: ["mouse"]), "mouse")
        expectNil(configuration.soleEventTapDevice(among: []))
    }
}

suite("Application profiles — one app, its own wheel and buttons") {
    // The case that started it: macOS natural scrolling on, the mouse's
    // vertical reverse on in LoLiMouse, and IINA undoing natural scrolling a
    // second time. IINA needs the reverse *off*, and its thumbwheel reversed.
    var mouse = DeviceConfiguration()
    mouse.scrolling.vertical.reverse = .on(true)
    mouse.scrolling.vertical.distance = .on(.lines(3))
    var iina = AppProfile(name: "IINA")
    iina.override(.verticalReverse, from: mouse)
    iina.override(.horizontalReverse, from: mouse)
    mouse.apps["com.colliderli.iina"] = iina
    mouse.editProfile("com.colliderli.iina") {
        $0.scrolling.vertical.reverse.enabled = false
        $0.scrolling.horizontal.reverse = .on(true)
    }

    test("an overridden setting is replaced whole, switch included") {
        guard let effective = mouse.applicationConfigurations["com.colliderli.iina"] else {
            expect(false, "the profile is on and changes something, so it must apply")
            return
        }
        expectEqual(effective.scrolling.vertical.reverse.enabled, false,
                    "a profile must be able to switch a setting off")
        expectEqual(effective.scrolling.horizontal.reverse, .on(true))
    }

    test("everything not overridden follows the settings for all applications") {
        var changed = mouse
        changed.scrolling.vertical.distance = .on(.pixels(40))
        expectEqual(
            changed.applicationConfigurations["com.colliderli.iina"]?.scrolling.vertical.distance,
            .on(.pixels(40))
        )
    }

    test("the effective configuration carries no profiles of its own") {
        expectEqual(mouse.applicationConfigurations["com.colliderli.iina"]?.apps.isEmpty, true)
    }

    test("a profile that is switched off, or changes nothing, does not apply") {
        var off = mouse
        off.apps["com.colliderli.iina"]?.enabled = false
        expect(off.applicationConfigurations.isEmpty)

        var empty = DeviceConfiguration()
        empty.apps["com.apple.Safari"] = AppProfile(name: "Safari")
        expect(empty.applicationConfigurations.isEmpty)
        expectEqual(empty.managesAnything, false)
    }

    test("editing records only what changed") {
        var device = DeviceConfiguration()
        device.apps["app"] = AppProfile(name: "App")
        device.editProfile("app") { $0.scrolling.horizontal.speed = .on(2) }
        expectEqual(device.apps["app"]?.overridden, [.horizontalSpeed])

        // The flick threshold is not a per-application setting; an edit to it
        // through a profile must not leak into anything.
        device.editProfile("app") { $0.buttons.thumbButton.threshold = 150 }
        expectEqual(device.apps["app"]?.overridden, [.horizontalSpeed])
        expectEqual(device.applicationConfigurations["app"]?.buttons.thumbButton.threshold, 60)
    }

    test("editing a device without that profile changes nothing") {
        var device = DeviceConfiguration()
        device.editProfile("missing") { $0.scrolling.vertical.reverse = .on(true) }
        expectEqual(device, DeviceConfiguration())
    }

    test("inheriting again drops the override") {
        var profile = iina
        profile.inherit(.horizontalReverse)
        expectEqual(profile.overridden, [.verticalReverse])
    }

    test("a diverted button can be changed per app only if it is taken over for all") {
        var device = DeviceConfiguration()
        var profile = AppProfile(name: "App")
        profile.override(.wheelModeButton, from: DeviceConfiguration(buttons: ButtonSettings(
            wheelModeButton: .on(.missionControl)
        )))
        profile.override(.thumbButtonTap, from: DeviceConfiguration(buttons: ButtonSettings(
            thumbButton: GestureButtonSettings(tap: .on(.showDesktop))
        )))
        device.apps["app"] = profile
        let untouched = device.applying(profile)
        expectEqual(untouched.buttons.wheelModeButton.enabled, false,
                    "the button is the firmware's everywhere else, so no profile may divert it")
        expectEqual(untouched.buttons.thumbButton.tap.enabled, false)
        expectEqual(untouched.buttons.divertedControls, [])

        device.buttons.wheelModeButton = .on(.cycleDPIPresets)
        device.buttons.thumbButton.tap = .on(.missionControl)
        let allowed = device.applying(profile)
        expectEqual(allowed.buttons.wheelModeButton, .on(.missionControl))
        expectEqual(allowed.buttons.thumbButton.tap, .on(.showDesktop))
    }

    test("a disallowed edit is not recorded") {
        var device = DeviceConfiguration()
        device.apps["app"] = AppProfile(name: "App")
        device.editProfile("app") { $0.buttons.wheelModeButton = .on(.missionControl) }
        expectEqual(device.apps["app"]?.overridden, [])
    }

    test("a profile brings in the event tap even when the device alone would not") {
        var device = DeviceConfiguration()
        expectEqual(device.usesEventTap, false)
        var profile = AppProfile(name: "App")
        var reversed = DeviceConfiguration()
        reversed.scrolling.vertical.reverse = .on(true)
        profile.override(.verticalReverse, from: reversed)
        device.apps["app"] = profile
        expectEqual(device.usesEventTap, true)

        device.apps["app"]?.enabled = false
        expectEqual(device.usesEventTap, false)
    }

    test("pinch zoom in a profile asks for flagsChanged") {
        var device = DeviceConfiguration()
        var pinch = DeviceConfiguration()
        pinch.scrolling.modifiers = .on([.command: .pinchZoom])
        var profile = AppProfile(name: "App")
        profile.override(.scrollModifiers, from: pinch)
        expectEqual(device.wantsFlagsChanged, false)
        device.apps["app"] = profile
        expectEqual(device.wantsFlagsChanged, true)
    }

    test("the file names only what the profile changes") {
        guard let data = try? JSONEncoder().encode(iina),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = object["settings"] as? [String: Any]
        else {
            expect(false, "encoding failed")
            return
        }
        expectEqual(Set(settings.keys), ["scrolling.vertical.reverse", "scrolling.horizontal.reverse"])
        expectEqual(object["name"] as? String, "IINA")
    }

    test("profiles round-trip through JSON") {
        guard let data = try? JSONEncoder().encode(mouse),
              let decoded = try? JSONDecoder().decode(DeviceConfiguration.self, from: data)
        else {
            expect(false, "round trip failed")
            return
        }
        expectEqual(decoded, mouse)
        expectEqual(decoded.applicationConfigurations, mouse.applicationConfigurations)
    }

    test("a setting a newer version knows about is skipped, not fatal") {
        let json = Data(#"""
        {"name": "App", "settings": {
            "scrolling.vertical.reverse": {"enabled": true, "value": true},
            "scrolling.somethingNew": {"enabled": true, "value": 1}
        }}
        """#.utf8)
        guard let profile = try? JSONDecoder().decode(AppProfile.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        expectEqual(profile.overridden, [.verticalReverse])
        expectEqual(profile.enabled, true, "a profile without the key is on")
    }

    test("a device written before profiles existed has none") {
        let json = Data(#"{"displayName": "MX Master 3S", "showBatteryInMenuBar": true}"#.utf8)
        expectEqual((try? JSONDecoder().decode(DeviceConfiguration.self, from: json))?.apps.isEmpty, true)
    }

    test("the values of settings not overridden do not make profiles differ") {
        var a = AppProfile(name: "App")
        a.override(.verticalSpeed, from: DeviceConfiguration())
        a.inherit(.verticalSpeed)
        expectEqual(a, AppProfile(name: "App"))
    }

    test("a key path built by appending finds the same setting as a literal one") {
        let axis: WritableKeyPath<DeviceConfiguration, AxisScrolling> = \.scrolling.horizontal
        expectEqual(OverridableSetting(path: axis.appending(path: \.reverse)), .horizontalReverse)
        expectEqual(OverridableSetting(path: \DeviceConfiguration.trackpad.fourFingerTap), .fourFingerTap)
        expectNil(OverridableSetting(path: \DeviceConfiguration.hardware.dpi),
                  "hardware settings are never per application")
    }
}

suite("Application under the pointer — whose window the wheel lands in") {
    typealias Window = ApplicationUnderPointer.Window
    let point = CGPoint(x: 100, y: 100)
    let covering = CGRect(x: 0, y: 0, width: 500, height: 500)

    test("the frontmost window containing the point wins") {
        let windows = [
            Window(ownerPID: 1, bounds: CGRect(x: 300, y: 300, width: 50, height: 50)),
            Window(ownerPID: 2, bounds: covering),
            Window(ownerPID: 3, bounds: covering),
        ]
        expectEqual(ApplicationUnderPointer.owner(at: point, in: windows), 2)
    }

    test("the menu bar and the Dock belong to nobody's profile") {
        let windows = [
            Window(ownerPID: 1, bounds: covering, layer: 25),
            Window(ownerPID: 2, bounds: covering, layer: 20),
            Window(ownerPID: 3, bounds: covering),
        ]
        expectEqual(ApplicationUnderPointer.owner(at: point, in: windows), 3)
    }

    test("a floating window, like IINA's picture in picture, counts") {
        let windows = [
            Window(ownerPID: 1, bounds: covering, layer: 3),
            Window(ownerPID: 2, bounds: covering),
        ]
        expectEqual(ApplicationUnderPointer.owner(at: point, in: windows), 1)
    }

    test("an invisible window is looked through") {
        let windows = [
            Window(ownerPID: 1, bounds: covering, alpha: 0),
            Window(ownerPID: 2, bounds: covering),
        ]
        expectEqual(ApplicationUnderPointer.owner(at: point, in: windows), 2)
    }

    test("over the desktop there is no application") {
        expectNil(ApplicationUnderPointer.owner(at: point, in: []))
    }
}

suite("Wheel ratchet — the setting Logitech does not offer") {
    test("always-ratchet sends the permanent sentinel") {
        let setting = WheelRatchetSetting(mode: .alwaysRatchet, threshold: 16)
        expectEqual(setting.hidppMode, .ratchet)
        expectEqual(setting.hidppAutoDisengage, HIDPPSmartShift.permanentRatchet)
    }

    test("SmartShift mode sends its threshold") {
        let setting = WheelRatchetSetting(mode: .smartShift, threshold: 24)
        expectEqual(setting.hidppMode, .ratchet)
        expectEqual(setting.hidppAutoDisengage, 24)
    }

    test("a threshold below the usable floor is clamped") {
        // Below the floor the wheel releases during ordinary scrolling, which
        // simply reads as the wheel being broken.
        let setting = WheelRatchetSetting(mode: .smartShift, threshold: 1)
        expectEqual(setting.hidppAutoDisengage, UInt8(WheelRatchetSetting.minimumThreshold))
    }

    test("free spin sends free-spin mode") {
        expectEqual(WheelRatchetSetting(mode: .freeSpin).hidppMode, .freespin)
    }
}

// MARK: - Detent accumulator

suite("Detent accumulator — folding a high-resolution wheel back into clicks") {
    test("a low-resolution wheel passes straight through") {
        var accumulator = DetentAccumulator()
        expectEqual(accumulator.consume(units: 1, multiplier: 1, now: 0), 1)
        expectEqual(accumulator.consume(units: -3, multiplier: 1, now: 0.1), -3)
    }

    test("a partial click emits nothing") {
        var accumulator = DetentAccumulator()
        for step in 0 ..< 3 {
            expectNil(accumulator.consume(units: 1, multiplier: 8, now: Double(step) * 0.01))
        }
    }

    test("eight increments produce exactly one click") {
        var accumulator = DetentAccumulator()
        var total = 0
        for step in 0 ..< 8 {
            total += accumulator.consume(units: 1, multiplier: 8, now: Double(step) * 0.01) ?? 0
        }
        expectEqual(total, 1, "one physical click must produce one scroll event")
    }

    test("ten clicks' worth of increments produce ten clicks") {
        var accumulator = DetentAccumulator()
        var total = 0
        for step in 0 ..< 80 {
            total += accumulator.consume(units: 1, multiplier: 8, now: Double(step) * 0.01) ?? 0
        }
        expectEqual(total, 10)
    }

    test("reversing direction discards the leftover fraction") {
        var accumulator = DetentAccumulator()
        _ = accumulator.consume(units: 3, multiplier: 8, now: 0)
        expectNil(accumulator.consume(units: -3, multiplier: 8, now: 0.01),
                  "the downward remainder must not shorten the first upward click")
        expectEqual(accumulator.consume(units: -2, multiplier: 8, now: 0.02), -1)
    }

    test("an idle gap discards the leftover fraction") {
        var accumulator = DetentAccumulator()
        _ = accumulator.consume(units: 3, multiplier: 8, now: 0)
        expectNil(accumulator.consume(units: 3, multiplier: 8, now: 60))
    }

    test("no movement emits nothing") {
        var accumulator = DetentAccumulator()
        expectNil(accumulator.consume(units: 0, multiplier: 8, now: 0))
    }
}

// MARK: - Scroll processing

func scrollEvent(deltaY: Int32) -> CGEvent {
    CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
    )!
}

suite("Scroll processing") {
    test("unmanaged settings leave the event untouched") {
        let processor = ScrollProcessor()
        guard let result = processor.process(scrollEvent(deltaY: 3)) else {
            expect(false, "the event was swallowed")
            return
        }
        expectEqual(ScrollWheelEvent(result).deltaY, 3)
    }

    test("reverse flips the axis") {
        var settings = ScrollingSettings()
        settings.vertical.reverse = .on(true)
        let processor = ScrollProcessor(settings: settings)

        guard let result = processor.process(scrollEvent(deltaY: 3)) else {
            expect(false, "the event was swallowed")
            return
        }
        expectEqual(ScrollWheelEvent(result).deltaY, -3)
    }

    test("horizontal settings do not touch the vertical axis") {
        var settings = ScrollingSettings()
        settings.horizontal.reverse = .on(true)
        let processor = ScrollProcessor(settings: settings)

        guard let result = processor.process(scrollEvent(deltaY: 3)) else {
            expect(false, "the event was swallowed")
            return
        }
        expectEqual(ScrollWheelEvent(result).deltaY, 3)
    }

    test("our own synthetic events are never transformed twice") {
        var settings = ScrollingSettings()
        settings.vertical.reverse = .on(true)
        let processor = ScrollProcessor(settings: settings)

        let event = scrollEvent(deltaY: 3)
        event.markSynthetic()
        guard let result = processor.process(event) else {
            expect(false, "the event was swallowed")
            return
        }
        expectEqual(ScrollWheelEvent(result).deltaY, 3)
    }

    test("a fixed line distance makes every click equal") {
        var settings = ScrollingSettings()
        settings.vertical.distance = .on(.lines(5))
        let processor = ScrollProcessor(settings: settings)

        for _ in 0 ..< 3 {
            guard let result = processor.process(scrollEvent(deltaY: 1)) else {
                expect(false, "the event was swallowed")
                return
            }
            expectEqual(ScrollWheelEvent(result).deltaY, 5)
        }
    }

    test("the IOHIDEvent scroll fields are X-first, like every other axis") {
        // These constants are transcribed from IOHIDEventTypes.h by hand, and
        // swapping them once made the thumbwheel scroll the page vertically:
        // the pipeline read sideways movement through the "Y" field, quantised
        // it, and wrote the result onto the vertical axis.
        expectEqual(kLoLiIOHIDEventFieldScrollX, (6 << 16) | 0)
        expectEqual(kLoLiIOHIDEventFieldScrollY, (6 << 16) | 1)
    }

    test("normalisation never quantises the thumbwheel") {
        // The thumbwheel is free-spinning: it sends fine fractional increments
        // and has no detents to fold them back into. Running it through the
        // vertical wheel's multiplier used to swallow those increments and turn
        // smooth horizontal panning into stepped scrolling.
        var settings = ScrollingSettings()
        settings.normalizeHighResolutionWheel = .on(true)
        let processor = ScrollProcessor(settings: settings, highResolutionMultiplier: 8)

        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 1,
            wheel3: 0
        )!
        guard let result = processor.process(event) else {
            expect(false, "a fine thumbwheel increment was swallowed")
            return
        }
        expectClose(ScrollWheelEvent(result).pointDeltaX, 1, accuracy: 0.01,
                    "the increment must pass through untouched")
    }

    test("the speed multiplier scales every representation together") {
        var settings = ScrollingSettings()
        settings.vertical.speed = .on(2)
        let processor = ScrollProcessor(settings: settings)

        // CoreGraphics derives the pixel field from the line count using its own
        // timing-dependent acceleration, so the reference has to come from the
        // very event being processed rather than a second identical one.
        let event = scrollEvent(deltaY: 2)
        let before = ScrollWheelEvent(event).pointDeltaY

        guard let result = processor.process(event) else {
            expect(false, "the event was swallowed")
            return
        }
        let view = ScrollWheelEvent(result)
        expectEqual(view.deltaY, 4)
        expectClose(view.pointDeltaY, before * 2, accuracy: 0.01,
                    "the pixel field must scale with the click field")
    }
}

// MARK: - Modifier keys

func modifierScrollEvent(deltaY: Int32, flags: CGEventFlags) -> CGEvent {
    let event = scrollEvent(deltaY: deltaY)
    event.flags = flags
    return event
}

suite("Modifier keys — what the wheel does while a modifier is held") {
    test("an unconfigured modifier leaves the event and its flags alone") {
        let transformer = ModifierKeyTransformer(actions: [.command: .zoom])
        let event = modifierScrollEvent(deltaY: 1, flags: .maskShift)
        guard let result = transformer.process(event, type: .scrollWheel) else {
            expect(false, "the event was swallowed")
            return
        }
        expect(result.flags.contains(.maskShift), "an unhandled flag must survive")
        expectEqual(ScrollWheelEvent(result).deltaY, 1)
    }

    test("ignore strips the modifier so the app sees plain scrolling") {
        let transformer = ModifierKeyTransformer(actions: [.command: .ignore])
        let event = modifierScrollEvent(deltaY: 2, flags: .maskCommand)
        guard let result = transformer.process(event, type: .scrollWheel) else {
            expect(false, "the event was swallowed")
            return
        }
        expect(!result.flags.contains(.maskCommand), "the handled flag must be removed")
        expectEqual(ScrollWheelEvent(result).deltaY, 2, "the movement must be untouched")
    }

    test("preventDefault swallows the event") {
        let transformer = ModifierKeyTransformer(actions: [.shift: .preventDefault])
        expectNil(transformer.process(modifierScrollEvent(deltaY: 1, flags: .maskShift),
                                      type: .scrollWheel))
    }

    test("alterOrientation swaps the axes") {
        let transformer = ModifierKeyTransformer(actions: [.option: .alterOrientation])
        let event = modifierScrollEvent(deltaY: 3, flags: .maskAlternate)
        guard let result = transformer.process(event, type: .scrollWheel) else {
            expect(false, "the event was swallowed")
            return
        }
        let view = ScrollWheelEvent(result)
        expectEqual(view.deltaY, 0)
        expectEqual(view.deltaX, 3)
    }

    test("changeSpeed scales the movement and strips the flag") {
        let transformer = ModifierKeyTransformer(actions: [.control: .changeSpeed(3)])
        let event = modifierScrollEvent(deltaY: 2, flags: .maskControl)
        guard let result = transformer.process(event, type: .scrollWheel) else {
            expect(false, "the event was swallowed")
            return
        }
        expectEqual(ScrollWheelEvent(result).deltaY, 6)
        expect(!result.flags.contains(.maskControl))
    }

    test("zoom swallows the scroll and posts one shortcut in the scroll direction") {
        var posted: [Int] = []
        let transformer = ModifierKeyTransformer(
            actions: [.command: .zoom],
            postZoom: { posted.append($0) },
            postPinch: { _, _ in expect(false, "zoom must not post gestures") }
        )
        expectNil(transformer.process(modifierScrollEvent(deltaY: 1, flags: .maskCommand),
                                      type: .scrollWheel))
        expectNil(transformer.process(modifierScrollEvent(deltaY: -1, flags: .maskCommand),
                                      type: .scrollWheel))
        expectEqual(posted, [1, -1])
    }

    test("zoomReversed flips the direction") {
        var posted: [Int] = []
        let transformer = ModifierKeyTransformer(
            actions: [.command: .zoomReversed],
            postZoom: { posted.append($0) },
            postPinch: { _, _ in }
        )
        _ = transformer.process(modifierScrollEvent(deltaY: 1, flags: .maskCommand),
                                type: .scrollWheel)
        expectEqual(posted, [-1])
    }

    test("a pinch begins on the first scroll and ends when the flags change") {
        var phases: [ModifierKeyTransformer.PinchPhase] = []
        let transformer = ModifierKeyTransformer(
            actions: [.command: .pinchZoom],
            postZoom: { _ in expect(false, "pinch must not post keystrokes") },
            postPinch: { phase, _ in phases.append(phase) }
        )

        expectNil(transformer.process(modifierScrollEvent(deltaY: 1, flags: .maskCommand),
                                      type: .scrollWheel))
        expectNil(transformer.process(modifierScrollEvent(deltaY: 1, flags: .maskCommand),
                                      type: .scrollWheel),
                  "scrolling during a pinch must keep feeding the gesture")

        guard let flagsChanged = CGEvent(source: nil) else {
            expect(false, "could not create an event")
            return
        }
        _ = transformer.process(flagsChanged, type: .flagsChanged)

        expectEqual(phases.first == .began, true, "the gesture must begin exactly once")
        expectEqual(phases.last == .ended, true, "releasing the modifier must end the gesture")
        expectEqual(phases.filter { $0 == .began }.count, 1)
        expectEqual(phases.filter { $0 == .ended }.count, 1)
    }

    test("deactivating mid-pinch ends the gesture") {
        var phases: [ModifierKeyTransformer.PinchPhase] = []
        let transformer = ModifierKeyTransformer(
            actions: [.command: .pinchZoom],
            postZoom: { _ in },
            postPinch: { phase, _ in phases.append(phase) }
        )
        _ = transformer.process(modifierScrollEvent(deltaY: 1, flags: .maskCommand),
                                type: .scrollWheel)
        transformer.deactivate()
        expectEqual(phases.last == .ended, true,
                    "tearing the tap down must never strand a began gesture")
        transformer.deactivate()
        expectEqual(phases.filter { $0 == .ended }.count, 1, "a second deactivate must be a no-op")
    }

    test("two held modifiers each get their action") {
        var posted: [Int] = []
        let transformer = ModifierKeyTransformer(
            actions: [.shift: .changeSpeed(2), .command: .zoom],
            postZoom: { posted.append($0) },
            postPinch: { _, _ in }
        )
        // ⌘⇧+scroll: shift doubles the movement, command turns it into zoom.
        expectNil(transformer.process(
            modifierScrollEvent(deltaY: 1, flags: [.maskCommand, .maskShift]),
            type: .scrollWheel
        ))
        expectEqual(posted, [1])
    }

    test("modifier actions round-trip through JSON") {
        var settings = ScrollingSettings()
        settings.modifiers = .on([.command: .pinchZoom, .shift: .changeSpeed(2.5)])
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(ScrollingSettings.self, from: data)
        else {
            expect(false, "round trip failed")
            return
        }
        expectEqual(decoded, settings)
    }

    test("only pinch actions ask for flagsChanged") {
        var settings = ScrollingSettings()
        expectEqual(settings.wantsFlagsChanged, false)

        settings.modifiers = .on([.command: .zoom])
        expectEqual(settings.wantsFlagsChanged, false,
                    "keystroke zoom must not widen the event tap")

        settings.modifiers = .on([.command: .pinchZoom])
        expectEqual(settings.wantsFlagsChanged, true)

        settings.modifiers.enabled = false
        expectEqual(settings.wantsFlagsChanged, false,
                    "a switched-off setting must not widen the event tap")
    }

    test("configuring modifiers switches the scrolling pipeline on") {
        var settings = ScrollingSettings()
        expectEqual(settings.managesAnything, false)
        settings.modifiers.enabled = true
        expectEqual(settings.managesAnything, true)
    }
}

// MARK: - Button mappings with modifiers

suite("Button mappings — modifiers make one button several") {
    let plain = ButtonMapping(button: 3, action: .back)
    let withCommand = ButtonMapping(button: 3, modifiers: [.command], action: .missionControl)
    let withBoth = ButtonMapping(button: 3, modifiers: [.command, .shift], action: .showDesktop)

    test("with no modifiers held, the plain mapping fires") {
        let best = ButtonMapping.bestMatch(in: [plain, withCommand], button: 3, held: [])
        expectEqual(best?.action, .back)
    }

    test("the most specific matching mapping wins") {
        let mappings = [plain, withCommand, withBoth]
        expectEqual(ButtonMapping.bestMatch(in: mappings, button: 3, held: [.command])?.action,
                    .missionControl)
        expectEqual(ButtonMapping.bestMatch(in: mappings, button: 3, held: [.command, .shift])?.action,
                    .showDesktop)
    }

    test("a mapping never fires without its required modifiers") {
        expectNil(ButtonMapping.bestMatch(in: [withCommand], button: 3, held: [.shift]))
        expectNil(ButtonMapping.bestMatch(in: [withCommand], button: 3, held: []))
    }

    test("extra held modifiers do not disqualify a mapping") {
        // ⌥ held on top of ⌘ still means "⌘ is held"; requiring an exact match
        // would make mappings feel randomly unreliable.
        expectEqual(ButtonMapping.bestMatch(in: [withCommand], button: 3,
                                            held: [.command, .option])?.action,
                    .missionControl)
    }

    test("the wrong button never matches") {
        expectNil(ButtonMapping.bestMatch(in: [plain], button: 4, held: []))
    }

    test("a pre-modifier config file still decodes") {
        let json = Data("""
        {"id": "00000000-0000-0000-0000-000000000000", "button": 3,
         "action": {"back": {}}}
        """.utf8)
        guard let mapping = try? JSONDecoder().decode(ButtonMapping.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        expectEqual(mapping.modifiers, [])
    }
}

// MARK: - Media actions

suite("Media actions") {
    test("the system-key codes match IOKit's ev_keymap.h") {
        // These are transcribed by hand; a wrong one silently presses the
        // wrong media key.
        expectEqual(ActionRunner.SystemKey.soundUp.rawValue, 0)
        expectEqual(ActionRunner.SystemKey.soundDown.rawValue, 1)
        expectEqual(ActionRunner.SystemKey.brightnessUp.rawValue, 2)
        expectEqual(ActionRunner.SystemKey.brightnessDown.rawValue, 3)
        expectEqual(ActionRunner.SystemKey.mute.rawValue, 7)
        expectEqual(ActionRunner.SystemKey.play.rawValue, 16)
        expectEqual(ActionRunner.SystemKey.next.rawValue, 17)
        expectEqual(ActionRunner.SystemKey.previous.rawValue, 18)
    }

    test("media actions round-trip through JSON") {
        let mapping = ButtonMapping(button: 4, modifiers: [.option], action: .volumeUp)
        guard let data = try? JSONEncoder().encode(mapping),
              let decoded = try? JSONDecoder().decode(ButtonMapping.self, from: data)
        else {
            expect(false, "round trip failed")
            return
        }
        expectEqual(decoded.action, .volumeUp)
        expectEqual(decoded.modifiers, [.option])
    }
}

// MARK: - Event thread

suite("Event thread") {
    // This exists because a null CoreFoundation context once got the run loop
    // trapped on start, and the only thing that noticed was a machine that had
    // to be restarted. Anything that runs on a real thread gets exercised here.
    test("starts, runs work on its own thread, and stops") {
        let thread = EventThread.shared
        thread.start()

        let ranOnEventThread = thread.perform { EventThread.shared.isCurrent }
        expectEqual(ranOnEventThread, true, "work must run on the event thread")

        let doubled = thread.perform { 21 * 2 }
        expectEqual(doubled, 42, "the result must come back to the caller")

        thread.stop()
    }

    test("starting twice is harmless") {
        let thread = EventThread.shared
        thread.start()
        thread.start()
        expectEqual(thread.perform { 1 }, 1)
        thread.stop()
    }
}

// MARK: - Three-finger tap

suite("Finger taps — only a quick, still touch with exactly N fingers counts") {
    // Frames as MultitouchSupport delivers them: finger count and centroid.
    func feed(_ detector: inout FingerTapDetector, _ frames: [(Int, Double, Double, Double)]) -> Int {
        var taps = 0
        for (count, x, y, t) in frames {
            let centroid: (x: Double, y: Double)? = count > 0 ? (x, y) : nil
            if detector.process(fingerCount: count, centroid: centroid, timestamp: t) { taps += 1 }
        }
        return taps
    }

    test("three fingers down and up quickly is a tap") {
        var detector = FingerTapDetector(fingers: 3)
        let taps = feed(&detector, [(1, 0.5, 0.5, 0.00), (3, 0.5, 0.5, 0.02), (3, 0.5, 0.5, 0.10),
                                    (2, 0.5, 0.5, 0.14), (0, 0, 0, 0.16)])
        expectEqual(taps, 1)
    }

    test("the tap fires on the frame the last finger lifts, never earlier") {
        var detector = FingerTapDetector(fingers: 3)
        expectEqual(detector.process(fingerCount: 3, centroid: (0.5, 0.5), timestamp: 0), false)
        expectEqual(detector.process(fingerCount: 3, centroid: (0.5, 0.5), timestamp: 0.05), false)
        expectEqual(detector.process(fingerCount: 0, centroid: nil, timestamp: 0.1), true)
    }

    test("two or four fingers are not a tap") {
        var detector = FingerTapDetector(fingers: 3)
        expectEqual(feed(&detector, [(2, 0.5, 0.5, 0), (0, 0, 0, 0.1)]), 0, "two fingers")
        expectEqual(feed(&detector, [(3, 0.5, 0.5, 0), (4, 0.5, 0.5, 0.05), (0, 0, 0, 0.1)]), 0,
                    "four fingers at the peak — a four-finger gesture, not a tap")
    }

    test("a three-finger swipe is left to macOS") {
        var detector = FingerTapDetector(fingers: 3)
        let taps = feed(&detector, [(3, 0.2, 0.5, 0), (3, 0.4, 0.5, 0.05), (3, 0.6, 0.5, 0.1), (0, 0, 0, 0.15)])
        expectEqual(taps, 0)
    }

    test("a long press is not a tap") {
        var detector = FingerTapDetector(fingers: 3)
        let taps = feed(&detector, [(3, 0.5, 0.5, 0), (3, 0.5, 0.5, 0.5), (0, 0, 0, 1.0)])
        expectEqual(taps, 0)
    }

    test("the centroid shift while fingers land does not count as movement") {
        // With one finger the centroid is that finger; with three it is their
        // middle. That jump must not be mistaken for a swipe.
        var detector = FingerTapDetector(fingers: 3)
        let taps = feed(&detector, [(1, 0.2, 0.5, 0), (2, 0.35, 0.5, 0.01), (3, 0.5, 0.5, 0.02),
                                    (3, 0.5, 0.5, 0.08), (1, 0.8, 0.5, 0.1), (0, 0, 0, 0.12)])
        expectEqual(taps, 1)
    }

    test("a four-finger detector accepts four and rejects three") {
        var detector = FingerTapDetector(fingers: 4)
        expectEqual(feed(&detector, [(3, 0.5, 0.5, 0), (4, 0.5, 0.5, 0.03), (0, 0, 0, 0.1)]), 1)
        expectEqual(feed(&detector, [(3, 0.5, 0.5, 1), (0, 0, 0, 1.1)]), 0)
    }

    test("three- and four-finger detectors watching the same frames never both fire") {
        var three = FingerTapDetector(fingers: 3)
        var four = FingerTapDetector(fingers: 4)
        let frames: [(Int, Double, Double, Double)] = [(3, 0.5, 0.5, 0), (4, 0.5, 0.5, 0.03), (0, 0, 0, 0.1)]
        expectEqual(feed(&three, frames) + feed(&four, frames), 1)
    }

    test("consecutive taps each fire once") {
        var detector = FingerTapDetector(fingers: 3)
        let one: [(Int, Double, Double, Double)] = [(3, 0.5, 0.5, 0), (0, 0, 0, 0.1)]
        let two: [(Int, Double, Double, Double)] = [(3, 0.5, 0.5, 1), (0, 0, 0, 1.1)]
        expectEqual(feed(&detector, one + two), 2)
    }

    test("the trackpad setting is off by default and decodes when absent") {
        let json = Data(#"{"schemaVersion": 1, "devices": {"usb:1:2": {"displayName": "Trackpad"}}, "enabled": true}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(Configuration.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        let trackpad = decoded.device("usb:1:2").trackpad
        expectEqual(trackpad.threeFingerTap.enabled, false)
        expectEqual(trackpad.threeFingerTap.value, .mouseButton(2), "middle click is the default action")
        expectEqual(trackpad.fourFingerTap.enabled, false)
        expectEqual(trackpad.tap(fingers: 4)?.value, .missionControl)
        expectNil(trackpad.tap(fingers: 5))
        expectEqual(decoded.device("usb:1:2").managesAnything, false)
    }
}

// MARK: - Finger swipes

suite("Finger swipes — every finger moving the same way, once per touch") {
    typealias Contact = FingerSwipeDetector.Contact
    typealias Swipe = FingerSwipeDetector.Swipe

    func detector() -> FingerSwipeDetector { FingerSwipeDetector(fingerCounts: [3, 4]) }

    /// Fingers side by side, all moved by the same offset from where they
    /// landed. `y` grows away from the user, as MultitouchSupport reports it.
    func hand(_ fingers: Int, dx: Double = 0, dy: Double = 0) -> [Contact] {
        (0 ..< fingers).map { Contact(id: $0, x: 0.3 + 0.1 * Double($0) + dx, y: 0.5 + dy) }
    }

    /// The hand travelling `dx`, `dy` in even steps.
    func glide(_ fingers: Int, dx: Double = 0, dy: Double = 0, steps: Int = 10) -> [[Contact]] {
        (0 ... steps).map { step in
            let part = Double(step) / Double(steps)
            return hand(fingers, dx: dx * part, dy: dy * part)
        }
    }

    /// Feeds frames 10 ms apart and returns every swipe reported.
    func feed(_ detector: inout FingerSwipeDetector, _ frames: [[Contact]], from start: Double = 0) -> [Swipe] {
        var swipes: [Swipe] = []
        for (index, contacts) in frames.enumerated() {
            if let swipe = detector.process(contacts: contacts, timestamp: start + Double(index) * 0.01) {
                swipes.append(swipe)
            }
        }
        return swipes
    }

    test("three fingers moving down together is a three-finger swipe down") {
        var detector = detector()
        expectEqual(feed(&detector, glide(3, dy: -0.3) + [[]]), [Swipe(fingers: 3, direction: .down)])
    }

    test("four fingers are told apart from three") {
        var detector = detector()
        expectEqual(feed(&detector, glide(4, dy: -0.3) + [[]]), [Swipe(fingers: 4, direction: .down)])
    }

    test("each direction is recognised") {
        var detector = detector()
        expectEqual(feed(&detector, glide(3, dy: 0.3) + [[]]).map(\.direction), [.up])
        expectEqual(feed(&detector, glide(3, dx: -0.2) + [[]], from: 1).map(\.direction), [.left])
        expectEqual(feed(&detector, glide(3, dx: 0.2) + [[]], from: 2).map(\.direction), [.right])
    }

    test("the swipe fires while the fingers are still down, and only once") {
        var detector = detector()
        expectEqual(feed(&detector, glide(3, dy: -0.4, steps: 20)).count, 1, "no lift needed")
        expectEqual(feed(&detector, glide(3, dy: 0.4, steps: 20), from: 0.3).count, 0,
                    "swiping back without lifting is the same touch")
        expectEqual(feed(&detector, [[]] + glide(3, dy: -0.3), from: 1).count, 1, "a new touch swipes again")
    }

    test("two fingers scrolling beside a resting thumb is not a swipe") {
        // The mean of the three contacts moves two thirds as far as the
        // scroll does — plenty for the threshold. Only the thumb gives it away.
        var detector = detector()
        let frames: [[Contact]] = (0 ... 10).map { step in
            let dy = -0.4 * Double(step) / 10
            return [
                Contact(id: 0, x: 0.4, y: 0.7 + dy),
                Contact(id: 1, x: 0.5, y: 0.7 + dy),
                Contact(id: 2, x: 0.6, y: 0.1),
            ]
        }
        expectEqual(feed(&detector, frames + [[]]), [])
    }

    test("a fast four-finger swipe whose last finger lands late is not a three-finger one") {
        var detector = detector()
        var swipes: [Swipe] = []
        func frame(_ time: Double, _ contacts: [Contact]) {
            if let swipe = detector.process(contacts: contacts, timestamp: time) { swipes.append(swipe) }
        }
        // Three fingers arrive already moving and cover the whole threshold
        // in 20 ms, before the fourth is down.
        frame(0.000, hand(3))
        frame(0.010, hand(3, dy: -0.10))
        frame(0.020, hand(3, dy: -0.20))
        frame(0.030, hand(4, dy: -0.20))
        frame(0.050, hand(4, dy: -0.30))
        frame(0.080, hand(4, dy: -0.40))
        frame(0.100, hand(4, dy: -0.45))
        frame(0.120, [])
        expectEqual(swipes, [Swipe(fingers: 4, direction: .down)])
    }

    test("a hand lifting off finger by finger does not become a smaller swipe") {
        var detector = detector()
        // Four fingers rest, one lifts, the other three slide away.
        let frames = [hand(4), hand(4), hand(4)] + glide(3, dy: -0.3) + [[]]
        expectEqual(feed(&detector, frames), [])
    }

    test("fingers creeping slowly are not a swipe") {
        var detector = detector()
        // The whole threshold twice over, but spread across three seconds.
        expectEqual(feed(&detector, glide(3, dy: -0.3, steps: 300) + [[]]), [])
    }

    test("fingers that rest first and swipe afterwards still count") {
        var detector = detector()
        let resting = Array(repeating: hand(3), count: 100)
        expectEqual(feed(&detector, resting + glide(3, dy: -0.3) + [[]]).map(\.direction), [.down])
    }

    test("a diagonal is nobody's swipe") {
        var detector = detector()
        // 0.2 of the width is 0.3 of the height on a 3:2 surface.
        expectEqual(feed(&detector, glide(3, dx: 0.2, dy: -0.3) + [[]]), [])
    }

    test("the same hand movement counts the same across as up and down") {
        var across = detector()
        expectEqual(feed(&across, glide(3, dx: 0.11) + [[]]).map(\.direction), [.right],
                    "0.11 of the width is 0.165 of the height")
        var along = detector()
        expectEqual(feed(&along, glide(3, dy: 0.11) + [[]]), [], "0.11 of the height is short of 0.15")
    }

    test("a tap is not a swipe, and a swipe is not a tap") {
        var swipes = detector()
        expectEqual(feed(&swipes, glide(3, dy: -0.02, steps: 5) + [[]]), [])

        var taps = FingerTapDetector(fingers: 3)
        var tapped = false
        for (index, contacts) in (glide(3, dy: -0.3) + [[]]).enumerated() {
            let centroid: (x: Double, y: Double)? = contacts.isEmpty ? nil : (0.4, contacts[0].y)
            if taps.process(fingerCount: contacts.count, centroid: centroid, timestamp: Double(index) * 0.01) {
                tapped = true
            }
        }
        expectEqual(tapped, false)
    }

    test("finger counts that were not asked for are ignored") {
        var detector = detector()
        expectEqual(feed(&detector, glide(2, dy: -0.3) + [[]]), [])
        expectEqual(feed(&detector, glide(5, dy: -0.3) + [[]], from: 1), [])
        var threeOnly = FingerSwipeDetector(fingerCounts: [3])
        expectEqual(feed(&threeOnly, glide(4, dy: -0.3) + [[]]), [])
    }

    test("swipes are off by default and decode when absent") {
        let json = Data(#"{"trackpad": {"threeFingerTap": {"enabled": true, "value": {"missionControl": {}}}}}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(DeviceConfiguration.self, from: json) else {
            expect(false, "decoding failed")
            return
        }
        expectEqual(decoded.trackpad.threeFingerSwipes, .off([.down: .minimizeWindow]))
        expectEqual(decoded.trackpad.fourFingerSwipes, .off([.down: .hideApplication]))
        expectEqual(decoded.trackpad.actions, [.tap(fingers: 3): .missionControl],
                    "a swipe that is switched off is bound to nothing")
        expectNil(decoded.trackpad.swipes(fingers: 5))
    }

    test("only what is switched on and bound becomes an action") {
        var trackpad = TrackpadSettings()
        expectEqual(trackpad.managesAnything, false)
        trackpad.threeFingerSwipes = .on([.down: .minimizeWindow, .up: .passthrough])
        trackpad.fourFingerSwipes = .on([.down: .hideApplication, .left: .back])
        expectEqual(trackpad.managesAnything, true)
        expectEqual(trackpad.actions, [
            .swipe(fingers: 3, direction: .down): .minimizeWindow,
            .swipe(fingers: 4, direction: .down): .hideApplication,
            .swipe(fingers: 4, direction: .left): .back,
        ], "a direction left to the system is not ours")
    }

    test("swipe settings round-trip through JSON") {
        var device = DeviceConfiguration()
        device.trackpad.threeFingerSwipes = .on([.down: .minimizeWindow, .right: .keyPress(KeyCombo(keyCode: 0x0D, command: true))])
        guard let data = try? JSONEncoder().encode(device),
              let decoded = try? JSONDecoder().decode(DeviceConfiguration.self, from: data)
        else {
            expect(false, "round trip failed")
            return
        }
        expectEqual(decoded.trackpad, device.trackpad)
    }

    test("swipes can differ in one application and do not need the event tap") {
        var device = DeviceConfiguration()
        device.trackpad.threeFingerSwipes = .on([.down: .minimizeWindow])
        device.apps["app"] = AppProfile(name: "App")
        device.editProfile("app") { $0.trackpad.threeFingerSwipes = .off([.down: .minimizeWindow]) }
        expectEqual(device.apps["app"]?.overridden, [.threeFingerSwipes])
        expectEqual(device.applicationConfigurations["app"]?.trackpad.actions, [:])
        expectEqual(device.usesEventTap, false)
        expectEqual(OverridableSetting(path: \DeviceConfiguration.trackpad.fourFingerSwipes), .fourFingerSwipes)
    }

    test("Mission Control's backdrop is told from everything else on screen") {
        typealias Window = ApplicationUnderPointer.Window
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let second = CGRect(x: 1800, y: 0, width: 2560, height: 1440)
        func owners(_ windows: [Window], displays: [CGRect] = [display]) -> [pid_t] {
            ApplicationUnderPointer.overviewBackdropOwners(in: windows, displays: displays)
        }
        // As measured on macOS 27: the Dock's own window and the desktop are
        // always there, the layer-19 backdrop only while the overview is up.
        let dock = Window(ownerPID: 903, bounds: display, layer: 20)
        let desktop = Window(ownerPID: 738, bounds: display, layer: -2_147_483_624)
        let backdrop = Window(ownerPID: 738, bounds: display, layer: 19)
        let spacesBar = Window(ownerPID: 738, bounds: CGRect(x: 0, y: 0, width: 1800, height: 134), layer: 14)

        expectEqual(owners([dock, desktop]), [], "idle")
        expectEqual(owners([dock, backdrop, spacesBar, desktop]), [738], "Mission Control")
        expectEqual(owners([dock, spacesBar, desktop]), [], "the Spaces bar alone outlives the backdrop")
        expectEqual(owners([Window(ownerPID: 1, bounds: display, layer: 0)]), [],
                    "a full-screen application window is not an overview")
        expectEqual(owners([Window(ownerPID: 738, bounds: display, layer: 19, alpha: 0)]), [], "invisible")
        expectEqual(owners([Window(ownerPID: 738, bounds: second, layer: 19)], displays: [display, second]),
                    [738], "on the second display")
    }

    test("Mission Control is looked for once per touch, as the fingers land") {
        var watch = OverviewWatch(fingers: 3)
        expectEqual(watch.shouldLook(fingerCount: 1), false, "pointing costs nothing")
        expectEqual(watch.shouldLook(fingerCount: 2), false, "nor does scrolling")
        expectEqual(watch.shouldLook(fingerCount: 3), true)
        expectEqual(watch.shouldLook(fingerCount: 3), false, "once is enough")
        expectEqual(watch.shouldLook(fingerCount: 4), false, "a fourth finger is the same touch")
        watch.sawOverview()
        // The overview closes under the moving fingers; the touch is still its.
        expectEqual(watch.shouldLook(fingerCount: 2), false)
        expectEqual(watch.overviewSeen, true, "remembered until the hand lifts")
        expectEqual(watch.shouldLook(fingerCount: 0), false)
        expectEqual(watch.overviewSeen, false, "a new touch starts clean")
        expectEqual(watch.shouldLook(fingerCount: 4), true, "four fingers landing at once")
    }

    test("what was sent away last comes back first") {
        typealias Entry = RestoreHistory<Int>.Entry
        var history = RestoreHistory<Int>()
        history.record(.window(10, 1))
        history.record(.application(20))
        history.record(.window(10, 2))
        expectEqual(history.takeLast(), .window(10, 2))
        expectEqual(history.takeLast(), .application(20))
        expectEqual(history.takeLast(), .window(10, 1))
        expectNil(history.takeLast(), "nothing left")
    }

    test("something sent away twice is remembered once, at its latest place") {
        var history = RestoreHistory<Int>()
        history.record(.application(20))
        history.record(.window(10, 1))
        history.record(.application(20))
        expectEqual(history.entries, [.window(10, 1), .application(20)])
    }

    test("an application that quits takes its windows out of the history") {
        var history = RestoreHistory<Int>()
        history.record(.window(10, 1))
        history.record(.application(20))
        history.record(.application(10))
        history.forget(pid: 10)
        expectEqual(history.entries, [.application(20)])
    }

    test("the history keeps only the newest entries") {
        var history = RestoreHistory<Int>(capacity: 3)
        for window in 1 ... 5 { history.record(.window(10, window)) }
        expectEqual(history.entries, [.window(10, 3), .window(10, 4), .window(10, 5)])
    }

    test("the window actions have names and survive JSON") {
        expectEqual(Action.minimizeWindow.displayName, "Minimise window")
        expectEqual(Action.hideApplication.displayName, "Hide application")
        expectEqual(Action.restoreMinimizedOrHidden.displayName, "Restore last minimised or hidden")
        for action in [Action.minimizeWindow, .hideApplication, .restoreMinimizedOrHidden] {
            let data = try? JSONEncoder().encode(action)
            expectEqual(data.flatMap { try? JSONDecoder().decode(Action.self, from: $0) }, action)
            expect(Action.simpleChoices.contains(action), "\(action.displayName) is offered in the menu")
        }
        expectEqual(TrackpadGesture.swipe(fingers: 3, direction: .down).displayName, "3-finger swipe down")
    }
}

// MARK: - Reconciler

suite("Reconciler — nothing is written while the Mac sleeps") {
    // DarkWake: a sleeping Mac surfaces briefly on its own, and HID traffic in
    // that window can promote it to a full wake. The gate is cheap; the test
    // pins it because forgetting it costs a Mac that wakes itself at night.
    func detachedDevice() -> ManagedDevice {
        ManagedDevice(key: "unit:TEST", displayName: "Test mouse",
                      target: nil, endpoint: nil, pointerService: nil)
    }

    test("a suspended reconciler drops the request instead of touching the device") {
        let reconciler = HardwareReconciler()
        let device = detachedDevice()
        reconciler.suspend()
        expectEqual(reconciler.isSuspended, true)

        reconciler.reconcile(device: device, configuration: DeviceConfiguration(),
                             globallyEnabled: true, confirm: true, reason: "test")
        // Statuses are published on the main queue, so pump it.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        expectNil(reconciler.statuses[device.key],
                  "no status must be published: no work was queued")
    }

    test("resume opens the gate again") {
        let reconciler = HardwareReconciler()
        reconciler.suspend()
        reconciler.resume()
        expectEqual(reconciler.isSuspended, false)

        let device = detachedDevice()
        reconciler.reconcile(device: device, configuration: DeviceConfiguration(),
                             globallyEnabled: true, reason: "test")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        expect(reconciler.statuses[device.key] != nil, "after resume the request is processed")
    }
}

// MARK: - HID++ protocol

suite("HID++ protocol") {
    test("feature IDs serialise big-endian") {
        expectEqual(HIDPPFeatureID.smartShiftEnhanced.bytes, [0x21, 0x11])
        expectEqual(HIDPPFeatureID.adjustableDPI.bytes, [0x22, 0x01])
    }

    test("a busy device is worth retrying, an unsupported feature is not") {
        expectEqual(HIDPPError.device(.busy).isTransient, true)
        expectEqual(HIDPPError.timeout.isTransient, true)
        expectEqual(HIDPPError.featureUnsupported(.smartShift).isTransient, false)
        expectEqual(HIDPPError.device(.unsupported).isTransient, false)
    }

    test("responses decode multi-byte fields big-endian") {
        let response = HIDPPResponse(deviceIndex: 1, featureIndex: 2, address: 0x0A,
                                     payload: [0x00, 0x06, 0x40, 0x00])
        expectEqual(response.byte(1), 0x06)
        expectEqual(response.word(1), 0x0640)
    }

    test("the buttons macOS already handles are never offered for remapping") {
        expect(HIDPPControl.systemHandled.contains(HIDPPControl.leftClick))
        expect(HIDPPControl.systemHandled.contains(HIDPPControl.rightClick))
        expect(!HIDPPControl.systemHandled.contains(HIDPPControl.wheelModeButton))
        expect(!HIDPPControl.systemHandled.contains(HIDPPControl.gestureButton))
    }
}

// MARK: - Service matching

suite("Service matching — one physical mouse must never become two devices") {
    let logitech = 0x046D

    test("a USB service matching vendor, product and location is claimed") {
        let endpoint = ServiceMatching.Identity(vendorID: logitech, productID: 0xC548, locationID: 0x14100000)
        let services = [
            ServiceMatching.Identity(vendorID: logitech, productID: 0xC548, locationID: 0x14100000),
            ServiceMatching.Identity(vendorID: 0x05AC, productID: 0x0342, locationID: nil, product: "Apple Internal Trackpad"),
        ]
        expectEqual(ServiceMatching.indicesMatching(endpoint: endpoint, services: services), [0])
    }

    test("location tells two identical receivers apart") {
        let endpoint = ServiceMatching.Identity(vendorID: logitech, productID: 0xC52B, locationID: 0x1000)
        let services = [
            ServiceMatching.Identity(vendorID: logitech, productID: 0xC52B, locationID: 0x2000),
            ServiceMatching.Identity(vendorID: logitech, productID: 0xC52B, locationID: 0x1000),
        ]
        expectEqual(ServiceMatching.indicesMatching(endpoint: endpoint, services: services), [1])
    }

    test("a Bluetooth location mismatch falls back rather than losing the service") {
        // Over Bluetooth macOS splits the collections into separate registry
        // entries whose location IDs do not always agree. Losing the match here
        // is what made the same mouse show up twice.
        let endpoint = ServiceMatching.Identity(vendorID: logitech, productID: 0xB034, locationID: 0x1F2)
        let services = [
            ServiceMatching.Identity(vendorID: logitech, productID: 0xB034, locationID: 0x1F1, product: "MX Master 3S"),
        ]
        expectEqual(ServiceMatching.indicesMatching(endpoint: endpoint, services: services), [0])
    }

    test("the trackpad is never claimed by a Logitech endpoint") {
        let endpoint = ServiceMatching.Identity(vendorID: logitech, productID: 0xB034, locationID: nil)
        let services = [
            ServiceMatching.Identity(vendorID: 0x05AC, productID: 0x0342, locationID: nil, product: "Apple Internal Trackpad"),
        ]
        expectEqual(ServiceMatching.indicesMatching(endpoint: endpoint, services: services), [])
    }

    test("a stray Logitech service is reunited with its device by name") {
        let service = ServiceMatching.Identity(vendorID: logitech, productID: 0xB034, product: "mx master 3s")
        expect(ServiceMatching.service(service, belongsToDeviceNamed: "MX Master 3S", vendorID: logitech))
    }

    test("name reunification never crosses vendors or names") {
        let trackpad = ServiceMatching.Identity(vendorID: 0x05AC, product: "MX Master 3S")
        expect(!ServiceMatching.service(trackpad, belongsToDeviceNamed: "MX Master 3S", vendorID: logitech))

        let other = ServiceMatching.Identity(vendorID: logitech, productID: 0xC08B, product: "G502 HERO")
        expect(!ServiceMatching.service(other, belongsToDeviceNamed: "MX Master 3S", vendorID: logitech))
    }
}

suite("Diverted button subscriptions — a rescan must not leave a dead one behind") {
    // Stands in for a ManagedDevice: the table only ever looks at identity.
    final class Device {}

    test("a subscription is recognised only on the object it was made for") {
        var table = AttachmentTable<Int>()
        let first = Device()
        expect(!table.holds(key: "unit:A9", device: ObjectIdentifier(first)))

        expectNil(table.insert(key: "unit:A9", device: ObjectIdentifier(first), observation: 1))
        expect(table.holds(key: "unit:A9", device: ObjectIdentifier(first)))

        // What a rescan does: same mouse, same key, brand new object.
        let second = Device()
        expect(!table.holds(key: "unit:A9", device: ObjectIdentifier(second)),
               "a subscription made for the previous object must not count as attached")
    }

    test("re-attaching hands back the subscription it displaced") {
        var table = AttachmentTable<Int>()
        let first = Device()
        let second = Device()
        _ = table.insert(key: "unit:A9", device: ObjectIdentifier(first), observation: 1)

        expectEqual(table.insert(key: "unit:A9", device: ObjectIdentifier(second), observation: 2), 1,
                    "the displaced observation must come back so the caller can cancel it")
        expect(table.holds(key: "unit:A9", device: ObjectIdentifier(second)))
    }

    test("a device that goes away takes its subscription with it") {
        var table = AttachmentTable<Int>()
        let mouse = Device()
        let keyboard = Device()
        _ = table.insert(key: "unit:A9", device: ObjectIdentifier(mouse), observation: 1)
        _ = table.insert(key: "unit:B7", device: ObjectIdentifier(keyboard), observation: 2)

        expectEqual(table.removeAll(except: ["unit:A9"]), [2])
        expect(table.holds(key: "unit:A9", device: ObjectIdentifier(mouse)))

        expectEqual(table.remove(key: "unit:A9"), 1)
        expectNil(table.remove(key: "unit:A9"))
        expect(table.isEmpty)
    }

    test("detaching everything returns every subscription exactly once") {
        var table = AttachmentTable<Int>()
        _ = table.insert(key: "unit:A9", device: ObjectIdentifier(Device()), observation: 1)
        _ = table.insert(key: "unit:B7", device: ObjectIdentifier(Device()), observation: 2)

        expectEqual(table.removeAll().sorted(), [1, 2])
        expect(table.isEmpty)
        expect(table.removeAll().isEmpty)
    }
}

// MARK: - Custom actions

suite("Custom actions — shortcuts, clicks and scrolls") {
    func roundTrip(_ action: Action) -> Action? {
        guard let data = try? JSONEncoder().encode(action) else { return nil }
        return try? JSONDecoder().decode(Action.self, from: data)
    }

    test("custom actions round-trip through JSON") {
        let actions: [Action] = [
            .keyPress(KeyCombo(keyCode: 0x0F, command: true)),
            .mouseClick(MouseClick(button: 0, count: 2, modifiers: [.command, .shift])),
            .scroll(ScrollStep(direction: .down, lines: 5, modifiers: [.command])),
        ]
        for action in actions {
            expectEqual(roundTrip(action), action)
        }
    }

    test("a legacy mouse-button action still decodes") {
        let json = Data(#"{"mouseButton":{"_0":2}}"#.utf8)
        expectEqual(try? JSONDecoder().decode(Action.self, from: json), .mouseButton(2))
    }

    test("shortcuts read the way macOS prints them") {
        expectEqual(KeyCombo(keyCode: 0x0F, command: true).displayString, "⌘R")
        expectEqual(KeyCombo(keyCode: 0x11, command: true, shift: true).displayString, "⇧⌘T")
        expectEqual(KeyCombo(keyCode: 0x7B, control: true).displayString, "⌃←")
        expectEqual(KeyCombo(keyCode: 0x60).displayString, "F5")
    }

    test("arrows and function keys carry the flags a real keyboard adds") {
        // The "move a space left" system hotkey is ⌃ + fn + ←; without the
        // intrinsic flags a synthesised ⌃← does not match it.
        let left = KeyCombo(keyCode: 0x7B, control: true)
        expect(left.intrinsicFlags.contains(.maskSecondaryFn))
        expect(left.intrinsicFlags.contains(.maskNumericPad))
        expect(KeyCombo(keyCode: 0x60).intrinsicFlags.contains(.maskSecondaryFn), "F5")
        expectEqual(KeyCombo(keyCode: 0x0F, command: true).intrinsicFlags, [], "a letter has none")
    }

    test("a shortcut is one down and one up with exactly its flags") {
        let events = ActionRunner.keyEvents(KeyCombo(keyCode: 0x0F, command: true))
        expectEqual(events.map(\.type), [.keyDown, .keyUp])
        for event in events {
            expectEqual(event.getIntegerValueField(.keyboardEventKeycode), 0x0F)
            expect(event.flags.contains(.maskCommand))
            expect(!event.flags.contains(.maskShift))
        }
    }

    test("a double click is two down/up pairs counted 1 then 2") {
        let click = MouseClick(button: 0, count: 2)
        let events = ActionRunner.clickEvents(click, at: CGPoint(x: 10, y: 20))
        expectEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        expectEqual(events.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2])
        expectEqual(events.first?.location, CGPoint(x: 10, y: 20))
    }

    test("a modified middle click keeps its button number and flags") {
        let click = MouseClick(button: 2, count: 1, modifiers: [.command])
        let events = ActionRunner.clickEvents(click, at: .zero)
        expectEqual(events.map(\.type), [.otherMouseDown, .otherMouseUp])
        for event in events {
            expectEqual(event.getIntegerValueField(.mouseEventButtonNumber), 2)
            expect(event.flags.contains(.maskCommand))
        }
    }

    test("the click count is clamped to a triple click") {
        let events = ActionRunner.clickEvents(MouseClick(button: 1, count: 9), at: .zero)
        expectEqual(events.count, 6)
        expectEqual(events.first?.type, .rightMouseDown)
    }

    test("scroll directions map onto CoreGraphics' wheel axes") {
        expectEqual(ScrollStep(direction: .up, lines: 3).wheelDeltas.vertical, 3)
        expectEqual(ScrollStep(direction: .down, lines: 3).wheelDeltas.vertical, -3)
        expectEqual(ScrollStep(direction: .left, lines: 2).wheelDeltas.horizontal, 2)
        expectEqual(ScrollStep(direction: .right, lines: 2).wheelDeltas.horizontal, -2)
        expectEqual(ScrollStep(direction: .down, lines: 3).wheelDeltas.horizontal, 0)
    }

    test("⌘ + scroll down is one line-unit wheel event carrying ⌘") {
        let events = ActionRunner.scrollEvents(ScrollStep(direction: .down, lines: 1, modifiers: [.command]))
        expectEqual(events.count, 1)
        guard let event = events.first else { return }
        expectEqual(event.type, .scrollWheel)
        expectEqual(ScrollWheelEvent(event).deltaY, -1)
        expect(event.flags.contains(.maskCommand))
    }

    test("custom actions have readable names") {
        expectEqual(Action.mouseClick(MouseClick(button: 0, count: 2)).displayName, "Left double-click")
        expectEqual(
            Action.scroll(ScrollStep(direction: .down, lines: 1, modifiers: [.command])).displayName,
            "⌘ scroll down 1 line"
        )
    }
}

report()
