import Foundation
import CoreAudio
import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
}

enum AudioDeviceList {
    static func inputs() -> [AudioInputDevice] {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        var result: [AudioInputDevice] = []
        for id in deviceIDs {
            let ch = channelCount(device: id, scope: kAudioDevicePropertyScopeInput)
            guard ch > 0 else { continue }
            guard let uid = stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device: id, selector: kAudioDevicePropertyDeviceNameCFString)
            else { continue }
            result.append(AudioInputDevice(id: id, uid: uid, name: name, inputChannels: ch))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultInputUID() -> String? {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return stringProperty(device: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first(where: { $0.uid == uid })?.id
    }

    static func inputChannelCount(forUID uid: String?) -> Int {
        if let uid, let device = inputs().first(where: { $0.uid == uid }) {
            return max(1, device.inputChannels)
        }
        if let def = defaultInputUID(), let device = inputs().first(where: { $0.uid == def }) {
            return max(1, device.inputChannels)
        }
        return 2
    }

    private static func channelCount(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &prop, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &prop, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let bufs = UnsafeMutableAudioBufferListPointer(list)
        var channels = 0
        for buf in bufs {
            channels += Int(buf.mNumberChannels)
        }
        return channels
    }

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var prop = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &prop, 0, nil, &size) == noErr else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: CFString?.self, repeating: nil, count: 1)
        var sz = size
        guard AudioObjectGetPropertyData(device, &prop, 0, nil, &sz, raw) == noErr else { return nil }
        guard let cf = raw.load(as: CFString?.self) else { return nil }
        return cf as String
    }
}
