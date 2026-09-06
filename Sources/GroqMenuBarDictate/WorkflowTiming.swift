import Foundation
import OSLog

/// Per-transcription timing and network diagnostics.
///
/// Kept out of `AppCoordinator` so the record -> transcribe -> copy/paste flow
/// reads without instrumentation noise. The coordinator fills in phase
/// durations, calls `apply(_:)` to absorb the service's network metrics, and
/// emits correlated workflow and network lines when diagnostics are enabled.
struct WorkflowTiming {
    var audioFileSizeBytes: Int64?
    var recordingDurationSeconds: TimeInterval?
    var uploadBodySizeBytes: Int64?
    var stopRecordingMilliseconds: Double = 0
    var promptPreparationMilliseconds: Double = 0
    var transcriptionMilliseconds: Double = 0
    var uploadPreparationMilliseconds: Double = 0
    var networkRoundTripMilliseconds: Double = 0
    var taskIntervalMilliseconds: Double?
    var fetchToResponseEndMilliseconds: Double?
    var domainLookupMilliseconds: Double?
    var tcpConnectionMilliseconds: Double?
    var tlsHandshakeMilliseconds: Double?
    var requestUploadMilliseconds: Double?
    var timeToFirstByteAfterUploadMilliseconds: Double?
    var responseDownloadMilliseconds: Double?
    var networkProtocolName: String?
    var isReusedConnection: Bool?
    var responseParseMilliseconds: Double = 0
    var postProcessingMilliseconds: Double = 0
    var clipboardMilliseconds: Double = 0
    // Preflight/event preparation overlaps transcription; permission is rechecked at delivery.
    var pastePreflightMilliseconds: Double?
    var pastePermissionMilliseconds: Double?
    var pastePreparationMilliseconds: Double?
    var pastePostMilliseconds: Double?
    var pasteMilliseconds: Double?
    var totalMilliseconds: Double = 0
    var result: String = "unknown"

    /// Absorbs the network/upload metrics returned by the transcription service.
    mutating func apply(_ metrics: TranscriptionMetrics) {
        audioFileSizeBytes = Int64(metrics.audioFileSizeBytes)
        uploadBodySizeBytes = metrics.uploadBodySizeBytes
        uploadPreparationMilliseconds = metrics.uploadPreparationMilliseconds
        networkRoundTripMilliseconds = metrics.networkRoundTripMilliseconds
        responseParseMilliseconds = metrics.responseParseMilliseconds
        guard let taskMetrics = metrics.urlSessionTaskMetrics else {
            return
        }
        taskIntervalMilliseconds = taskMetrics.taskIntervalMilliseconds
        fetchToResponseEndMilliseconds = taskMetrics.fetchToResponseEndMilliseconds
        domainLookupMilliseconds = taskMetrics.domainLookupMilliseconds
        tcpConnectionMilliseconds = taskMetrics.tcpConnectionMilliseconds
        tlsHandshakeMilliseconds = taskMetrics.tlsHandshakeMilliseconds
        requestUploadMilliseconds = taskMetrics.requestUploadMilliseconds
        timeToFirstByteAfterUploadMilliseconds = taskMetrics.timeToFirstByteAfterUploadMilliseconds
        responseDownloadMilliseconds = taskMetrics.responseDownloadMilliseconds
        networkProtocolName = taskMetrics.networkProtocolName
        isReusedConnection = taskMetrics.isReusedConnection
    }

    /// Split the fields to stay below OSLog's interpolation-argument limit.
    /// Optional fields use -1/unknown; the shared ID correlates both records.
    func log(to logger: Logger) {
        let timingID = UUID().uuidString
        let pastePreflightMilliseconds = self.pastePreflightMilliseconds ?? -1
        let pastePermissionMilliseconds = self.pastePermissionMilliseconds ?? -1
        let pastePreparationMilliseconds = self.pastePreparationMilliseconds ?? -1
        let pastePostMilliseconds = self.pastePostMilliseconds ?? -1
        let pasteMilliseconds = self.pasteMilliseconds ?? -1
        let audioFileSizeBytes = self.audioFileSizeBytes ?? -1
        let recordingDurationSeconds = self.recordingDurationSeconds ?? -1
        let uploadBodySizeBytes = self.uploadBodySizeBytes ?? -1
        let taskIntervalMilliseconds = self.taskIntervalMilliseconds ?? -1
        let fetchToResponseEndMilliseconds = self.fetchToResponseEndMilliseconds ?? -1
        let domainLookupMilliseconds = self.domainLookupMilliseconds ?? -1
        let tcpConnectionMilliseconds = self.tcpConnectionMilliseconds ?? -1
        let tlsHandshakeMilliseconds = self.tlsHandshakeMilliseconds ?? -1
        let requestUploadMilliseconds = self.requestUploadMilliseconds ?? -1
        let timeToFirstByteAfterUploadMilliseconds = self.timeToFirstByteAfterUploadMilliseconds ?? -1
        let responseDownloadMilliseconds = self.responseDownloadMilliseconds ?? -1
        let networkProtocolName = self.networkProtocolName ?? "unknown"
        let reusedConnection = isReusedConnection.map { $0 ? "true" : "false" } ?? "unknown"
        logger.info(
            "Workflow timing id=\(timingID, privacy: .public) result=\(result, privacy: .public) audio_bytes=\(audioFileSizeBytes, privacy: .public) recording_s=\(recordingDurationSeconds, format: .fixed(precision: 3)) upload_body_bytes=\(uploadBodySizeBytes, privacy: .public) total_ms=\(totalMilliseconds, format: .fixed(precision: 1)) stop_ms=\(stopRecordingMilliseconds, format: .fixed(precision: 1)) prep_ms=\(promptPreparationMilliseconds, format: .fixed(precision: 1)) transcribe_ms=\(transcriptionMilliseconds, format: .fixed(precision: 1)) upload_prep_ms=\(uploadPreparationMilliseconds, format: .fixed(precision: 1)) network_ms=\(networkRoundTripMilliseconds, format: .fixed(precision: 1)) parse_ms=\(responseParseMilliseconds, format: .fixed(precision: 1)) post_ms=\(postProcessingMilliseconds, format: .fixed(precision: 1)) clipboard_ms=\(clipboardMilliseconds, format: .fixed(precision: 1)) paste_preflight_ms=\(pastePreflightMilliseconds, format: .fixed(precision: 1)) paste_permission_ms=\(pastePermissionMilliseconds, format: .fixed(precision: 1)) paste_prepare_ms=\(pastePreparationMilliseconds, format: .fixed(precision: 1)) paste_post_ms=\(pastePostMilliseconds, format: .fixed(precision: 1)) paste_ms=\(pasteMilliseconds, format: .fixed(precision: 1))"
        )
        logger.info(
            "Workflow network id=\(timingID, privacy: .public) task_interval_ms=\(taskIntervalMilliseconds, format: .fixed(precision: 1)) fetch_to_response_end_ms=\(fetchToResponseEndMilliseconds, format: .fixed(precision: 1)) dns_ms=\(domainLookupMilliseconds, format: .fixed(precision: 1)) tcp_ms=\(tcpConnectionMilliseconds, format: .fixed(precision: 1)) tls_ms=\(tlsHandshakeMilliseconds, format: .fixed(precision: 1)) request_upload_ms=\(requestUploadMilliseconds, format: .fixed(precision: 1)) first_byte_wait_ms=\(timeToFirstByteAfterUploadMilliseconds, format: .fixed(precision: 1)) response_download_ms=\(responseDownloadMilliseconds, format: .fixed(precision: 1)) reused_connection=\(reusedConnection, privacy: .public) network_protocol=\(networkProtocolName, privacy: .public)"
        )
    }
}
