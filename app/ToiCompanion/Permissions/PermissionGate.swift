import AVFoundation
import Speech
import os.log

/// Orchestrates the macOS TCC (Transparency, Consent, and Control) prompts
/// for microphone and speech recognition permissions.
///
/// macOS prompts the user the first time the app tries to use each
/// capability. We ask for both upfront during onboarding.
final class PermissionGate {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "PermissionGate")

    // MARK: - Microphone

    /// Requests microphone permission if not yet granted.
    /// Returns the current permission status.
    @MainActor
    func requestMicrophonePermission() async -> PermissionStatus {
        // AVAudioApplication is macOS 14+. Fallback to AVCaptureDevice on macOS 13.
        if #available(macOS 14.0, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:  return .granted
            case .denied:      return .denied
            case .restricted:  return .restricted
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                return granted ? .granted : .denied
            @unknown default:  return .unknown
            }
        } else {
            // macOS 13 fallback using the older AVCaptureDevice.requestAccess
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized:  return .granted
            case .denied:      return .denied
            case .restricted:  return .restricted
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                return granted ? .granted : .denied
            @unknown default:  return .unknown
            }
        }
    }

    // MARK: - Speech Recognition

    /// Requests speech recognition permission if not yet granted.
    @MainActor
    func requestSpeechRecognitionPermission() async -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    switch status {
                    case .authorized: continuation.resume(returning: .granted)
                    case .denied:     continuation.resume(returning: .denied)
                    case .restricted: continuation.resume(returning: .restricted)
                    case .notDetermined: continuation.resume(returning: .unknown)
                    @unknown default:   continuation.resume(returning: .unknown)
                    }
                }
            }
        @unknown default:    return .unknown
        }
    }

    // MARK: - Combined

    /// Requests both permissions. Returns a tuple with each status.
    /// Phase 1/2: just call this at app launch.
    @MainActor
    func requestAllPermissions() async -> (mic: PermissionStatus, speech: PermissionStatus) {
        let mic    = await requestMicrophonePermission()
        let speech = await requestSpeechRecognitionPermission()
        logger.info("Permissions: mic=\(mic.rawValue), speech=\(speech.rawValue)")
        return (mic, speech)
    }
}

// MARK: - Status

enum PermissionStatus: String {
    case granted
    case denied
    case restricted
    case unknown
}
