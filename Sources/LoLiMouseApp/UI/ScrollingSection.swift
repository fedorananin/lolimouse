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

            SettingsSection(
                title: "Modifier keys",
                subtitle: "Change what the wheel does while a modifier key is held."
            ) {
                ManagedSetting(
                    title: "Act on modifier keys while scrolling",
                    help: "For example, hold ⌘ and scroll to zoom. The application never sees the "
                        + "modifier itself, so its own shortcuts stay out of the way.",
                    isManaged: model.enabled(\.scrolling.modifiers)
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ModifierKey.allCases, id: \.self) { modifier in
                            ModifierActionRow(
                                modifier: modifier,
                                actions: model.value(\.scrolling.modifiers)
                            )
                        }
                    }
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

/// One modifier's row: a picker over the possible actions, plus a speed
/// slider when the chosen action is "change speed".
private struct ModifierActionRow: View {
    let modifier: ModifierKey
    @Binding var actions: [ModifierKey: ModifierKeyAction]

    /// The fixed menu entries. `changeSpeed` keeps its configured scale when
    /// re-selected, so it is handled separately.
    private static let simpleChoices: [ModifierKeyAction?] = [
        nil, .ignore, .preventDefault, .alterOrientation,
        .zoom, .zoomReversed, .pinchZoom, .pinchZoomReversed,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(modifier.displayName, selection: selection) {
                ForEach(Array(Self.simpleChoices.enumerated()), id: \.offset) { _, choice in
                    Text(choice?.displayName ?? "No change").tag(Selection(choice))
                }
                Text(ModifierKeyAction.changeSpeed(2).displayName).tag(Selection.changeSpeed)
            }
            .pickerStyle(.menu)

            if case let .changeSpeed(scale) = actions[modifier] {
                LabelledSlider(
                    label: "Multiplier",
                    value: Binding(
                        get: { scale },
                        set: { actions[modifier] = .changeSpeed($0) }
                    ),
                    range: 0.1 ... 10,
                    step: 0.1
                )
                .padding(.leading, 16)
            }
        }
    }

    /// A hashable stand-in for "no action or one of the actions", because
    /// `changeSpeed`'s payload must not fragment the menu into one entry per
    /// slider position.
    private enum Selection: Hashable {
        case none
        case simple(ModifierKeyAction)
        case changeSpeed

        init(_ action: ModifierKeyAction?) {
            switch action {
            case nil: self = .none
            case .changeSpeed: self = .changeSpeed
            case let .some(other): self = .simple(other)
            }
        }
    }

    private var selection: Binding<Selection> {
        Binding(
            get: { Selection(actions[modifier]) },
            set: { newValue in
                switch newValue {
                case .none: actions[modifier] = nil
                case let .simple(action): actions[modifier] = action
                case .changeSpeed:
                    if case .changeSpeed = actions[modifier] { break }
                    actions[modifier] = .changeSpeed(2)
                }
            }
        )
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
