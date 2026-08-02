//
//  IOKitSPI.h
//  LoLiMouse
//
//  Declarations for a handful of IOKit / CoreGraphics symbols that macOS
//  exports but does not publish headers for. Everything that *does* have a
//  public API (IOHIDManager, IOHIDDevice, IOHIDServiceClient,
//  IOHIDEventSystemClient) is used through its public header instead, so this
//  file stays as small as possible.
//
//  The only genuinely private surface we depend on is the IOHIDEvent accessor
//  family, which is required for two things no public API offers:
//
//    1. Attributing a CGEvent to the physical device that produced it
//       (CGEventCopyIOHIDEvent + IOHIDEventGetSenderID).
//    2. Reading and writing the high-resolution scroll deltas that Logitech
//       wheels report, which live in the IOHIDEvent rather than the CGEvent
//       (IOHIDEventGetFloatValue / IOHIDEventSetFloatValue).
//
//  MIT License.
//

#ifndef LOLIMOUSE_IOKITSPI_H
#define LOLIMOUSE_IOKITSPI_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

typedef CFTypeRef IOHIDEventRef;
typedef uint32_t LoLiIOHIDEventType;
typedef uint32_t LoLiIOHIDEventField;
typedef uint64_t LoLiIOHIDEventSenderID;

#ifdef __LP64__
typedef double LoLiIOHIDFloat;
#else
typedef float LoLiIOHIDFloat;
#endif

enum {
    kLoLiIOHIDEventTypeNULL = 0,
    kLoLiIOHIDEventTypeVendorDefined = 1,
    kLoLiIOHIDEventTypeKeyboard = 3,
    kLoLiIOHIDEventTypeRotation = 5,
    kLoLiIOHIDEventTypeScroll = 6,
    kLoLiIOHIDEventTypePointer = 7,
    kLoLiIOHIDEventTypeZoom = 8,
    kLoLiIOHIDEventTypeDigitizer = 11,
    kLoLiIOHIDEventTypeNavigationSwipe = 16,
};

#define LoLiIOHIDEventFieldBase(type) ((type) << 16)

/// Scroll axes, in wheel "units" rather than points.
///
/// The order is X, then Y — the same as every other axis triplet in
/// IOHIDEventTypes.h. Getting these two swapped once turned the thumbwheel
/// into a vertical scroller: the pipeline read the sideways movement as
/// vertical, quantised it, and wrote it onto the Y axis.
static const LoLiIOHIDEventField kLoLiIOHIDEventFieldScrollX =
    LoLiIOHIDEventFieldBase(kLoLiIOHIDEventTypeScroll) | 0;
static const LoLiIOHIDEventField kLoLiIOHIDEventFieldScrollY =
    LoLiIOHIDEventFieldBase(kLoLiIOHIDEventTypeScroll) | 1;

/// The IOHIDEvent backing a CGEvent, or NULL for a synthesised event.
extern IOHIDEventRef _Nullable CGEventCopyIOHIDEvent(CGEventRef event);

extern LoLiIOHIDEventType IOHIDEventGetType(IOHIDEventRef event);

/// The IOService registry ID of the device that produced the event. Matches
/// the value returned by `IOHIDServiceClientGetRegistryID`.
extern LoLiIOHIDEventSenderID IOHIDEventGetSenderID(IOHIDEventRef event);

extern LoLiIOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, LoLiIOHIDEventField field);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, LoLiIOHIDEventField field, LoLiIOHIDFloat value);

/// Asks the Dock to run one of its window-management effects. This is how
/// Mission Control, Launchpad and Show Desktop are triggered reliably; sending
/// their keyboard shortcuts instead breaks as soon as the user rebinds them.
///
/// Known notification names:
///   com.apple.expose.awake          — Mission Control
///   com.apple.expose.front.awake    — Application Windows
///   com.apple.showdesktop.awake     — Show Desktop
///   com.apple.launchpad.toggle      — Launchpad
extern CGError CoreDockSendNotification(CFStringRef notification, int unused);

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED

#endif /* LOLIMOUSE_IOKITSPI_H */
