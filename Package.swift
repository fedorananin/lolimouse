// swift-tools-version: 6.0
//
// LoLiMouse — a single, native, open-source mouse configurator for macOS.
// MIT License. See LICENSE.

import PackageDescription

let package = Package(
    name: "LoLiMouse",
    // macOS 15 for SwiftUI's `defaultLaunchBehavior(.suppressed)`, which is
    // what lets a login-item launch come up quietly in the menu bar.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LoLiMouse", targets: ["LoLiMouseApp"]),
        .executable(name: "LoLiMouseTests", targets: ["LoLiMouseTests"]),
        .library(name: "HIDPP", targets: ["HIDPP"]),
    ],
    targets: [
        // Private IOKit / CoreGraphics declarations that Apple ships as symbols
        // but not as headers. Kept deliberately tiny — everything that has a
        // public equivalent uses the public API instead.
        .target(name: "IOKitSPI"),

        // IOHIDManager device discovery, synchronous HID report transactions,
        // and per-device pointer tuning through IOHIDServiceClient.
        .target(name: "HIDKit", dependencies: ["IOKitSPI"]),

        // The Logitech HID++ 1.0 / 2.0 protocol stack.
        .target(name: "HIDPP", dependencies: ["HIDKit"]),

        // Configuration, device registry, hardware reconciliation and the
        // CGEvent processing pipeline.
        .target(name: "LoLiCore", dependencies: ["HIDKit", "HIDPP", "IOKitSPI"]),

        // The SwiftUI application.
        .executableTarget(name: "LoLiMouseApp", dependencies: ["LoLiCore"]),

        // A plain executable rather than a test target: XCTest and
        // swift-testing both ship with Xcode, and this project deliberately
        // builds with nothing but the Command Line Tools.
        .executableTarget(name: "LoLiMouseTests", dependencies: ["LoLiCore", "HIDPP"]),
    ],
    swiftLanguageModes: [.v5]
)
