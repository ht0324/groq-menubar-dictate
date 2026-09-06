import Foundation
import OSLog

struct RecordingStartTiming {
    var permissionMilliseconds: Double = 0
    var deviceSelectionMilliseconds: Double = 0
    var recorderCreationMilliseconds: Double = 0
    var preparationMilliseconds: Double = 0
    var recordMilliseconds: Double = 0
    var readyMilliseconds: Double = 0
    /// Time to update recording feedback and schedule the cue; excludes asynchronous playback.
    var feedbackMilliseconds: Double = 0
    var retryCleanupMilliseconds: Double = 0
    var eventPermissionMilliseconds: Double = 0
    var stateUpdateMilliseconds: Double = 0
    var profileAttempts = 0
    var sampleRate: Double = 0

    static func measure<T>(_ milliseconds: inout Double, operation: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        defer { milliseconds += Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 }
        return try operation()
    }

    func log(to logger: Logger) {
        logger.info(
            "Recording startup ready_ms=\(readyMilliseconds, format: .fixed(precision: 1)) permission_ms=\(permissionMilliseconds, format: .fixed(precision: 1)) device_ms=\(deviceSelectionMilliseconds, format: .fixed(precision: 1)) recorder_create_ms=\(recorderCreationMilliseconds, format: .fixed(precision: 1)) prepare_ms=\(preparationMilliseconds, format: .fixed(precision: 1)) record_ms=\(recordMilliseconds, format: .fixed(precision: 1)) feedback_ms=\(feedbackMilliseconds, format: .fixed(precision: 1)) profile_attempts=\(profileAttempts) sample_rate=\(sampleRate)"
        )
        logger.info(
            "Recording feedback retry_cleanup_ms=\(retryCleanupMilliseconds, format: .fixed(precision: 1)) event_permission_ms=\(eventPermissionMilliseconds, format: .fixed(precision: 1)) state_update_ms=\(stateUpdateMilliseconds, format: .fixed(precision: 1))"
        )
    }
}
