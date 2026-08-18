import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

// MARK: - Model

@MainActor
final class MacAmpModel: ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        case needsPermission
        case deviceMissing(String)
        case failed(String)
    }

    @Published var inputs:  [AudioDevice] = []
    @Published var outputs: [AudioDevice] = []

    /// Outputs minus the device already chosen as input. Many USB interfaces —
    /// the Amphonix among them — advertise both input and output endpoints, but
    /// routing a device back into itself is a self-loop, never a valid choice.
    var availableOutputs: [AudioDevice] { outputs.filter { $0.uid != selectedInputUID } }
    @Published var selectedInputUID:  String = "" { didSet { persistAndRestart() } }
    @Published var selectedOutputUID: String = "" { didSet { persistAndRestart() } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var detail: String = ""

    private let engine: OpaquePointer? = macamp_create()
    private let watcher = DeviceChangeWatcher()
    private var ticker: Timer?
    private var suppressRestart = false

    private let kIn  = "inputDeviceUID"
    private let kOut = "outputDeviceUID"

    init() {
        refreshDevices(initial: true)
        watcher.start { [weak self] in self?.refreshDevices(initial: false) }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDetail() }
        }
    }

    deinit { macamp_destroy(engine) }

    // MARK: Permission

    /// Core Audio hands back digital silence when microphone access is denied
    /// rather than returning an error, so this must be checked explicitly.
    func requestPermissionThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.start() } else { self.status = .needsPermission }
                }
            }
        default:
            status = .needsPermission
        }
    }

    // MARK: Devices

    func refreshDevices(initial: Bool) {
        inputs  = DeviceQuery.inputs()
        outputs = DeviceQuery.outputs()

        suppressRestart = true
        if selectedInputUID.isEmpty || !inputs.contains(where: { $0.uid == selectedInputUID }) {
            selectedInputUID = preferredInput()
        }
        if selectedOutputUID.isEmpty || !availableOutputs.contains(where: { $0.uid == selectedOutputUID }) {
            selectedOutputUID = preferredOutput()
        }
        suppressRestart = false

        if initial { return }

        // A device vanished mid-session, or came back. Re-resolve and recover.
        if resolvedInput() == nil {
            stop(); status = .deviceMissing("Input device disconnected")
        } else if resolvedOutput() == nil {
            stop(); status = .deviceMissing("Output device disconnected")
        } else if status != .running {
            requestPermissionThenStart()
        }
    }

    private func preferredInput() -> String {
        if let saved = UserDefaults.standard.string(forKey: kIn),
           let d = inputs.first(where: { $0.uid == saved }) { return d.uid }
        if let amp = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("Amphonix") }) {
            return amp.uid
        }
        let def = DeviceQuery.defaultDevice(input: true)
        return inputs.first(where: { $0.id == def })?.uid ?? inputs.first?.uid ?? ""
    }

    private func preferredOutput() -> String {
        let candidates = availableOutputs
        if let saved = UserDefaults.standard.string(forKey: kOut),
           let d = candidates.first(where: { $0.uid == saved }) { return d.uid }
        // Default to the built-in speakers rather than the system default: a
        // virtual driver holding "default output" would otherwise capture this.
        if let spk = candidates.first(where: { $0.name.localizedCaseInsensitiveContains("MacBook Pro Speakers") }) {
            return spk.uid
        }
        let def = DeviceQuery.defaultDevice(input: false)
        return candidates.first(where: { $0.id == def })?.uid ?? candidates.first?.uid ?? ""
    }

    private func resolvedInput()  -> AudioDevice? { inputs.first  { $0.uid == selectedInputUID } }
    private func resolvedOutput() -> AudioDevice? { availableOutputs.first { $0.uid == selectedOutputUID } }

    // MARK: Engine

    private func persistAndRestart() {
        guard !suppressRestart else { return }

        // Choosing an input that was serving as the output strands the output
        // selection, since it is now filtered out. Re-pick before starting.
        if !availableOutputs.contains(where: { $0.uid == selectedOutputUID }) {
            suppressRestart = true
            selectedOutputUID = preferredOutput()
            suppressRestart = false
        }

        UserDefaults.standard.set(selectedInputUID,  forKey: kIn)
        UserDefaults.standard.set(selectedOutputUID, forKey: kOut)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { start() }
    }

    func start() {
        guard let engine else { status = .failed("Audio engine unavailable"); return }
        guard let i = resolvedInput()  else { status = .deviceMissing("Input device unavailable");  return }
        guard let o = resolvedOutput() else { status = .deviceMissing("Output device unavailable"); return }
        guard i.id != o.id else {
            status = .failed("Input and output cannot be the same device.")
            return
        }

        var buf = [CChar](repeating: 0, count: 512)
        let rc = macamp_start(engine, i.id, o.id, &buf, 512)
        if rc == 0 {
            status = .running
            updateDetail()
        } else {
            let msg = String(cString: buf)
            status = .failed(msg.isEmpty ? "Could not start audio (code \(rc))" : msg)
        }
    }

    func stop() {
        guard let engine else { return }
        macamp_stop(engine)
        if status == .running { status = .idle }
    }

    private func updateDetail() {
        guard let engine, status == .running else { detail = ""; return }
        let inR  = macamp_input_rate(engine)
        let outR = macamp_output_rate(engine)
        let ms   = macamp_latency_ms(engine)
        let un   = macamp_underruns(engine)
        var s = String(format: "%.1f kHz to %.1f kHz  ·  %.0f ms", inR / 1000, outR / 1000, ms)
        if un > 0 { s += "  ·  \(un) dropout\(un == 1 ? "" : "s")" }
        detail = s
    }
}

// MARK: - View

struct ContentView: View {
    @ObservedObject var model: MacAmpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            picker("Input", devices: model.inputs, selection: $model.selectedInputUID)
            picker("Output", devices: model.availableOutputs, selection: $model.selectedOutputUID)

            Divider()
            statusLine
        }
        .padding(22)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
            Text("MacAmp").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
    }

    private func picker(_ label: String,
                        devices: [AudioDevice],
                        selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(devices) { d in Text(d.name).tag(d.uid) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(statusText).font(.system(size: 12))
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var indicatorColor: Color {
        switch model.status {
        case .running:          return .green
        case .idle:             return .secondary
        default:                return .orange
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle:                    return "Stopped"
        case .running:                 return "Monitoring"
        case .needsPermission:         return "Microphone access denied. Enable MacAmp in System Settings > Privacy & Security > Microphone."
        case .deviceMissing(let m):    return m
        case .failed(let m):           return m
        }
    }
}

// MARK: - App

@main
struct MacAmpApp: App {
    @StateObject private var model = MacAmpModel()

    var body: some Scene {
        Window("MacAmp", id: "main") {
            ContentView(model: model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    model.requestPermissionThenStart()
                }
                .onDisappear { model.stop() }
        }
        .windowResizability(.contentSize)
    }
}
