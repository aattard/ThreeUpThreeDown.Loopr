import Foundation

class Settings {
    static let shared = Settings()
    
    private let defaults = UserDefaults.standard
    
    private let keyPlaybackDelay = "playbackDelay"
    private let keyBufferDuration = "bufferDuration"
    private let keyCameraSelection = "cameraSelection"
    
    private let keyBufferDurationSeconds = "bufferDurationSeconds"
    private let keyBackCameraZoom = "backCameraZoom"
    private let keyFrontCameraZoom = "frontCameraZoom"
    private let keyBackCameraFPS = "backCameraFPS"
    private let keyFrontCameraFPS = "frontCameraFPS"
    private let keyFrontCameraUltraWide = "frontCameraUltraWide"
    private let keyBackCameraUltraWide = "backCameraUltraWide"
    
    var playbackDelay: Int {
        get {
            let value = defaults.integer(forKey: keyPlaybackDelay)
            return value == 0 ? 7 : value
        }
        set { defaults.set(newValue, forKey: keyPlaybackDelay) }
    }
    
    var bufferDuration: Int {
        get {
            let value = defaults.integer(forKey: keyBufferDuration)
            return value == 0 ? 45 : value
        }
        set { defaults.set(newValue, forKey: keyBufferDuration) }
    }
    
    /// Buffer duration in seconds (user selects 1–5 minutes; stored as seconds).
    /// Default: 60 seconds (1 minute).
    var bufferDurationSeconds: Int {
        get {
            let value = defaults.integer(forKey: keyBufferDurationSeconds)
            return value == 0 ? 60 : value
        }
        set { defaults.set(newValue, forKey: keyBufferDurationSeconds) }
    }

    var useFrontCamera: Bool {
        get { return defaults.bool(forKey: keyCameraSelection) }
        set { defaults.set(newValue, forKey: keyCameraSelection) }
    }

    /// Whether to use the ultra-wide camera for the front-facing position.
    /// Stored independently so switching cameras preserves each position's last selection.
    /// Resets zoom to 1.0 when toggled.
    var frontCameraUltraWide: Bool {
        get { return defaults.bool(forKey: keyFrontCameraUltraWide) }
        set {
            defaults.set(newValue, forKey: keyFrontCameraUltraWide)
            frontCameraZoom = 1.0
        }
    }

    /// Whether to use the ultra-wide camera for the rear-facing position.
    /// Resets zoom to 1.0 when toggled.
    var backCameraUltraWide: Bool {
        get { return defaults.bool(forKey: keyBackCameraUltraWide) }
        set {
            defaults.set(newValue, forKey: keyBackCameraUltraWide)
            backCameraZoom = 1.0
        }
    }

    /// Convenience accessor for the ultra-wide state of the currently active camera position.
    var useUltraWideCamera: Bool {
        get { return useFrontCamera ? frontCameraUltraWide : backCameraUltraWide }
        set {
            if useFrontCamera {
                frontCameraUltraWide = newValue
            } else {
                backCameraUltraWide = newValue
            }
        }
    }
    
    var backCameraZoom: CGFloat {
        get {
            let value = defaults.double(forKey: keyBackCameraZoom)
            return value == 0 ? 1.0 : CGFloat(value)
        }
        set { defaults.set(Double(newValue), forKey: keyBackCameraZoom) }
    }

    var frontCameraZoom: CGFloat {
        get {
            let value = defaults.double(forKey: keyFrontCameraZoom)
            return value == 0 ? 1.0 : CGFloat(value)
        }
        set { defaults.set(Double(newValue), forKey: keyFrontCameraZoom) }
    }
    
    var backCameraFPS: Int {
        get { return 30 }
        set { defaults.set(30, forKey: keyBackCameraFPS) }
    }
    
    var frontCameraFPS: Int {
        get { return 30 }
        set { defaults.set(30, forKey: keyFrontCameraFPS) }
    }

    func currentZoomFactor(isFrontCamera: Bool) -> CGFloat {
        return isFrontCamera ? frontCameraZoom : backCameraZoom
    }
    
    func setZoomFactor(_ zoom: CGFloat, isFrontCamera: Bool) {
        if isFrontCamera { frontCameraZoom = zoom } else { backCameraZoom = zoom }
    }
    
    func currentFPS(isFrontCamera: Bool) -> Int {
        return isFrontCamera ? frontCameraFPS : backCameraFPS
    }
    
    func setFPS(_ fps: Int, isFrontCamera: Bool) {
        if isFrontCamera { frontCameraFPS = fps } else { backCameraFPS = fps }
    }
    
    private init() {}
}
