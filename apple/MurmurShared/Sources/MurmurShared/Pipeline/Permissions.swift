import AVFoundation
import Foundation
import Speech
import UIKit

/// Three-state permission, the same shape for the microphone and for speech recognition, so
/// onboarding can treat them identically.
public enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}

/// The two system prompts Murmur needs, and the way back to Settings once one is denied.
///
/// Both prompts are asked during onboarding rather than at the moment of the first dictation,
/// so nobody's first recording is eaten by an alert.
public enum Permissions {
    // MARK: Microphone

    public static func micStatus() -> PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .granted: return .granted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// Shows the system prompt if it has not been shown; otherwise returns the standing
    /// answer immediately.
    public static func requestMic() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: Speech recognition

    /// Needed by both on-device engines even though nothing leaves the phone: the
    /// authorization gate is on the API, not on the network.
    public static func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    public static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    // MARK: Settings

    /// Opens Murmur's page in Settings — the only route back once a permission is denied,
    /// since the system prompt is shown exactly once.
    public static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in UIApplication.shared.open(url) }
    }
}
