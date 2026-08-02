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
