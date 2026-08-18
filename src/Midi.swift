import Foundation
import CoreMIDI
import AppKit

// MARK: - Sources

struct MidiSource: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
}

enum MidiQuery {
    static func sources() -> [MidiSource] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let ref = MIDIGetSource(i)
            guard ref != 0 else { return nil }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid)
            var cf: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &cf)
            let name = cf?.takeRetainedValue() as String? ?? "MIDI \(i + 1)"
            return MidiSource(id: uid, name: name)
        }
    }

    /// CoreMIDI composes an endpoint's display name from its parent device's
    /// name plus its own. Setting only the endpoint therefore APPENDS -- an
    /// "Amphonix 2" renamed to "Keys" reads as "Amphonix 2 Keys". Both have to
    /// be set for the name to replace rather than extend.
    ///
    /// kMIDIPropertyDisplayName itself is read-only; writing it returns -50.
    static func names(of uid: MIDIUniqueID) -> (endpoint: String, device: String?)? {
        guard let ep = endpoint(for: uid) else { return nil }
        func str(_ o: MIDIObjectRef) -> String? {
            var cf: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(o, kMIDIPropertyName, &cf) == noErr,
                  let v = cf else { return nil }
            return v.takeRetainedValue() as String
        }
        var entity = MIDIEntityRef(); MIDIEndpointGetEntity(ep, &entity)
        var device = MIDIDeviceRef(); if entity != 0 { MIDIEntityGetDevice(entity, &device) }
        guard let epName = str(ep) else { return nil }
        return (epName, device != 0 ? str(device) : nil)
    }

    /// System-wide and persistent: every app sees this name, and CoreMIDI keeps
    /// it across reboots.
    @discardableResult
    static func rename(uid: MIDIUniqueID, endpointName: String, deviceName: String?) -> Bool {
        guard let ep = endpoint(for: uid) else { return false }
        var entity = MIDIEntityRef(); MIDIEndpointGetEntity(ep, &entity)
        var device = MIDIDeviceRef(); if entity != 0 { MIDIEntityGetDevice(entity, &device) }
        if device != 0, let dn = deviceName {
            MIDIObjectSetStringProperty(device, kMIDIPropertyName, dn as CFString)
        }
        return MIDIObjectSetStringProperty(ep, kMIDIPropertyName, endpointName as CFString) == noErr
    }

    @discardableResult
    static func rename(uid: MIDIUniqueID, to name: String) -> Bool {
        rename(uid: uid, endpointName: name, deviceName: name)
    }

    static func name(of uid: MIDIUniqueID) -> String? {
        guard let ep = endpoint(for: uid) else { return nil }
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf) == noErr,
              let v = cf else { return nil }
        return v.takeRetainedValue() as String
    }

    static func endpoint(for uid: MIDIUniqueID) -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfSources() {
            let ref = MIDIGetSource(i)
            var u: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &u)
            if u == uid { return ref }
        }
        return nil
    }
}

// MARK: - Hardware input

/// Receives from CoreMIDI and hands raw status/data bytes to a callback.
///
/// Uses the UMP (MIDI 2.0 packet) API requesting the 1.0 protocol, so CoreMIDI
/// translates legacy devices for us and we parse exactly one packet shape
/// rather than walking a variable-length MIDIPacketList.
final class MidiReceiver {
    private var client = MIDIClientRef()
    private var port   = MIDIPortRef()
    private var connected: MIDIEndpointRef?
    private let onEvent: (UInt8, UInt8, UInt8) -> Void

    init(onEvent: @escaping (UInt8, UInt8, UInt8) -> Void) {
        self.onEvent = onEvent
        MIDIClientCreateWithBlock("MacAmp" as CFString, &client) { _ in }
        MIDIInputPortCreateWithProtocol(client, "MacAmp In" as CFString, ._1_0, &port) {
            [weak self] evtList, _ in
            guard let self else { return }
            let list = evtList.pointee
            var packet = list.packet
            for _ in 0..<list.numPackets {
                withUnsafeBytes(of: packet.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for w in 0..<Int(packet.wordCount) where w < words.count {
                        let word = words[w]
                        // Message type 2 = MIDI 1.0 channel voice.
                        guard (word >> 28) & 0xF == 2 else { continue }
                        let status = UInt8((word >> 16) & 0xFF)
                        let d1     = UInt8((word >> 8)  & 0x7F)
                        let d2     = UInt8(word         & 0x7F)
                        self.onEvent(status, d1, d2)
                    }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }
    }

    func connect(uid: MIDIUniqueID?) {
        if let c = connected { MIDIPortDisconnectSource(port, c); connected = nil }
        guard let uid, let ep = MidiQuery.endpoint(for: uid) else { return }
        if MIDIPortConnectSource(port, ep, nil) == noErr { connected = ep }
    }

    deinit {
        if let c = connected { MIDIPortDisconnectSource(port, c) }
        if port != 0   { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }
}

// MARK: - Computer keyboard

/// Maps the Mac keyboard to notes, in the layout people already know from
/// GarageBand: the home row is white keys, the row above is the black keys.
/// Z and X shift octave.
final class KeyboardMidi {
    /// keyCode -> semitone offset from the octave's C.
    private static let layout: [UInt16: Int] = [
        0: 0,   // A  -> C
        13: 1,  // W  -> C#
        1: 2,   // S  -> D
        14: 3,  // E  -> D#
        2: 4,   // D  -> E
        3: 5,   // F  -> F
        17: 6,  // T  -> F#
        5: 7,   // G  -> G
        16: 8,  // Y  -> G#
        4: 9,   // H  -> A
        32: 10, // U  -> A#
        38: 11, // J  -> B
        40: 12, // K  -> C
        31: 13, // O  -> C#
        37: 14, // L  -> D
        35: 15, // P  -> D#
        41: 16  // ;  -> E
    ]
    private static let octaveDown: UInt16 = 6   // Z
    private static let octaveUp:   UInt16 = 7   // X

    private var monitor: Any?
    private var held = Set<UInt16>()
    var octave = 4 { didSet { octave = max(0, min(8, octave)) } }
    var velocity: UInt8 = 96
    var onOctaveChange: ((Int) -> Void)?

    private let onEvent: (UInt8, UInt8, UInt8) -> Void
    init(onEvent: @escaping (UInt8, UInt8, UInt8) -> Void) { self.onEvent = onEvent }

    var isEnabled: Bool { monitor != nil }

    func enable() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard let self else { return ev }
            // Never swallow shortcuts.
            if ev.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return ev }

            if ev.keyCode == Self.octaveDown || ev.keyCode == Self.octaveUp {
                if ev.type == .keyDown && !ev.isARepeat {
                    self.allNotesOff()
                    self.octave += (ev.keyCode == Self.octaveUp ? 1 : -1)
                    self.onOctaveChange?(self.octave)
                }
                return nil
            }
            guard let semitone = Self.layout[ev.keyCode] else { return ev }

            let note = UInt8(max(0, min(127, (self.octave + 1) * 12 + semitone)))
            if ev.type == .keyDown {
                // Key repeat would otherwise retrigger the note dozens of times.
                guard !ev.isARepeat, !self.held.contains(ev.keyCode) else { return nil }
                self.held.insert(ev.keyCode)
                self.onEvent(0x90, note, self.velocity)
            } else {
                guard self.held.remove(ev.keyCode) != nil else { return nil }
                self.onEvent(0x80, note, 0)
            }
            return nil
        }
    }

    func disable() {
        allNotesOff()
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// Releasing keys while the window is not key would otherwise strand
    /// note-ons, leaving a note sounding forever.
    func allNotesOff() {
        for key in held {
            if let semitone = Self.layout[key] {
                let note = UInt8(max(0, min(127, (octave + 1) * 12 + semitone)))
                onEvent(0x80, note, 0)
            }
        }
        held.removeAll()
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

/// The 16 General MIDI families, one representative program each -- the full
/// 128 is a scrolling list nobody reads.
let GM_INSTRUMENTS: [(name: String, program: UInt8)] = [
    ("Grand Piano", 0),     ("Electric Piano", 4),  ("Harpsichord", 6),
    ("Vibraphone", 11),     ("Church Organ", 19),   ("Drawbar Organ", 16),
    ("Nylon Guitar", 24),   ("Clean Electric", 27), ("Overdriven Guitar", 29),
    ("Fingered Bass", 33),  ("Synth Bass", 38),     ("Strings", 48),
    ("Choir Aahs", 52),     ("Trumpet", 56),        ("Tenor Sax", 66),
    ("Square Lead", 80),    ("Saw Lead", 81),       ("Warm Pad", 89)
]
