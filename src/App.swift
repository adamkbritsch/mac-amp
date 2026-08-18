import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import CoreMIDI

let BUS_NAMES = ["A", "B", "C", "D"]

/// Selecting this in an input picker turns the strip into a MIDI instrument
/// rather than binding it to a capture device.
let MIDI_UID = "__macamp_midi__"

// MARK: - Model

/// Meter levels update 30 times a second. They are deliberately NOT stored on
/// MixerModel: mutating a @Published property there invalidates every view
/// observing the model, so the pickers, buttons and bus panels would all be
/// rebuilt on every tick. Profiling showed that costing ~66% CPU. Keeping the
/// fast-changing state on its own object means only the meter views redraw.
@MainActor
final class Meters: ObservableObject {
    @Published var level = [Double](repeating: 0, count: 8)   // L,R interleaved per strip
    func l(_ i: Int) -> Double { level[i * 2] }
    func r(_ i: Int) -> Double { level[i * 2 + 1] }
}

@MainActor
final class MixerModel: ObservableObject {

    struct Strip: Identifiable {
        let id: Int
        var deviceUID: String = ""
        var gain: Double = 1.0
        var pan: Double = 0.0
        var mute = false
        var solo = false
        var gate = false
        var gateThreshold: Double = -50
        var routes: [Bool] = [false, false, false, false]
        var error: String = ""

        // MIDI instrument strips
        var isMidi = false
        var midiSourceUID: MIDIUniqueID = 0
        var program: UInt8 = 0
        var keyboard = false
        var octave = 4
        var notes = 0
    }

    struct Bus: Identifiable {
        let id: Int
        var deviceUID: String = ""
        var error: String = ""
        var detail: String = ""
    }

    @Published var strips: [Strip] = (0..<4).map { Strip(id: $0) }
    @Published var buses:  [Bus]   = (0..<4).map { Bus(id: $0) }
    @Published var inputs:  [AudioDevice] = []
    @Published var outputs: [AudioDevice] = []
    @Published var midiSources: [MidiSource] = []
    /// The factory name of any endpoint we have renamed. Renaming is written
    /// into CoreMIDI and is system-wide and persistent; it cannot be undone by
    /// asking the OS, so the original is recorded here the first time a device
    /// is renamed and is what Restore writes back.
    /// [endpointName, deviceName] as found before the first rename. Both are
    /// needed: restoring only the endpoint would leave the device renamed, and
    /// the display name is composed from the pair.
    @Published var midiOriginalNames: [MIDIUniqueID: [String]] = [:]
    @Published var permissionDenied = false

    private let engine: OpaquePointer? = macamp_create()
    private let watcher = DeviceChangeWatcher()
    private let outputGuard = DefaultOutputGuard()
    @Published var revertedNotice: String = ""
    private var meterTimer: Timer?
    let meters = Meters()
    private var meterTick = 0
    private var receivers: [MidiReceiver?] = [nil, nil, nil, nil]
    private var keyboardMidi: KeyboardMidi?
    private var keyboardSlot: Int?

    init() {
        restoreAliases()
        refreshDevices()

        // Keep macOS from handing system audio to an instrument we are capturing.
        outputGuard.isCaptureDevice = { [weak self] id in
            guard let self else { return false }
            return self.strips.contains { s in
                !s.isMidi && !s.deviceUID.isEmpty
                    && self.inputs.first(where: { $0.uid == s.deviceUID })?.id == id
            }
        }
        outputGuard.onReverted = { [weak self] name in
            Task { @MainActor in
                self?.revertedNotice = "System output was switched to \(name); put back."
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.revertedNotice = ""
            }
        }
        outputGuard.start()
        watcher.start { [weak self] in self?.refreshDevices() }
        // 30 Hz: fast enough that a meter reads as continuous, slow enough to
        // stay off the audio threads' backs.
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
    }

    deinit { macamp_destroy(engine) }

    // MARK: Permission

    func requestPermission(_ then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: then()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    if ok { then() } else { self.permissionDenied = true }
                }
            }
        default: permissionDenied = true
        }
    }

    // MARK: Devices

    func refreshDevices() {
        inputs  = DeviceQuery.inputs()
        outputs = DeviceQuery.outputs()
        midiSources = MidiQuery.sources()
        restoreIfNeeded()
    }

    /// Every output device, including ones also serving as an input.
    ///
    /// A bidirectional interface's USB playback lands on its own aux/headphone
    /// jack, which is a real destination: send a microphone or a MIDI
    /// instrument there and you hear it in the headphones plugged into the amp.
    func outputCandidates() -> [AudioDevice] { outputs }

    /// True when this device is also feeding one of the input strips.
    func isAlsoAnInput(_ uid: String) -> Bool {
        strips.contains { $0.deviceUID == uid && !$0.isMidi }
    }

    /// Names a bus destination, marking the case where playback returns to a
    /// device we are also capturing from.
    func outputLabel(_ d: AudioDevice) -> String {
        isAlsoAnInput(d.uid) ? "\(d.name) — aux out" : d.name
    }

    /// Sending a strip back to the very device it is captured from means hearing
    /// it twice: once direct in the hardware, once round-tripped through the
    /// Mac a few milliseconds later. Worth flagging rather than preventing --
    /// it is exactly what you want for a *different* source.
    func echoWarning(_ slot: Int) -> String? {
        let s = strips[slot]
        guard !s.isMidi, !s.deviceUID.isEmpty else { return nil }
        for b in 0..<4 where s.routes[b] && buses[b].deviceUID == s.deviceUID {
            return "Routed back to its own aux out — you will hear it twice."
        }
        return nil
    }

    /// Input candidates for a strip: only exclude devices another strip already
    /// holds. A device serving as an output bus is still a valid input -- that
    /// is the whole point of a bidirectional interface.
    func inputCandidates(for slot: Int) -> [AudioDevice] {
        let takenByOtherStrip = Set(strips.enumerated()
            .filter { $0.offset != slot }.map { $0.element.deviceUID }.filter { !$0.isEmpty })
        return inputs.filter { !takenByOtherStrip.contains($0.uid) }
    }

    // MARK: Engine wiring

    func setInput(_ slot: Int, uid: String) {
        strips[slot].deviceUID = uid
        strips[slot].error = ""
        guard let engine else { return }

        if uid != MIDI_UID { teardownMidi(slot) }

        if uid == MIDI_UID {
            strips[slot].isMidi = true
            var buf = [CChar](repeating: 0, count: 512)
            // 48 kHz internally; buses at other rates resample exactly as they
            // would for a hardware input.
            let rc = macamp_set_midi_input(engine, Int32(slot), 48000, &buf, 512)
            if rc != 0 {
                strips[slot].error = String(cString: buf)
            } else {
                macamp_midi_program(engine, Int32(slot), strips[slot].program)
                attachReceiver(slot)
                if strips[slot].keyboard { enableKeyboard(slot) }
            }
            pushStrip(slot); persist(); return
        }

        strips[slot].isMidi = false
        guard !uid.isEmpty, let dev = inputs.first(where: { $0.uid == uid }) else {
            macamp_clear_input(engine, Int32(slot)); persist(); return
        }
        requestPermission { [weak self] in
            guard let self, let engine = self.engine else { return }
            var buf = [CChar](repeating: 0, count: 512)
            let rc = macamp_set_input(engine, Int32(slot), dev.id, &buf, 512)
            if rc != 0 { self.strips[slot].error = String(cString: buf) }
            self.pushStrip(slot)
            self.persist()
        }
    }

    func setOutput(_ bus: Int, uid: String) {
        buses[bus].deviceUID = uid
        buses[bus].error = ""
        guard let engine else { return }

        guard !uid.isEmpty, let dev = outputs.first(where: { $0.uid == uid }) else {
            macamp_clear_output(engine, Int32(bus)); persist(); return
        }
        var buf = [CChar](repeating: 0, count: 512)
        let rc = macamp_set_output(engine, Int32(bus), dev.id, &buf, 512)
        if rc != 0 { buses[bus].error = String(cString: buf) }
        persist()
    }

    /// Pushes every live control for a strip down to the engine.
    func pushStrip(_ i: Int) {
        guard let engine else { return }
        let s = strips[i]
        macamp_set_gain(engine, Int32(i), Float(s.gain))
        macamp_set_pan (engine, Int32(i), Float(s.pan))
        macamp_set_mute(engine, Int32(i), s.mute ? 1 : 0)
        macamp_set_solo(engine, Int32(i), s.solo ? 1 : 0)
        macamp_set_gate(engine, Int32(i), s.gate ? 1 : 0, Float(s.gateThreshold))
        for b in 0..<4 { macamp_set_route(engine, Int32(i), Int32(b), s.routes[b] ? 1 : 0) }
        persist()
    }

    // MARK: MIDI

    func refreshMidiSources() { midiSources = MidiQuery.sources() }

    /// Names now come straight from CoreMIDI, since a rename is written there.
    func displayName(_ src: MidiSource) -> String { src.name }

    func displayName(forUID uid: MIDIUniqueID) -> String {
        midiSources.first(where: { $0.id == uid })?.name ?? "Unavailable"
    }

    /// System-wide: this is the name every other app will see too.
    func renameMidi(_ uid: MIDIUniqueID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, uid != 0 else { return }
        // Record the factory names once, before the first rename overwrites them.
        if midiOriginalNames[uid] == nil, let n = MidiQuery.names(of: uid) {
            midiOriginalNames[uid] = [n.endpoint, n.device ?? n.endpoint]
        }
        MidiQuery.rename(uid: uid, to: t)
        persistOriginals()
        refreshMidiSources()
    }

    var canRestore: (MIDIUniqueID) -> Bool { { self.midiOriginalNames[$0] != nil } }

    func restoreMidiName(_ uid: MIDIUniqueID) {
        guard let o = midiOriginalNames[uid], o.count == 2 else { return }
        MidiQuery.rename(uid: uid, endpointName: o[0], deviceName: o[1])
        midiOriginalNames.removeValue(forKey: uid)
        persistOriginals()
        refreshMidiSources()
    }

    func originalName(_ uid: MIDIUniqueID) -> String {
        midiOriginalNames[uid]?.first
            ?? midiSources.first(where: { $0.id == uid })?.name ?? "Unavailable"
    }

    private func persistOriginals() {
        let d = Dictionary(uniqueKeysWithValues: midiOriginalNames.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(d, forKey: "midiOriginalNames")
    }

    private func restoreAliases() {
        guard let raw = UserDefaults.standard.dictionary(forKey: "midiOriginalNames") as? [String: [String]] else { return }
        midiOriginalNames = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            v.count == 2 ? MIDIUniqueID(k).map { ($0, v) } : nil
        })
    }

    private func attachReceiver(_ slot: Int) {
        let uid = strips[slot].midiSourceUID
        if receivers[slot] == nil {
            receivers[slot] = MidiReceiver { [weak self] status, d1, d2 in
                // CoreMIDI delivers on its own thread; the engine call is
                // lock-free, but the @Published note count is main-actor state.
                guard let self else { return }
                if let e = self.engineRef { macamp_midi_event(e, Int32(slot), status, d1, d2) }
                Task { @MainActor in
                    self.strips[slot].notes = Int(macamp_midi_active_notes(self.engine, Int32(slot)))
                }
            }
        }
        receivers[slot]?.connect(uid: uid == 0 ? nil : uid)
    }

    private func teardownMidi(_ slot: Int) {
        receivers[slot]?.connect(uid: nil)
        receivers[slot] = nil
        if keyboardSlot == slot { disableKeyboard() }
        strips[slot].isMidi = false
        strips[slot].notes = 0
    }

    func setMidiSource(_ slot: Int, uid: MIDIUniqueID) {
        strips[slot].midiSourceUID = uid
        attachReceiver(slot)
        persist()
    }

    func setProgram(_ slot: Int, program: UInt8) {
        strips[slot].program = program
        if let engine { macamp_midi_program(engine, Int32(slot), program) }
        persist()
    }

    /// Only one strip can own the computer keyboard, or a single keypress
    /// would sound on several instruments at once.
    func enableKeyboard(_ slot: Int) {
        if let cur = keyboardSlot, cur != slot {
            strips[cur].keyboard = false
            keyboardMidi?.disable()
        }
        keyboardSlot = slot
        strips[slot].keyboard = true
        if keyboardMidi == nil {
            keyboardMidi = KeyboardMidi { [weak self] status, d1, d2 in
                guard let self, let s = self.keyboardSlot, let e = self.engineRef else { return }
                macamp_midi_event(e, Int32(s), status, d1, d2)
                Task { @MainActor in
                    self.strips[s].notes = Int(macamp_midi_active_notes(self.engine, Int32(s)))
                }
            }
        }
        keyboardMidi?.octave = strips[slot].octave
        keyboardMidi?.onOctaveChange = { [weak self] oct in
            Task { @MainActor in
                if let s = self?.keyboardSlot { self?.strips[s].octave = oct }
            }
        }
        keyboardMidi?.enable()
        persist()
    }

    func disableKeyboard() {
        if let s = keyboardSlot { strips[s].keyboard = false }
        keyboardMidi?.disable()
        keyboardSlot = nil
        persist()
    }

    // MARK: Whole-mixer actions (menu bar)

    func muteAll(_ on: Bool) {
        for i in 0..<4 where !strips[i].deviceUID.isEmpty {
            strips[i].mute = on
            pushStrip(i)
        }
    }

    func clearSolos() {
        for i in 0..<4 where strips[i].solo {
            strips[i].solo = false
            pushStrip(i)
        }
    }

    func panicAll() {
        for i in 0..<4 { panic(i) }
    }

    var anyMuted: Bool { strips.contains { !$0.deviceUID.isEmpty && $0.mute } }
    var anySoloed: Bool { strips.contains(where: \.solo) }
    var midiSlots: [Int] { (0..<4).filter { strips[$0].isMidi } }
    var assignedSlots: [Int] { (0..<4).filter { !strips[$0].deviceUID.isEmpty } }

    func toggleKeyboard() {
        if let cur = keyboardSlot { disableKeyboard(); _ = cur }
        else if let first = midiSlots.first { enableKeyboard(first) }
    }

    func shiftOctave(_ delta: Int) {
        guard let s = keyboardSlot else { return }
        panic(s)                      // release anything held at the old octave
        strips[s].octave = max(0, min(8, strips[s].octave + delta))
        keyboardMidi?.octave = strips[s].octave
        persist()
    }

    var keyboardActive: Bool { keyboardSlot != nil }

    func panic(_ slot: Int) {
        keyboardMidi?.allNotesOff()
        if let engine { macamp_midi_all_notes_off(engine, Int32(slot)) }
        strips[slot].notes = 0
    }

    /// The engine pointer, reachable from non-main threads.
    private var engineRef: OpaquePointer? { engine }

    private func pollMeters() {
        guard let engine else { return }

        // Build the whole array, then assign once: eight separate writes would
        // publish eight times.
        var next = meters.level
        var changed = false
        for i in 0..<4 {
            var l: Float = 0, r: Float = 0
            macamp_read_peaks(engine, Int32(i), &l, &r)
            // Instant attack, exponential release -- a peak must never be
            // missed, but the bar should fall smoothly rather than flicker.
            let nl = max(Double(l), next[i * 2]     * 0.82)
            let nr = max(Double(r), next[i * 2 + 1] * 0.82)
            // Below this the bar cannot move a visible pixel, so publishing it
            // would be pure invalidation for no visual change.
            if abs(nl - next[i * 2])     > 0.002 { next[i * 2]     = nl; changed = true }
            if abs(nr - next[i * 2 + 1]) > 0.002 { next[i * 2 + 1] = nr; changed = true }
        }
        if changed { meters.level = next }

        // Text readouts do not need 30 Hz; a quarter of a second is plenty and
        // each update rebuilds the bus panels.
        meterTick += 1
        guard meterTick % 8 == 0 else { return }
        for b in 0..<4 where macamp_output_active(engine, Int32(b)) != 0 {
            let ms = macamp_latency_ms(engine, Int32(b))
            let un = macamp_underruns(engine, Int32(b))
            let sr = macamp_output_rate(engine, Int32(b))
            var d = String(format: "%.1f kHz · %.0f ms", sr / 1000, ms)
            if un > 0 { d += " · \(un) dropout\(un == 1 ? "" : "s")" }
            if buses[b].detail != d { buses[b].detail = d }
        }
    }

    // MARK: Persistence  (by device UID -- AudioDeviceIDs are reassigned)

    private func persist() {
        let d = UserDefaults.standard
        for (i, s) in strips.enumerated() {
            d.set(s.deviceUID, forKey: "in\(i).uid")
            d.set(s.gain,      forKey: "in\(i).gain")
            d.set(s.pan,       forKey: "in\(i).pan")
            d.set(s.mute,      forKey: "in\(i).mute")
            d.set(s.gate,      forKey: "in\(i).gate")
            d.set(s.gateThreshold, forKey: "in\(i).gateT")
            d.set(s.routes.map { $0 ? 1 : 0 }, forKey: "in\(i).routes")
            d.set(Int(s.midiSourceUID), forKey: "in\(i).midiSrc")
            d.set(Int(s.program),       forKey: "in\(i).program")
            d.set(s.octave,             forKey: "in\(i).octave")
        }
        for (b, bus) in buses.enumerated() { d.set(bus.deviceUID, forKey: "out\(b).uid") }
    }

    private var restored = false
    private func restoreIfNeeded() {
        guard !restored else { return }
        restored = true
        let d = UserDefaults.standard

        for i in 0..<4 {
            strips[i].gain = d.object(forKey: "in\(i).gain") as? Double ?? 1.0
            strips[i].pan  = d.object(forKey: "in\(i).pan")  as? Double ?? 0.0
            strips[i].mute = d.bool(forKey: "in\(i).mute")
            strips[i].gate = d.bool(forKey: "in\(i).gate")
            strips[i].gateThreshold = d.object(forKey: "in\(i).gateT") as? Double ?? -50
            strips[i].midiSourceUID = MIDIUniqueID(d.integer(forKey: "in\(i).midiSrc"))
            strips[i].program       = UInt8(clamping: d.integer(forKey: "in\(i).program"))
            strips[i].octave        = d.object(forKey: "in\(i).octave") as? Int ?? 4
            if let r = d.array(forKey: "in\(i).routes") as? [Int], r.count == 4 {
                strips[i].routes = r.map { $0 != 0 }
            } else if i == 0 {
                strips[i].routes = [true, false, false, false]
            }
        }
        // Snapshot every saved UID BEFORE wiring anything up. setOutput and
        // setInput both call persist(), which would otherwise overwrite the
        // not-yet-read input keys with empty strings and defeat the defaults
        // below -- an empty string is not nil, so ?? would never fire.
        var savedIn  = (0..<4).map { d.string(forKey: "in\($0).uid")  ?? "" }
        let savedOut = (0..<4).map { d.string(forKey: "out\($0).uid") ?? "" }
        let firstRun = savedIn.allSatisfy(\.isEmpty) && savedOut.allSatisfy(\.isEmpty)
        if firstRun { savedIn[0] = likelyInstrument() }

        // Outputs first, so a bus exists for inputs to attach to.
        for b in 0..<4 {
            let uid = (firstRun && b == 0) ? defaultSpeakers() : savedOut[b]
            if !uid.isEmpty, outputs.contains(where: { $0.uid == uid }) { setOutput(b, uid: uid) }
        }
        for i in 0..<4 {
            let uid = savedIn[i]
            if uid == MIDI_UID { setInput(i, uid: uid) }
            else if !uid.isEmpty, inputs.contains(where: { $0.uid == uid }) { setInput(i, uid: uid) }
        }
    }

    /// A USB interface is a better first guess than the built-in mic, which is
    /// almost never what someone opens this app to listen to.
    private func likelyInstrument() -> String {
        if let amp = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("Amphonix") }) {
            return amp.uid
        }
        return inputs.first {
            !$0.name.localizedCaseInsensitiveContains("MacBook")
            && !$0.name.localizedCaseInsensitiveContains("AirPods")
            && !$0.name.localizedCaseInsensitiveContains("iPhone")
        }?.uid ?? ""
    }

    /// Built-in speakers rather than the system default: a virtual driver
    /// holding "default output" would otherwise swallow the signal.
    private func defaultSpeakers() -> String {
        outputs.first { $0.name.localizedCaseInsensitiveContains("MacBook Pro Speakers") }?.uid
            ?? outputs.first?.uid ?? ""
    }
}

// MARK: - Design system
//
// Every colour here is lifted from MacAmp.icon's own gradients, so the app and
// its Dock tile are visibly the same object. Two rules, borrowed as structure
// rather than style: state is carried by BRIGHTNESS, never by hue, and exactly
// one hue is reserved for genuine faults.

private func P3(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(.displayP3, red: r, green: g, blue: b)
}

enum DS {
    // Ground: the icon's backdrop, dark at the top and settling into violet at
    // the floor. Near-black so OLED panels actually switch pixels off.
    static let bgTop    = P3(0.055, 0.066, 0.070)
    static let bgMid    = P3(0.086, 0.082, 0.104)
    static let bgBottom = P3(0.166, 0.141, 0.183)

    // The icon's amp face: near-white lavender falling to periwinkle. This is
    // the app's whole identity, and it belongs to signal — meters, active
    // routing, anything currently carrying audio.
    static let glowLit  = P3(0.897, 0.905, 1.000)
    static let glow     = P3(0.640, 0.686, 0.930)
    static let glowDeep = P3(0.510, 0.547, 0.806)

    static let signal = LinearGradient(colors: [glowDeep, glow, glowLit],
                                       startPoint: .leading, endPoint: .trailing)
    static let wordmark = LinearGradient(colors: [glowLit, glowDeep],
                                         startPoint: .top, endPoint: .bottom)

    // Text ramp — one axis, brightness.
    static let textLit = P3(0.930, 0.930, 0.955)
    static let text    = P3(0.720, 0.725, 0.775)
    static let textDim = P3(0.475, 0.480, 0.535)

    // Surfaces. No left accent bars anywhere: a panel says "live" by getting
    // brighter, not by growing a coloured stripe.
    static let panel       = Color.white.opacity(0.038)
    static let panelLive   = Color.white.opacity(0.062)
    static let hairline    = Color.white.opacity(0.070)
    static let hairlineLit = Color.white.opacity(0.150)

    static let fault = P3(0.920, 0.380, 0.360)   // the one hue exception

    static let radius: CGFloat = 8
}

private struct Panel<Content: View>: View {
    var live = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(11)
            .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                .fill(live ? DS.panelLive : DS.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                .strokeBorder(live ? DS.hairlineLit : DS.hairline, lineWidth: 1))
    }
}

// MARK: - Meter

struct Meter: View {
    var level: Double

    /// Linear peak is unreadable — audio lives in the top few dB — so the bar
    /// is dBFS across the last 60.
    private var scaled: Double {
        guard level > 0.0001 else { return 0 }
        return max(0, min(1, (20 * log10(level) + 60) / 60))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.055))
                Capsule()
                    .fill(level >= 0.99 ? LinearGradient(colors: [DS.fault, DS.fault],
                                                         startPoint: .leading, endPoint: .trailing)
                                        : DS.signal)
                    .frame(width: max(0, geo.size.width * scaled))
                    .shadow(color: DS.glow.opacity(scaled > 0.02 ? 0.45 : 0), radius: 4)
            }
        }
        .frame(height: 5)
    }
}

/// Only these two views observe Meters, so a 30 Hz tick invalidates them and
/// nothing else.
struct StripMeters: View {
    @ObservedObject var meters: Meters
    let index: Int
    var body: some View {
        VStack(spacing: 3) {
            Meter(level: meters.l(index))
            Meter(level: meters.r(index))
        }
    }
}

struct GateLamp: View {
    @ObservedObject var meters: Meters
    let index: Int
    var body: some View {
        let open = meters.l(index) > 0.002
        Text(open ? "OPEN" : "SHUT")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(open ? DS.glow : DS.textDim)
    }
}

// MARK: - Controls

private struct StateButton: View {
    let label: String
    let on: Bool
    var compact = false
    var faultTint = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: compact ? 23 : 40, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? (faultTint ? DS.fault.opacity(0.85) : DS.glowDeep.opacity(0.95))
                             : Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(on ? Color.clear : DS.hairline, lineWidth: 1))
                .foregroundStyle(on ? (faultTint ? Color.white : DS.textLit) : DS.textDim)
        }
        .buttonStyle(.plain)
    }
}

private struct Row<Content: View>: View {
    let label: String
    let readout: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 9) {
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textDim).frame(width: 30, alignment: .leading)
            content
            Text(readout).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.text).frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Input strip

struct StripView: View {
    @ObservedObject var model: MixerModel
    let index: Int
    @State private var renaming = false
    @State private var draftName = ""
    private var strip: MixerModel.Strip { model.strips[index] }

    private func commitRename() {
        model.renameMidi(strip.midiSourceUID, to: draftName)
        renaming = false
    }
    private var live: Bool { !strip.deviceUID.isEmpty }

    var body: some View {
        Panel(live: live) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text("IN \(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(live ? DS.text : DS.textDim)
                    if live && strip.gate {
                        GateLamp(meters: model.meters, index: index)
                    }
                    Spacer()
                }

                Picker("", selection: Binding(
                    get: { strip.deviceUID },
                    set: { model.setInput(index, uid: $0) })) {
                    Text("None").tag("")
                    Divider()
                    ForEach(model.inputCandidates(for: index)) { d in Text(d.name).tag(d.uid) }
                    Divider()
                    Text("MIDI Instrument").tag(MIDI_UID)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)

                if strip.isMidi { midiControls }

                StripMeters(meters: model.meters, index: index)
                    .opacity(live ? 1 : 0.22)

                Row(label: "Gain", readout: String(format: "%+.0f dB", 20 * log10(max(strip.gain, 0.001)))) {
                    Slider(value: Binding(get: { strip.gain },
                        set: { model.strips[index].gain = $0; model.pushStrip(index) }), in: 0...2)
                        .controlSize(.mini).tint(DS.glowDeep)
                }
                Row(label: "Pan", readout: panLabel) {
                    Slider(value: Binding(get: { strip.pan },
                        set: { model.strips[index].pan = $0; model.pushStrip(index) }), in: -1...1)
                        .controlSize(.mini).tint(DS.glowDeep)
                }

                HStack(spacing: 5) {
                    StateButton(label: "Mute", on: strip.mute, faultTint: true) {
                        model.strips[index].mute.toggle(); model.pushStrip(index)
                    }
                    StateButton(label: "Solo", on: strip.solo) {
                        model.strips[index].solo.toggle(); model.pushStrip(index)
                    }
                    StateButton(label: "Gate", on: strip.gate) {
                        model.strips[index].gate.toggle(); model.pushStrip(index)
                    }
                    Spacer()
                    ForEach(0..<4, id: \.self) { b in
                        StateButton(label: BUS_NAMES[b], on: strip.routes[b], compact: true) {
                            model.strips[index].routes[b].toggle(); model.pushStrip(index)
                        }
                        .disabled(model.buses[b].deviceUID.isEmpty)
                        .opacity(model.buses[b].deviceUID.isEmpty ? 0.25 : 1)
                    }
                }

                if strip.gate {
                    Row(label: "Thr", readout: String(format: "%.0f dB", strip.gateThreshold)) {
                        Slider(value: Binding(get: { strip.gateThreshold },
                            set: { model.strips[index].gateThreshold = $0; model.pushStrip(index) }),
                            in: -80 ... -10).controlSize(.mini).tint(DS.glowDeep)
                    }
                }
                if !strip.error.isEmpty {
                    Text(strip.error).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.fault).fixedSize(horizontal: false, vertical: true)
                } else if let echo = model.echoWarning(index) {
                    Text(echo).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.glow).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var midiControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("SRC").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.textDim)
                Picker("", selection: Binding(
                    get: { strip.midiSourceUID },
                    set: { model.setMidiSource(index, uid: $0) })) {
                    Text("None").tag(MIDIUniqueID(0))
                    ForEach(model.midiSources) { src in Text(model.displayName(src)).tag(src.id) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.mini)

                if strip.midiSourceUID != 0 {
                    StateButton(label: renaming ? "Done" : "Name", on: renaming) {
                        if renaming { commitRename() }
                        else {
                            draftName = model.displayName(forUID: strip.midiSourceUID)
                            renaming = true
                        }
                    }
                }
            }

            if renaming && strip.midiSourceUID != 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField(model.originalName(strip.midiSourceUID), text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.mini)
                            .font(.system(size: 11))
                            .onSubmit { commitRename() }
                        if model.midiOriginalNames[strip.midiSourceUID] != nil {
                            StateButton(label: "Restore", on: false) {
                                model.restoreMidiName(strip.midiSourceUID)
                                renaming = false
                            }
                        }
                    }
                    Text("Renames the device for every app on this Mac.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DS.textDim)
                }
            }

            HStack(spacing: 6) {
                Text("INST").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.textDim)
                Picker("", selection: Binding(
                    get: { strip.program },
                    set: { model.setProgram(index, program: $0) })) {
                    ForEach(GM_INSTRUMENTS, id: \.program) { i in
                        Text(i.name).tag(i.program)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.mini)
            }

            HStack(spacing: 5) {
                StateButton(label: "Keys", on: strip.keyboard) {
                    if strip.keyboard { model.disableKeyboard() }
                    else { model.enableKeyboard(index) }
                }
                if strip.keyboard {
                    Text("OCT \(strip.octave)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.glow)
                    Text("Z / X")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DS.textDim)
                }
                Spacer()
                if strip.notes > 0 {
                    Text("\(strip.notes)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.glowLit)
                }
                StateButton(label: "Panic", on: false, faultTint: true) { model.panic(index) }
            }
        }
        .padding(.vertical, 2)
    }

    private var panLabel: String {
        let p = strip.pan
        if abs(p) < 0.02 { return "C" }
        return String(format: "%@%.0f", p < 0 ? "L" : "R", abs(p) * 100)
    }
}

// MARK: - Title bar geometry

/// The traffic lights and the wordmark have to agree about where the title bar
/// ends, so both read these instead of carrying their own magic numbers.
enum TitleBar {
    /// How far the window buttons are pushed down from the top.
    static let buttonDrop: CGFloat = 7

    /// Measured on screen, not assumed: with buttonDrop = 7 the close button's
    /// frame lands 8pt from the window top (AppKit adds one) and is 14pt tall,
    /// not the 12pt square it looks like. So its bottom edge sits here.
    static let buttonBottom: CGFloat = 8 + 14

    /// Requested gap between the bottom of the lights and the top of the title.
    static let gap: CGFloat = 2

    static let wordmarkSize: CGFloat = 18

    /// A Text view's top edge is NOT where its letters start. The font puts
    /// invisible leading above the cap height -- 4.52pt for SF 18pt bold -- so
    /// padding alone lands the glyphs that much too low. Measured from the real
    /// font metrics so it self-corrects if wordmarkSize changes.
    static var capInset: CGFloat {
        let f = NSFont.systemFont(ofSize: wordmarkSize, weight: .bold)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: f)
        let lead = lineHeight - (f.ascender - f.descender)
        return f.ascender - f.capHeight + lead
    }

    /// Where the Text VIEW must start for the GLYPHS to sit `gap` below the lights.
    static var titleTop: CGFloat { buttonBottom + gap - capInset }

    /// Visible space above the letters: window top to the top of the caps.
    static var aboveGlyph: CGFloat { buttonBottom + gap }

    /// "MacAmp" has no descenders, so the space between the baseline and the
    /// bottom of the Text view is invisible too, and has to be discounted when
    /// balancing -- otherwise the title reads as sitting high in its band.
    static var descenderInset: CGFloat {
        let f = NSFont.systemFont(ofSize: wordmarkSize, weight: .bold)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: f)
        return lineHeight - capInset - f.capHeight
    }

    /// Stack spacing that makes the visible gap BELOW the letters match the
    /// visible gap above them.
    static var belowTitle: CGFloat { aboveGlyph - descenderInset }
}

// MARK: - Traffic lights

/// Nudges the three window buttons down without touching anything else.
///
/// The usual trick for this is an empty NSTitlebarAccessoryViewController,
/// which makes the title bar taller and lets AppKit re-centre the buttons in
/// it -- but a taller title bar also insets the content, moving the whole
/// window's layout. Offsetting the buttons directly leaves the content exactly
/// where it is, which is the point.
///
/// AppKit restores the default frames on some relayouts, so this reapplies on
/// key/resize rather than setting it once.
struct TrafficLightOffset: NSViewRepresentable {
    let dy: CGFloat

    final class Coordinator {
        var dy: CGFloat = 0
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func apply(_ window: NSWindow?) {
            guard let window else { return }

            // The window is fixed-size (.windowResizability(.contentSize)), so
            // zoom has nothing to do. Hide it rather than leave a control that
            // does nothing when clicked.
            window.standardWindowButton(.zoomButton)?.isHidden = true

            for type in [NSWindow.ButtonType.closeButton,
                         .miniaturizeButton] {
                guard let button = window.standardWindowButton(type),
                      let container = button.superview else { continue }
                // Titlebar coords run bottom-up, so lowering the button means
                // a smaller y. Measured from the top so repeated calls are
                // idempotent rather than cumulative.
                let top = container.bounds.height - button.frame.height
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x,
                                              y: top - dy))
            }
        }

        func attach(to window: NSWindow?) {
            guard let window, observers.isEmpty else { apply(window); return }
            let nc = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification,
                         NSWindow.didResizeNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(nc.addObserver(forName: name, object: window,
                                                queue: .main) { [weak self] _ in
                    self?.apply(window)
                })
            }
            apply(window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.dy = dy
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.dy = dy
        DispatchQueue.main.async { context.coordinator.apply(v.window) }
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No title bar, so the traffic lights float directly over the
            // gradient. The wordmark is centred on the window rather than the
            // remaining space -- a ZStack, not an HStack with Spacers, so the
            // fault text appearing on the right cannot shove it off-centre.
            ZStack {
                Text("MacAmp")
                    .font(.system(size: TitleBar.wordmarkSize, weight: .bold))
                    .foregroundStyle(DS.wordmark)
                    .tracking(0.3)
                if model.permissionDenied {
                    HStack {
                        Spacer()
                        Text("MICROPHONE ACCESS DENIED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.fault)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, TitleBar.belowTitle)

            HStack(alignment: .top, spacing: 13) {
                VStack(spacing: 9) {
                    ForEach(0..<4, id: \.self) { StripView(model: model, index: $0) }
                }
                .frame(width: 358)

                VStack(alignment: .leading, spacing: 9) {
                    Text("OUTPUTS").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.textDim)

                    ForEach(0..<4, id: \.self) { b in
                        let on = !model.buses[b].deviceUID.isEmpty
                        Panel(live: on) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(BUS_NAMES[b])
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 18, height: 18)
                                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(on ? DS.glowDeep.opacity(0.95) : Color.white.opacity(0.055)))
                                        .foregroundStyle(on ? DS.textLit : DS.textDim)
                                    Picker("", selection: Binding(
                                        get: { model.buses[b].deviceUID },
                                        set: { model.setOutput(b, uid: $0) })) {
                                        Text("None").tag("")
                                        ForEach(model.outputCandidates()) { d in
                                            Text(model.outputLabel(d)).tag(d.uid)
                                        }
                                    }
                                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                }
                                if on && !model.buses[b].detail.isEmpty {
                                    Text(model.buses[b].detail)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(DS.textDim)
                                }
                                if !model.buses[b].error.isEmpty {
                                    Text(model.buses[b].error)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DS.fault)
                                        .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, TitleBar.belowTitle)
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .frame(width: 262)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, TitleBar.titleTop)
        // 358 (strips) + 262 (outputs) + 13 (gap) + 32 (padding). Pinned so the
        // header's unbounded Spacer cannot make the content width indeterminate
        // under .windowResizability(.contentSize).
        .frame(width: 665, alignment: .leading)
        .background(
            LinearGradient(colors: [DS.bgTop, DS.bgMid, DS.bgBottom],
                           startPoint: .top, endPoint: .bottom)
        )
        .background(TrafficLightOffset(dy: TitleBar.buttonDrop).frame(width: 0, height: 0))
        .preferredColorScheme(.dark)
    }
}

@main
struct MacAmpApp: App {
    @StateObject private var model = MixerModel()

    /// Names the strip by its device, so the menu reads "Mute Amphonix 2 Audio"
    /// rather than making you remember which number is which.
    private func muteLabel(_ i: Int) -> String {
        let s = model.strips[i]
        let name = s.isMidi ? "MIDI Instrument"
            : (model.inputs.first { $0.uid == s.deviceUID }?.name ?? "Input \(i + 1)")
        return (s.mute ? "Unmute " : "Mute ") + name
    }

    var body: some Scene {
        Window("MacAmp", id: "main") {
            ContentView(model: model)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // A single-window utility has no documents, so the default File
            // commands are all dead weight.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }

            CommandMenu("Mixer") {
                Button(model.anyMuted ? "Unmute All" : "Mute All") {
                    model.muteAll(!model.anyMuted)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                if model.anySoloed {
                    Button("Clear Solos") { model.clearSolos() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }

                Divider()

                // Only strips with something assigned. An entry for an empty
                // strip does nothing, so it should not be there at all.
                ForEach(model.assignedSlots, id: \.self) { i in
                    Button(muteLabel(i)) {
                        model.strips[i].mute.toggle()
                        model.pushStrip(i)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }

                if !model.assignedSlots.isEmpty { Divider() }

                Button("Refresh Devices") { model.refreshDevices() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Instrument") {
                if model.midiSlots.isEmpty {
                    // Nothing here applies without a MIDI strip. Say why rather
                    // than presenting a menu of greyed-out verbs.
                    Text("Set an input to MIDI Instrument to use these")
                } else {
                    Button(model.keyboardActive ? "Stop Musical Typing" : "Start Musical Typing") {
                        model.toggleKeyboard()
                    }
                    .keyboardShortcut("k", modifiers: .command)

                    // Octave only means something while the keyboard is live.
                    if model.keyboardActive {
                        Button("Octave Up")   { model.shiftOctave(1)  }
                            .keyboardShortcut("=", modifiers: .command)
                        Button("Octave Down") { model.shiftOctave(-1) }
                            .keyboardShortcut("-", modifiers: .command)
                    }

                    Divider()

                    // Worth a shortcut you can hit without looking: a stuck
                    // note-on does not stop on its own.
                    Button("Panic — All Notes Off") { model.panicAll() }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }

            CommandGroup(replacing: .help) {
                Button("MacAmp on GitHub") {
                    if let u = URL(string: "https://github.com/adamkbritsch/macamp") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }
}
