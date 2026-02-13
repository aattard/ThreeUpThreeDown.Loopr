import Foundation

class Settings {
    static let shared = Settings()
    
    private let defaults = UserDefaults.standard
    
    private let keyPlaybackDelay = "playbackDelay"
    private let keyBufferDuration = "bufferDuration"
    private let keyCameraSelection = "cameraSelection"
    
    private let keyBackCameraZoom = "backCameraZoom"
    private let keyFrontCameraZoom = "frontCameraZoom"
    
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
    
    private init() {}
}
