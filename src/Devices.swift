import Foundation
import CoreAudio

/// One selectable Core Audio device.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
}

enum DeviceQuery {

    private static func addr(_ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ dev: AudioDeviceID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var a = addr(selector)
        // CoreAudio writes a +1-retained CFStringRef here. Taking it as an
        // Unmanaged keeps ARC out of the way, then we consume the +1 exactly once.
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &cf) == noErr,
              let value = cf else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(_ dev: AudioDeviceID, input: Bool) -> UInt32 {
        var a = addr(kAudioDevicePropertyStreamConfiguration,
                     input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// Every device the HAL currently reports.
    static func all() -> [AudioDevice] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Device IDs are reassigned across reboots; the UID is what we persist.
            let uid = string(id, kAudioDevicePropertyDeviceUID) ?? name
            return AudioDevice(id: id, uid: uid, name: name,
                               inputChannels: channels(id, input: true),
                               outputChannels: channels(id, input: false))
        }
    }

    static func inputs()  -> [AudioDevice] { all().filter { $0.inputChannels  > 0 } }
    static func outputs() -> [AudioDevice] { all().filter { $0.outputChannels > 0 } }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var a = addr(input ? kAudioHardwarePropertyDefaultInputDevice
                           : kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        return dev
    }

    static func sampleRate(_ dev: AudioDeviceID) -> Double {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var sr: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &sr) == noErr else { return 0 }
        return Double(sr)
    }
}

extension DeviceQuery {
    @discardableResult
    static func setDefaultOutput(_ dev: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = dev
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }
}

/// macOS makes a newly connected USB audio device the system output, which is
/// reasonable for headphones and wrong for a guitar interface: every alert and
/// every track suddenly plays into the amp instead of the speakers.
///
/// This watches the default output and puts it back if it lands on a device
/// MacAmp is currently capturing from. The condition is deliberately narrow --
/// it never touches a switch to any other device, so choosing headphones or a
/// display still works normally.
final class DefaultOutputGuard {
    private var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var block: AudioObjectPropertyListenerBlock?
    private var lastGood: AudioDeviceID = 0

    /// True when the device is serving as one of MacAmp's inputs.
    var isCaptureDevice: (AudioDeviceID) -> Bool = { _ in false }
    /// Called when a takeover was reverted, so the UI can say so.
    var onReverted: ((String) -> Void)?

    func start() {
        stop()
        let cur = DeviceQuery.defaultDevice(input: false)
        if !isCaptureDevice(cur) { lastGood = cur }

        let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let now = DeviceQuery.defaultDevice(input: false)
            guard self.isCaptureDevice(now) else {
                // A normal switch. Remember it as somewhere safe to go back to.
                if now != 0 { self.lastGood = now }
                return
            }
            let name = DeviceQuery.all().first { $0.id == now }?.name ?? "that device"
            // Fall back to the built-in speakers if there is no earlier choice.
            var target = self.lastGood
            if target == 0 || self.isCaptureDevice(target) {
                target = DeviceQuery.outputs().first {
                    $0.name.localizedCaseInsensitiveContains("MacBook") && $0.outputChannels > 0
                }?.id ?? 0
            }
            guard target != 0, target != now else { return }
            DeviceQuery.setDefaultOutput(target)
            self.onReverted?(name)
        }
        block = b
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, b)
    }

    func stop() {
        guard let b = block else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, b)
        block = nil
    }
    deinit { stop() }
}

/// Fires whenever the set of hardware devices changes (plug / unplug).
final class DeviceChangeWatcher {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var block: AudioObjectPropertyListenerBlock?

    func start(_ onChange: @escaping () -> Void) {
        stop()
        // Delivered on the main queue, so SwiftUI state updates are safe here.
        let b: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        block = b
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, b)
    }

    func stop() {
        guard let b = block else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, b)
        block = nil
    }

    deinit { stop() }
}
