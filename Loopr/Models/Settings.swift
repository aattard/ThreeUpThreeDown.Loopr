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
    
    var playbackDelay: Int {
        get {
            let value = defaults.integer(forKey: keyPlaybackDelay)
            return value == 0 ? 7 : value // Default 7 seconds
        }
        set {
            defaults.set(newValue, forKey: keyPlaybackDelay)
        }
    }
    
    var bufferDuration: Int {
        get {
            let value = defaults.integer(forKey: keyBufferDuration)
            return value == 0 ? 45 : value // Default 45 seconds
        }
        set {
            defaults.set(newValue, forKey: keyBufferDuration)
        }
    }
    
    /// Buffer duration in seconds (user selects 1–5 minutes; stored as seconds).
    /// Default: 60 seconds (1 minute).
    var bufferDurationSeconds: Int {
        get {
            let value = defaults.integer(forKey: keyBufferDurationSeconds)
            return value == 0 ? 60 : value
        }
        set {
            defaults.set(newValue, forKey: keyBufferDurationSeconds)
        }
    }

    var useFrontCamera: Bool {
        get {
            return defaults.bool(forKey: keyCameraSelection)
        }
        set {
            defaults.set(newValue, forKey: keyCameraSelection)
        }
    }
    
    var backCameraZoom: CGFloat {
        get {
            let value = defaults.double(forKey: keyBackCameraZoom)
            return value == 0 ? 1.0 : CGFloat(value)
        }
        set {
            defaults.set(Double(newValue), forKey: keyBackCameraZoom)
        }
    }

    var frontCameraZoom: CGFloat {
        get {
            let value = defaults.double(forKey: keyFrontCameraZoom)
            return value == 0 ? 1.0 : CGFloat(value)
        }
        set {
            defaults.set(Double(newValue), forKey: keyFrontCameraZoom)
        }
    }
    
    var backCameraFPS: Int {
        get {
            // Always return 30fps - the only supported frame rate
            return 30
        }
        set {
            // Accept but always store 30fps
            defaults.set(30, forKey: keyBackCameraFPS)
        }
    }
    
    var frontCameraFPS: Int {
        get {
            // Always return 30fps - the only supported frame rate
            return 30
        }
        set {
            // Accept but always store 30fps
            defaults.set(30, forKey: keyFrontCameraFPS)
        }
    }

    // Helper to get the right zoom for current camera
    func currentZoomFactor(isFrontCamera: Bool) -> CGFloat {
        return isFrontCamera ? frontCameraZoom : backCameraZoom
    }
    
    func setZoomFactor(_ zoom: CGFloat, isFrontCamera: Bool) {
        if isFrontCamera {
            frontCameraZoom = zoom
        } else {
            backCameraZoom = zoom
        }
    }
    
    // Helper to get the right FPS for current camera
    func currentFPS(isFrontCamera: Bool) -> Int {
        return isFrontCamera ? frontCameraFPS : backCameraFPS
    }
    
    func setFPS(_ fps: Int, isFrontCamera: Bool) {
        if isFrontCamera {
            frontCameraFPS = fps
        } else {
            backCameraFPS = fps
        }
    }
    
    private init() {}
}
