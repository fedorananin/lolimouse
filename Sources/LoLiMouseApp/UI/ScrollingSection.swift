// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import LoLiCore
import SwiftUI

/// Scrolling behaviour applied to the event stream, per axis.
struct ScrollingSection: View {
    @ObservedObject var model: DeviceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(
                title: "Precision",
                subtitle: "The fix for galleries and carousels that jump several items per click."
            ) {
                ManagedSetting(
                    title: "Collapse high-resolution scrolling into whole clicks",
                    help: "Counts the wheel's fine increments and emits exactly one scroll event per "
                        + "physical click. Works even when another application has switched the "
                        + "high-resolution wheel on behind your back. Applies to the vertical wheel "
                        + "only — the thumbwheel has no clicks and stays smooth.",
                    isManaged: model.enabled(\.scrolling.normalizeHighResolutionWheel)
                ) {
                    Toggle("Enabled", isOn: model.value(\.scrolling.normalizeHighResolutionWheel))
                }
            }

            AxisSettings(
                title: "Vertical scrolling",
                model: model,
                axis: \.scrolling.vertical
            )

            AxisSettings(
                title: "Horizontal scrolling",
                model: model,
                axis: \.scrolling.horizontal
            )
        }
    }
}

private struct AxisSettings: View {
    let title: String
    @ObservedObject var model: DeviceSettingsModel
    let axis: WritableKeyPath<DeviceConfiguration, AxisScrolling>

    var body: some View {
        SettingsSection(title: title) {
            ManagedSetting(
                title: "Reverse direction",
                isManaged: model.enabled(axis.appending(path: \.reverse))
            ) {
                Toggle("Reversed", isOn: model.value(axis.appending(path: \.reverse)))
            }

            Divider()

            ManagedSetting(
                title: "Fixed distance per click",
                help: "Every click scrolls exactly the same amount. This is what makes scrolling "
                    + "linear — with it on, acceleration no longer applies.",
                isManaged: model.enabled(axis.appending(path: \.distance))
            ) {
                distanceControls
            }

            Divider()

            ManagedSetting(
                title: "Acceleration",
                help: "Above 1, fast flicks travel further than slow ones. Ignored while a fixed "
                    + "distance is in use.",
                isManaged: model.enabled(axis.appending(path: \.acceleration))
            ) {
                LabelledSlider(
                    label: "Curve",
                    value: model.value(axis.appending(path: \.acceleration)),
                    range: 0.5 ... 3,
                    step: 0.05
                )
            }

            Divider()

            ManagedSetting(
                title: "Speed",
                help: "A flat multiplier applied on top of everything else.",
                isManaged: model.enabled(axis.appending(path: \.speed))
            ) {
                LabelledSlider(
                    label: "Multiplier",
                    value: model.value(axis.appending(path: \.speed)),
                    range: 0.1 ... 5,
                    step: 0.05
                )
            }
        }
    }

    @ViewBuilder
    private var distanceControls: some View {
        let distance = model.value(axis.appending(path: \.distance))

        VStack(alignment: .leading, spacing: 8) {
            Picker("Unit", selection: Binding(
                get: { DistanceKind(distance.wrappedValue) },
                set: { kind in distance.wrappedValue = kind.distance(amount(distance.wrappedValue)) }
            )) {
                Text("Lines").tag(DistanceKind.lines)
                Text("Pixels").tag(DistanceKind.pixels)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Stepper(
                value: Binding(
                    get: { amount(distance.wrappedValue) },
                    set: { distance.wrappedValue = DistanceKind(distance.wrappedValue).distance($0) }
                ),
                in: 1 ... 200
            ) {
                Text("\(amount(distance.wrappedValue)) per click")
            }
            .frame(width: 220)
        }
    }

    private func amount(_ distance: ScrollDistance) -> Int {
        switch distance {
        case .system: return 3
        case let .lines(count): return count
        case let .pixels(count): return count
        }
    }
}

private enum DistanceKind: Hashable {
    case lines, pixels

    init(_ distance: ScrollDistance) {
        switch distance {
        case .pixels: self = .pixels
        case .lines, .system: self = .lines
        }
    }

    func distance(_ amount: Int) -> ScrollDistance {
        switch self {
        case .lines: return .lines(amount)
        case .pixels: return .pixels(amount)
        }
    }
}
