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

    test("DPI presets cycle and wrap around") {
        let presets = DPIPresets(values: [800, 1600, 3200], activeIndex: 0)
        expectEqual(presets.active, 800)
        expectEqual(presets.next().active, 1600)
        expectEqual(presets.next().next().active, 3200)
        expectEqual(presets.next().next().next().active, 800, "cycling must wrap")
    }
}

// MARK: - Wheel ratchet

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

report()
