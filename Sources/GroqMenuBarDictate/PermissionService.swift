import AVFoundation
import ApplicationServices
import Foundation

@MainActor
final class PermissionService {
    enum EventAccess {
        case listen
        case post
    }

    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func hasEventAccess(_ access: EventAccess) -> Bool {
        checkEventAccess(access, prompt: false)
    }

    func ensureEventAccess(_ access: EventAccess) -> Bool {
        if checkEventAccess(access, prompt: false) {
            return true
        }
        _ = checkEventAccess(access, prompt: true)
        return checkEventAccess(access, prompt: false)
    }

    func permissionSummary(promptForDialogs: Bool = false) -> [String] {
        let microphoneLine: String = {
            switch microphoneAuthorizationStatus() {
            case .authorized:
                return "Microphone: granted"
            case .notDetermined:
                return "Microphone: not determined"
            case .denied:
                return "Microphone: denied"
            case .restricted:
                return "Microphone: restricted"
            @unknown default:
                return "Microphone: unknown"
            }
        }()

        let listenLine = "Input Monitoring (for global Option/Escape detection): \(checkEventAccess(.listen, prompt: promptForDialogs) ? "granted" : "missing")"
        let postLine = "Post keyboard events (for auto-paste Cmd+V): \(checkEventAccess(.post, prompt: promptForDialogs) ? "granted" : "missing")"
        return [microphoneLine, listenLine, postLine]
    }

    private func checkEventAccess(_ access: EventAccess, prompt: Bool) -> Bool {
        if #available(macOS 10.15, *) {
            switch access {
            case .listen:
                return prompt ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
            case .post:
                return prompt ? CGRequestPostEventAccess() : CGPreflightPostEventAccess()
            }
        }
        return true
    }
}
