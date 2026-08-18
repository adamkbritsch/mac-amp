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
