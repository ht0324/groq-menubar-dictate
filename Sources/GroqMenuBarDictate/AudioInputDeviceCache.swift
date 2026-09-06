import CoreAudio
import Foundation

/// Serializes background prewarming with lookup at recording start. Device IDs
/// can be recycled, so callers must validate identity as well as availability.
final class AudioInputDeviceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedDevice: AudioDeviceInfo?

    func resolve(
        discover: () throws -> AudioDeviceInfo?,
        isValid: (AudioDeviceInfo) -> Bool
    ) rethrows -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedDevice, isValid(cachedDevice) {
            return cachedDevice.id
        }
        cachedDevice = nil
        guard let device = try discover(), device.uid != nil, isValid(device) else {
            return nil
        }
        cachedDevice = device
        return device.id
    }
}
