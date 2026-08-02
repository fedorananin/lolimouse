# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

LoLiMouse is a macOS-only, MIT-licensed mouse configurator. It combines two
things that normally require separate applications fighting each other:
talking to a Logitech mouse over HID++, and reshaping scroll and button events
through a CGEvent tap.

It is an independent project, **not a fork**. Protocol knowledge and a number of
implementation techniques were learned by reading
[LinearMouse](https://github.com/linearmouse/linearmouse) (MIT) and
[OpenLogi](https://github.com/AprilNEA/OpenLogi) (MIT/Apache-2.0). Both are worth
consulting when a protocol detail is unclear — they are the reference
implementations for this problem space.

## Non-negotiable safety rules

**Read this section before touching anything under `Sources/HIDKit` or
`Sources/LoLiCore/Events`.**

This project can take a Mac down hard — not "crash and reopen", but "the
built-in keyboard and trackpad stop responding and the machine must be
restarted". That has already happened once during development. Three rules
exist because of it:

1. **Never open a HID device we do not need to talk to.** A device this process
   holds open when it dies can stay seized by the kernel until reboot.
   `IOHIDManagerOpen` must never be called — it opens *every* matched device at
   once. Only Logitech vendor-defined collections are opened, one at a time.
   `HIDDevice.isOpenable` is the last line of defence and must stay strict.
2. **Never match a device we do not need.** `HIDDeviceMonitor` matches Logitech
   devices only. Ordinary mice and trackpads are served entirely by
   `IOHIDServiceClient`, which opens nothing.
3. **The event tap is installed only while it has work to do.** An active tap at
   `kCGHIDEventTap` sits in front of every input event on the machine. With no
   scrolling or button settings switched on, no tap is installed at all, and the
   tap only ever asks for the event types it acts on (`flagsChanged` is added to
   the mask only while a pinch-zoom modifier action is configured).

**Do not launch the app on a user's machine without asking first.** Verifying a
change usually means `make test` plus reading the code. When a real run is
genuinely needed, say so and let the user decide.

### IOKit lifecycle traps

Every one of these was found the hard way, each costing a crash:

- `CFRunLoopSourceCreate(nil, 0, nil)` traps — the context argument is
  mandatory. Use `RunLoop.add(Port(), forMode:)` to hold a run loop open.
- Device references handed over by `IOHIDManager` are **already activated by the
  manager**. Registering an input-report callback on one asserts with `Device
  has already been activated/cancelled`. `HIDDevice.open()` therefore builds its
  own reference with `IOHIDDeviceCreate(_:IOHIDDeviceGetService(device))`.
- With the dispatch-queue API, the close belongs in the cancel handler. Calling
  `IOHIDDeviceClose` directly after `IOHIDDeviceCancel` asserts.
- Callbacks must not be re-registered on an activated `IOHIDManager`. Teardown
  is `IOHIDManagerCancel` and nothing else.

Anything that runs on a real thread or touches IOKit lifecycle gets a test in
`Sources/LoLiMouseTests` — see the event-thread suite for the pattern.

## Build and test

```sh
make build      # compile
make test       # run the suite (also: swift run LoLiMouseTests)
make bundle     # assemble build/LoLiMouse.app
make install    # bundle + copy to /Applications
make uninstall  # remove the app, keep settings
```

**Tests are a plain executable, not XCTest.** Both XCTest and swift-testing ship
inside Xcode, and this project builds with only the Command Line Tools. The
harness lives in `Sources/LoLiMouseTests/Harness.swift`; add cases to `main.swift`
using `suite`, `test`, `expect`, `expectEqual`, `expectClose`, `expectNil`.

### Signing

macOS ties Accessibility and Input Monitoring grants to the designated
requirement. Ad-hoc signing embeds the binary hash, so **every rebuild becomes a
new app** and both permissions have to be granted again — and they land in a
*denied* state that toggling the checkbox does not fix, requiring
`tccutil reset ListenEvent me.fedorananin.LoLiMouse` (and `Accessibility`).

`.signing.mk` (git-ignored) pins a self-signed code-signing certificate, which
makes the requirement `identifier "…" and certificate leaf = H"…"` — stable
across rebuilds.

A self-signed certificate with no trust settings does **not** appear in
`security find-identity -v -p codesigning`, but signs fine when passed by
fingerprint. Use `security find-identity` (without `-v`) to find it. Adding
trust settings is unnecessary.

## Architecture

| Target | Responsibility |
|---|---|
| `IOKitSPI` | The few private IOKit/CoreGraphics declarations Apple ships as symbols but not headers. Keep it minimal — anything with a public equivalent uses that. |
| `HIDKit` | `IOHIDManager` discovery, synchronous HID report transactions, per-device pointer tuning via `IOHIDServiceClient`. |
| `HIDPP` | Logitech HID++ 1.0/2.0: framing, feature resolution, receiver slots, typed feature wrappers. |
| `LoLiCore` | Configuration, device registry, hardware reconciler, CGEvent pipeline. |
| `LoLiMouseApp` | AppKit lifecycle (`@main` app delegate, own `NSStatusItem`, `NSHostingController`-hosted SwiftUI views). Not a SwiftUI `App` on purpose: a `MenuBarExtra` scene terminates the app when its icon is hidden, and a suppressed `Window` scene cannot be opened from AppKit at all. Do not reintroduce SwiftUI scenes. |
| `LoLiMouseTests` | Executable test suite. |

### The two ideas the project is built around

**Every setting is individually switchable.** `Sources/LoLiCore/Config/Setting.swift`
is the whole premise: nothing is written to the mouse or to macOS unless that
specific setting is switched on, and switching it off restores the value that
was there before. This is what lets LoLiMouse coexist with other tools. When
adding a feature, it gets its own `Setting`, its own baseline, and its own
restore path — no exceptions.

**Settings survive reconnects.** `Sources/LoLiCore/Reconcile/HardwareReconciler.swift`
exists because SmartShift, DPI, wheel mode and button diversion live in the
mouse's RAM and are wiped by every power cycle. It reapplies on arrival, writes
a second confirming time a few seconds later to beat the firmware's own
start-up, retries with backoff when the device is asleep, and keeps baselines so
disabling a setting puts the original back.

### Threading

- Device scanning and all HID++ traffic: background queues. HID++ transactions
  block; never run them on the main thread.
- The CGEvent tap: its own `userInteractive` thread (`EventThread`). macOS
  disables a tap whose owner answers slowly.
- The tap callback never reads `store.configuration` or `registry.devices`
  directly. It takes one lock and copies `AppController.EventSnapshot`.
- Everything else: main thread.

### Device identity

Devices are keyed by HID++ unit ID (`unit:A91CDB35`), which identifies the
physical mouse regardless of how it is connected, so settings follow the
hardware between Bluetooth and a receiver. Devices without HID++ fall back to
`usb:VVVV:PPPP`. Config lives at
`~/Library/Application Support/LoLiMouse/config.json`; an absent setting means
"off", so the file only mentions what was actually turned on.

## Current state

Verified on hardware (MX Master 3S over Bluetooth LE):

- Device discovery, hotplug, clean start and quit.
- HID++ reaches the mouse: firmware name and unit ID read back over a direct
  (`0xFF`) connection.
- 61 tests pass.

**Not yet verified on hardware** — written from the protocol specifications and
the two reference implementations, never exercised against a real device:

- SmartShift / ratchet control (`0x2110`, `0x2111`)
- DPI (`0x2201`), report rate (`0x8060`)
- Button diversion (`0x1B04`), the wheel-mode button, thumb-button gestures
- The scroll pipeline end to end, including detent normalisation
- Reconnect reapplication
- Modifier-key scroll actions (`ModifierKeyTransformer`): zoom keystrokes,
  pinch-zoom gesture synthesis (private CGEvent fields 110/113/132), the
  dynamic `flagsChanged` tap mask
- Modifier-qualified button mappings (⌘+button → different action)
- Media/brightness actions (NX system-defined key events)
- Battery level in the menu bar

Do not describe any of the above as working until it has been seen working.

## Conventions

- Comments explain *why*, especially where the reason is a platform quirk that
  cost a crash to discover. Do not remove those comments.
- Prefer public API over SPI. Every SPI declaration in `IOKitSPI` should have a
  comment saying why no public equivalent exists.
- User-facing strings are British English.
- Log through `LoLiLog` categories (`hid`, `hidpp`, `devices`, `reconcile`,
  `events`, `config`, `app`), readable with:

  ```sh
  log stream --predicate 'subsystem == "me.fedorananin.LoLiMouse"' --style compact
  ```

  When something does not work, read the log before theorising. The permission
  line reports exactly what the app sees, including the raw
  `IOHIDCheckAccess` value: `0` granted, `1` denied, `2` never asked.
