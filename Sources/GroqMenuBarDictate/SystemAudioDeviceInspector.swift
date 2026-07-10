import CoreAudio
import Foundation

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String?
    let uid: String?
    let transportType: UInt32?
}

enum AudioDeviceRoutingPolicy {
    static func shouldAvoidAutomaticActivation(
        name: String?,
        uid: String?,
        transportType: UInt32?
    ) -> Bool {
        if transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }

        let searchableText = [name, uid]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return searchableText.contains("airpods") ||
            searchableText.contains("bluetooth")
    }
}

enum SystemAudioDeviceInspector {
    static func defaultInputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(for: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceInfo() throws -> AudioDeviceInfo {
        let deviceID = try defaultDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
        return try deviceInfo(for: deviceID)
    }

    static func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "set default input device", status: status)
        }
    }

    static func allAudioDeviceIDs() throws -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "size audio device list", status: status)
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "read audio device list", status: status)
        }
        return deviceIDs
    }

    static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        return status == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    static func firstInputDevice(matchingName targetName: String) -> AudioDeviceInfo? {
        guard let deviceIDs = try? allAudioDeviceIDs() else {
            return nil
        }
        for deviceID in deviceIDs where hasInputStreams(deviceID) {
            guard let info = try? deviceInfo(for: deviceID),
                  let name = info.name,
                  name.localizedCaseInsensitiveContains(targetName)
            else {
                continue
            }
            return info
        }
        return nil
    }

    static func deviceInfo(for deviceID: AudioDeviceID) throws -> AudioDeviceInfo {
        AudioDeviceInfo(
            id: deviceID,
            name: try stringProperty(kAudioObjectPropertyName, for: deviceID),
            uid: try stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
            transportType: try uint32Property(kAudioDevicePropertyTransportType, for: deviceID)
        )
    }

    private static func defaultDeviceID(
        for selector: AudioObjectPropertySelector
    ) throws -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(bitPattern: 0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "read default device", status: status)
        }
        return deviceID
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) throws -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            return nil
        }

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer {
            storage.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            storage
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "read audio device string property", status: status)
        }
        return storage.load(as: CFString?.self) as String?
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) throws -> UInt32? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            return nil
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "read audio device uint32 property", status: status)
        }
        return value
    }
}

enum CoreAudioError: Error {
    case failed(operation: String, status: OSStatus)
}
