// MIT License
// Copyright (c) 2026 LoLiMouse contributors

/// Which device object each key's subscription was actually made for.
///
/// Keyed by the stable device key, because that is what the rest of the app
/// asks in (`detach(_:)`, `retain(_:)`), but every entry also remembers the
/// identity of the `ManagedDevice` it was made for. That second half is the
/// point: a rescan builds *fresh* `ManagedDevice` objects for the same mice,
/// so a table keyed by the stable key alone would report "already attached"
/// while holding a subscription whose closure refers to an object nobody owns
/// any more — notifications keep arriving and are silently dropped.
///
/// Generic over the observation so the bookkeeping can be tested on its own:
/// nothing here opens, closes or talks to a device. Cancelling is the caller's
/// job — the removed observations are handed back rather than released, so the
/// caller can cancel them outside its lock.
package struct AttachmentTable<Observation> {
    private struct Entry {
        let device: ObjectIdentifier
        let observation: Observation
    }

    private var entries: [String: Entry] = [:]

    package init() {}

    package var isEmpty: Bool { entries.isEmpty }

    /// Whether `key` is already subscribed *on this very object*.
    package func holds(key: String, device: ObjectIdentifier) -> Bool {
        entries[key]?.device == device
    }

    /// Records a subscription, returning the one it displaced, if any.
    package mutating func insert(
        key: String,
        device: ObjectIdentifier,
        observation: Observation
    ) -> Observation? {
        let replaced = entries[key]?.observation
        entries[key] = Entry(device: device, observation: observation)
        return replaced
    }

    package mutating func remove(key: String) -> Observation? {
        entries.removeValue(forKey: key)?.observation
    }

    package mutating func removeAll() -> [Observation] {
        let removed = entries.values.map(\.observation)
        entries.removeAll()
        return removed
    }

    /// Drops every entry whose key is not in `keys`.
    package mutating func removeAll(except keys: Set<String>) -> [Observation] {
        let stale = entries.keys.filter { !keys.contains($0) }
        return stale.compactMap { entries.removeValue(forKey: $0)?.observation }
    }
}
