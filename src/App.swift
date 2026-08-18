import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

let BUS_NAMES = ["A", "B", "C", "D"]

// MARK: - Model

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
        var meterL: Double = 0
        var meterR: Double = 0
        var error: String = ""
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
    @Published var permissionDenied = false

    private let engine: OpaquePointer? = macamp_create()
    private let watcher = DeviceChangeWatcher()
    private var meterTimer: Timer?

    init() {
        refreshDevices()
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
        restoreIfNeeded()
    }

    /// Output candidates for a bus: everything except devices currently in use
    /// as an input, since routing a device into itself is a self-loop.
    func outputCandidates() -> [AudioDevice] {
        let usedAsInput = Set(strips.map(\.deviceUID).filter { !$0.isEmpty })
        return outputs.filter { !usedAsInput.contains($0.uid) }
    }

    /// Input candidates for a strip: exclude devices already used by another
    /// strip, and anything serving as an output bus.
    func inputCandidates(for slot: Int) -> [AudioDevice] {
        let takenByOtherStrip = Set(strips.enumerated()
            .filter { $0.offset != slot }.map { $0.element.deviceUID }.filter { !$0.isEmpty })
        let usedAsOutput = Set(buses.map(\.deviceUID).filter { !$0.isEmpty })
        return inputs.filter { !takenByOtherStrip.contains($0.uid) && !usedAsOutput.contains($0.uid) }
    }

    // MARK: Engine wiring

    func setInput(_ slot: Int, uid: String) {
        strips[slot].deviceUID = uid
        strips[slot].error = ""
        guard let engine else { return }

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

    private func pollMeters() {
        guard let engine else { return }
        for i in 0..<4 {
            var l: Float = 0, r: Float = 0
            macamp_read_peaks(engine, Int32(i), &l, &r)
            // Instant attack, exponential release -- a peak must never be
            // missed, but the bar should fall smoothly rather than flicker.
            strips[i].meterL = max(Double(l), strips[i].meterL * 0.82)
            strips[i].meterR = max(Double(r), strips[i].meterR * 0.82)
        }
        for b in 0..<4 where macamp_output_active(engine, Int32(b)) != 0 {
            let ms = macamp_latency_ms(engine, Int32(b))
            let un = macamp_underruns(engine, Int32(b))
            let sr = macamp_output_rate(engine, Int32(b))
            var d = String(format: "%.1f kHz · %.0f ms", sr / 1000, ms)
            if un > 0 { d += " · \(un) dropout\(un == 1 ? "" : "s")" }
            buses[b].detail = d
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
            if !uid.isEmpty, inputs.contains(where: { $0.uid == uid }) { setInput(i, uid: uid) }
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

// MARK: - Meter

struct Meter: View {
    var level: Double            // 0..1 linear peak

    // Linear peak is nearly useless to read; audio lives in the top few dB.
    private var scaled: Double {
        guard level > 0.0001 else { return 0 }
        let db = 20 * log10(level)
        return max(0, min(1, (db + 60) / 60))     // -60 dBFS .. 0 dBFS
    }

    private var tint: Color {
        if level >= 0.99 { return .red }
        if scaled > 0.85 { return .orange }
        return .green
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.09))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * scaled))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Input strip

struct StripView: View {
    @ObservedObject var model: MixerModel
    let index: Int

    private var strip: MixerModel.Strip { model.strips[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("INPUT \(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                if strip.gate && !strip.deviceUID.isEmpty {
                    Text(model.strips[index].meterL > 0.001 ? "GATE OPEN" : "GATE SHUT")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Picker("", selection: Binding(
                get: { strip.deviceUID },
                set: { model.setInput(index, uid: $0) })) {
                Text("None").tag("")
                ForEach(model.inputCandidates(for: index)) { d in Text(d.name).tag(d.uid) }
            }
            .labelsHidden().pickerStyle(.menu)

            VStack(spacing: 2) {
                Meter(level: strip.meterL)
                Meter(level: strip.meterR)
            }
            .opacity(strip.deviceUID.isEmpty ? 0.25 : 1)

            HStack(spacing: 10) {
                Text("Gain").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { strip.gain },
                    set: { model.strips[index].gain = $0; model.pushStrip(index) }),
                    in: 0...2)
                Text(String(format: "%+.0f dB", 20 * log10(max(strip.gain, 0.001))))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text("Pan").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { strip.pan },
                    set: { model.strips[index].pan = $0; model.pushStrip(index) }),
                    in: -1...1)
                Text(panLabel).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 6) {
                toggle("Mute", on: strip.mute, tint: .red) {
                    model.strips[index].mute.toggle(); model.pushStrip(index)
                }
                toggle("Solo", on: strip.solo, tint: .yellow) {
                    model.strips[index].solo.toggle(); model.pushStrip(index)
                }
                toggle("Gate", on: strip.gate, tint: .blue) {
                    model.strips[index].gate.toggle(); model.pushStrip(index)
                }
                Spacer()
                ForEach(0..<4, id: \.self) { b in
                    toggle(BUS_NAMES[b], on: strip.routes[b], tint: .accentColor, compact: true) {
                        model.strips[index].routes[b].toggle(); model.pushStrip(index)
                    }
                    .disabled(model.buses[b].deviceUID.isEmpty)
                    .opacity(model.buses[b].deviceUID.isEmpty ? 0.3 : 1)
                }
            }

            if strip.gate {
                HStack(spacing: 10) {
                    Text("Thresh").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { strip.gateThreshold },
                        set: { model.strips[index].gateThreshold = $0; model.pushStrip(index) }),
                        in: -80 ... -10)
                    Text(String(format: "%.0f dB", strip.gateThreshold))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                }
            }

            if !strip.error.isEmpty {
                Text(strip.error).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var panLabel: String {
        let p = strip.pan
        if abs(p) < 0.02 { return "C" }
        return String(format: "%@%.0f", p < 0 ? "L" : "R", abs(p) * 100)
    }

    private func toggle(_ label: String, on: Bool, tint: Color,
                        compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: compact ? 22 : 38, height: 19)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(on ? tint.opacity(0.85) : Color.primary.opacity(0.07)))
                .foregroundStyle(on ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { StripView(model: model, index: $0) }
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 10) {
                Text("OUTPUTS").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)

                ForEach(0..<4, id: \.self) { b in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(BUS_NAMES[b])
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(model.buses[b].deviceUID.isEmpty
                                          ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.85)))
                                .foregroundStyle(model.buses[b].deviceUID.isEmpty ? Color.secondary : .white)
                            Picker("", selection: Binding(
                                get: { model.buses[b].deviceUID },
                                set: { model.setOutput(b, uid: $0) })) {
                                Text("None").tag("")
                                ForEach(model.outputCandidates()) { d in Text(d.name).tag(d.uid) }
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        if !model.buses[b].detail.isEmpty && !model.buses[b].deviceUID.isEmpty {
                            Text(model.buses[b].detail)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if !model.buses[b].error.isEmpty {
                            Text(model.buses[b].error).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
                }

                if model.permissionDenied {
                    Text("Microphone access denied. Enable MacAmp in System Settings > Privacy & Security > Microphone.")
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .frame(width: 250)
        }
        .padding(16)
    }
}

@main
struct MacAmpApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        Window("MacAmp", id: "main") {
            ContentView(model: model)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .windowResizability(.contentSize)
    }
}
