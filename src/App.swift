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
                .font(.system(size: 10, weight: .semibold))
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
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.textDim).frame(width: 30, alignment: .leading)
            content
            Text(readout).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.text).frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Input strip

struct StripView: View {
    @ObservedObject var model: MixerModel
    let index: Int
    private var strip: MixerModel.Strip { model.strips[index] }
    private var live: Bool { !strip.deviceUID.isEmpty }

    var body: some View {
        Panel(live: live) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text("IN \(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(live ? DS.text : DS.textDim)
                    if live && strip.gate {
                        Text(strip.meterL > 0.002 ? "OPEN" : "SHUT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(strip.meterL > 0.002 ? DS.glow : DS.textDim)
                    }
                    Spacer()
                }

                Picker("", selection: Binding(
                    get: { strip.deviceUID },
                    set: { model.setInput(index, uid: $0) })) {
                    Text("None").tag("")
                    ForEach(model.inputCandidates(for: index)) { d in Text(d.name).tag(d.uid) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)

                VStack(spacing: 3) {
                    Meter(level: strip.meterL)
                    Meter(level: strip.meterR)
                }
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
                    Text(strip.error).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.fault).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var panLabel: String {
        let p = strip.pan
        if abs(p) < 0.02 { return "C" }
        return String(format: "%@%.0f", p < 0 ? "L" : "R", abs(p) * 100)
    }
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
            for type in [NSWindow.ButtonType.closeButton,
                         .miniaturizeButton,
                         .zoomButton] {
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
        VStack(alignment: .leading, spacing: 13) {
            // No title bar, so the traffic lights float directly over the
            // gradient. The wordmark is centred on the window rather than the
            // remaining space -- a ZStack, not an HStack with Spacers, so the
            // fault text appearing on the right cannot shove it off-centre.
            ZStack {
                // Concatenated Text runs, so "Amp" carries its own italic while
                // the gradient still sweeps across the wordmark as one object.
                (Text("Mac").font(.system(size: 18, weight: .semibold))
                 + Text("Amp").font(.system(size: 18, weight: .semibold)).italic())
                    .foregroundStyle(DS.wordmark)
                    .tracking(0.3)
                if model.permissionDenied {
                    HStack {
                        Spacer()
                        Text("MICROPHONE ACCESS DENIED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.fault)
                    }
                }
            }
            .frame(height: 26)

            HStack(alignment: .top, spacing: 13) {
                VStack(spacing: 9) {
                    ForEach(0..<4, id: \.self) { StripView(model: model, index: $0) }
                }
                .frame(width: 336)

                VStack(alignment: .leading, spacing: 9) {
                    Text("OUTPUTS").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.textDim)

                    ForEach(0..<4, id: \.self) { b in
                        let on = !model.buses[b].deviceUID.isEmpty
                        Panel(live: on) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(BUS_NAMES[b])
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 18, height: 18)
                                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(on ? DS.glowDeep.opacity(0.95) : Color.white.opacity(0.055)))
                                        .foregroundStyle(on ? DS.textLit : DS.textDim)
                                    Picker("", selection: Binding(
                                        get: { model.buses[b].deviceUID },
                                        set: { model.setOutput(b, uid: $0) })) {
                                        Text("None").tag("")
                                        ForEach(model.outputCandidates()) { d in Text(d.name).tag(d.uid) }
                                    }
                                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                                }
                                if on && !model.buses[b].detail.isEmpty {
                                    Text(model.buses[b].detail)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(DS.textDim)
                                }
                                if !model.buses[b].error.isEmpty {
                                    Text(model.buses[b].error)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(DS.fault)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .frame(width: 246)
            }
        }
        .padding(16)
        .padding(.top, 4)
        // 336 (strips) + 246 (outputs) + 13 (gap) + 32 (padding). Pinned so the
        // header's unbounded Spacer cannot make the content width indeterminate
        // under .windowResizability(.contentSize).
        .frame(width: 627, alignment: .leading)
        .background(
            LinearGradient(colors: [DS.bgTop, DS.bgMid, DS.bgBottom],
                           startPoint: .top, endPoint: .bottom)
        )
        .background(TrafficLightOffset(dy: 7).frame(width: 0, height: 0))
        .preferredColorScheme(.dark)
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
