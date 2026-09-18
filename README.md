# LoLiMouse

One app for the whole mouse, on macOS. Free, open source, and it does not fight
with anything else you have installed.

Configuring a Logitech mouse on a Mac usually takes two or three applications at
once: one to talk to the hardware, another to fix scrolling, and Logitech's own
software to make the extra buttons work. They overlap, they overwrite each
other, and the result is a mouse that behaves differently depending on which one
started last. LoLiMouse is both halves in one place.

## Install

Download the latest `LoLiMouse-vX.Y.Z.zip` from the
[releases page](https://github.com/fedorananin/lolimouse/releases), unzip it,
and drag `LoLiMouse.app` into `/Applications`.

> [!IMPORTANT]
> **macOS will refuse to open the app the first time.** LoLiMouse is not
> notarised — that requires a paid Apple Developer subscription, which this
> free project does not have. The build is reproducible from the source in
> this repository, and this is the entire workaround:
>
> 1. Open the app once and let macOS refuse it.
> 2. Go to **System Settings → Privacy & Security**, scroll down, and click
>    **Open Anyway** next to the LoLiMouse message.
>
> Or skip the dialog entirely from Terminal:
>
> ```sh
> xattr -d com.apple.quarantine /Applications/LoLiMouse.app
> ```

On first launch LoLiMouse appears in the menu bar (no Dock icon — the Dock icon
only exists while the settings window is open). Click the mouse icon in the
menu bar and choose **Settings…** to configure it, and tick **Start at login**
there if you want it running permanently.

Prefer an empty menu bar? Untick **Show in menu bar** in the settings window —
or hide the icon from System Settings → Menu Bar, or ⌘-drag it off. LoLiMouse
keeps running invisibly either way; open it again from the Applications folder
(or Spotlight) whenever you want the settings window back.

### Permissions

LoLiMouse asks for exactly two, and needs no kernel extension, driver, or
process running as root:

- **Accessibility** — to see and reshape scroll and button events. Without it,
  scrolling, gestures and button remapping do nothing.
- **Input Monitoring** — to talk to the mouse over HID++. Without it, the
  ratchet, DPI and the extra buttons cannot be configured.

Grant both from the Permissions tab in the app, or in System Settings →
Privacy & Security.

### Requirements

macOS 15 or later. Logitech mice get the full feature set; any other mouse gets
everything except the firmware settings.

## What makes it different

**Every setting has its own switch.** Nothing is written to your mouse or to
macOS unless you turned that specific setting on. Turn one back off and the
value that was there before is restored. That is why LoLiMouse can share a
machine with other tools instead of arguing with them — use it for the wheel
ratchet only, or for scrolling only, and it will leave everything else strictly
alone.

**Settings survive a reconnect.** SmartShift, DPI and diverted buttons live in
the mouse's RAM, and every power cycle wipes them: switching the mouse off,
letting it sleep, moving it between Bluetooth and a receiver. LoLiMouse notices
the device come back, reapplies everything, and then writes again a few seconds
later to beat the firmware's own start-up — the race that makes the first write
disappear.

## Features

Firmware settings, over Logitech HID++ (shown only for devices whose firmware
actually implements them):

- **Wheel ratchet** — always ratchet, SmartShift with an adjustable threshold,
  or always free spin. "Always ratchet" means the wheel never slips into free
  spin however hard you flick it, which Logitech's own software will not do.
- **High-resolution wheel** — on or off, in the device itself.
- **DPI**, either a fixed value or a set of presets you can cycle through.
- **Report rate**, from 125 Hz to 1000 Hz.
- **Firmware scroll inversion**, for when you want it to follow the mouse to
  other computers.

Buttons macOS cannot see on its own:

- **The wheel-mode button** below the wheel — bind it to anything, cycling DPI
  presets being the obvious one.
- **The thumb button**, with optional flick gestures: hold it and move the mouse
  up, down, left or right. Gestures can be switched off entirely, leaving a
  plain extra button.

Event handling:

- **Detent normalisation** — collapses the high-resolution wheel's eight-plus
  events per click back into one. This is the fix for photo galleries and
  carousels that jump several items per click, and it works even when another
  application has switched the high-resolution wheel on behind your back. The
  thumbwheel is left alone — it has no detents and stays smooth.
- **Linear or accelerated scrolling**, per axis, with a fixed distance per click
  or an adjustable acceleration curve, plus a speed multiplier and direction
  reversal.
- **Modifier keys while scrolling** — hold ⌘ (or ⇧, ⌥, ⌃) and the wheel does
  something else: zoom via the application's own ⌘= / ⌘− shortcut, a smooth
  trackpad-style pinch zoom, a different scrolling speed, swapped axes, or
  nothing at all. The application never sees the modifier itself, so its own
  shortcuts stay out of the way.
- **Per-device pointer speed and acceleration**, including fully linear tracking.
- **Button remapping** for ordinary mouse buttons, with optional modifier keys —
  the same button can do one thing plain and another with ⌘ held.
- **Media and hardware keys as actions** — volume, mute, play/pause, track
  skipping and display brightness can all be bound to buttons and gestures.

- **Three-finger tap on the trackpad** — the built-in one or an external one.
  Tap with three fingers and get a middle click, or any other action from the
  list. Off by default; switch off Look Up under System Settings › Trackpad so
  the two do not fire together.

And the small things:

- **Battery level** in the menu and in the settings window, over HID++. Each
  device has a "Show charge in menu bar" checkbox; the ones you tick are shown
  next to the icon, so with a mouse and a keyboard you choose which to see.
- **A hideable menu bar icon** — untick "Show in menu bar" and LoLiMouse keeps
  working with no visible presence at all. Hiding it from System Settings or by
  ⌘-dragging it off does the same thing, never quits the app, and stays in sync
  with the checkbox.

## Where settings live

`~/Library/Application Support/LoLiMouse/config.json`

Devices are keyed by their HID++ unit ID, which identifies the individual mouse
rather than how it happens to be connected. Move it from a Bolt receiver to
Bluetooth and it keeps its settings.

The file is plain JSON and safe to edit by hand. A setting that is absent counts
as switched off, so the file only mentions what you actually turned on.

## Building from source

You need the Command Line Tools for Xcode (`xcode-select --install`) — a full
Xcode install is not required.

```sh
make install
```

That builds a release binary, packages it as `LoLiMouse.app`, signs it and
copies it to `/Applications`.

### Keeping permissions across rebuilds

macOS ties Accessibility and Input Monitoring grants to an app's code signature.
An ad-hoc signature changes on every build, so the system treats each rebuild as
a brand new app and asks for both permissions again.

The fix is a free self-signed certificate — no Apple Developer account involved:

1. Open **Keychain Access**.
2. **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name `LoLiMouse Self-Signed`, identity type **Self Signed Root**, certificate
   type **Code Signing**.
4. Build with it:

```sh
LOLIMOUSE_SIGN_IDENTITY='LoLiMouse Self-Signed' make install
```

`make signing-help` prints the same instructions.

### Other targets

```sh
make build        # compile only
make bundle       # build LoLiMouse.app into build/
make run          # build and launch
make test         # run the test suite
make release-zip  # what the release workflow publishes
make uninstall    # remove the app (settings are kept)
make clean
```

### Releases

Releases are built by GitHub Actions
([release.yml](.github/workflows/release.yml)): pushing a tag like `v0.1.0`
runs the tests, builds a universal (Apple Silicon + Intel) bundle with the tag
stamped in as the version, and attaches the zip to a GitHub release.

## Safety rules

An application that touches HID devices and the input event stream can take a
Mac down hard — not "crash and reopen" hard, but "the keyboard and trackpad stop
responding and the machine has to be restarted" hard. Three rules exist to
prevent that, and they are not negotiable:

1. **Never open a HID device we do not need to talk to.** A device this process
   holds open when it dies can stay seized by the kernel until the machine
   restarts. `IOHIDManagerOpen` is never called, because it opens *every*
   matched device at once. Only Logitech vendor-defined collections are ever
   opened, one at a time, and `HIDDevice.isOpenable` refuses everything else as
   a last line of defence.
2. **Never register a device matcher we do not need.** The HID manager matches
   Logitech devices only. Ordinary mice and trackpads are handled entirely
   through `IOHIDServiceClient`, which opens nothing.
3. **The event tap is installed only while it has work to do.** An active tap at
   `kCGHIDEventTap` sits in front of every input event on the machine. With no
   scrolling or button settings switched on, LoLiMouse installs no tap at all,
   and it asks for only the event types it actually acts on — three, plus
   modifier-key changes only while a pinch-zoom action is configured.

Teardown is bounded for the same reason: restoring settings at quit talks to a
device that may be asleep, and hanging in `applicationWillTerminate` is how an
app gets killed halfway through cleanup.

## Architecture

| Module | Responsibility |
|---|---|
| `IOKitSPI` | The handful of private IOKit and CoreGraphics declarations Apple ships as symbols but not headers. Deliberately tiny — everything with a public equivalent uses that instead. |
| `HIDKit` | Device discovery through `IOHIDManager`, synchronous HID report transactions, and per-device pointer tuning via `IOHIDServiceClient`. |
| `HIDPP` | The Logitech HID++ 1.0 / 2.0 stack: framing, feature resolution, receiver slots, and typed wrappers for the features used here. |
| `LoLiCore` | Configuration, the device registry, the hardware reconciler, and the CGEvent pipeline. |
| `LoLiMouseApp` | The application: an AppKit lifecycle (deliberately — SwiftUI scenes tie the app's lifetime to its windows and menu bar icon) hosting SwiftUI views. |

Two pieces are worth reading if you want to understand the design:

- `Sources/LoLiCore/Config/Setting.swift` — the type that makes every feature
  independently switchable, and the restore-on-disable promise that follows.
- `Sources/LoLiCore/Reconcile/HardwareReconciler.swift` — reapplication on
  reconnect, the confirming second write, retry backoff, and the baselines that
  make switching a setting off put things back.

## Testing

```sh
make test
```

The suite is a plain executable rather than an XCTest bundle, because both
XCTest and swift-testing ship inside Xcode and this project is built to need
only the Command Line Tools.

## Licence and credit

MIT. See [LICENSE](LICENSE).

This is an independent project, not a fork. Protocol details and several
hard-won implementation techniques were learned by reading two excellent open
source projects, both of which deserve your support:

- [LinearMouse](https://github.com/linearmouse/linearmouse) (MIT) — the multiple
  representations inside a scroll event, the high-resolution wheel accumulator,
  and the discipline of a dedicated event thread with a watchdog.
- [OpenLogi](https://github.com/AprilNEA/OpenLogi) (MIT / Apache-2.0) — the
  HID++ feature catalogue, and the insight that volatile settings need
  reapplying with a confirming second write.
