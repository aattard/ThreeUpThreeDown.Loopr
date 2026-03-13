import UIKit
import AVFoundation

class LiveCameraPreviewView: UIView {
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isFrontCamera: Bool = false
    private var currentDevice: AVCaptureDevice?
    private var lastZoomFactor: CGFloat = 1.0
    
    // Frame rate support tracking
    private var supports60FPS: Bool = false
    
    var onZoomChanged: ((CGFloat) -> Void)?
    var onFPSSupportChanged: ((Bool) -> Void)?  // Callback when FPS support changes
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        
        // Listen for orientation changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        CATransaction.commit()
    }
    
    @objc private func orientationDidChange() {
        guard let connection = previewLayer?.connection else { return }
        
        let interfaceOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        
        if isFrontCamera {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 0
                print("📱 Live Preview (Front): Landscape Left (0°)")
            case .landscapeRight:
                connection.videoRotationAngle = 180
                print("📱 Live Preview (Front): Landscape Right (180°)")
            case .portrait:
                connection.videoRotationAngle = 90
                print("📱 Live Preview (Front): Portrait (90°)")
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
                print("📱 Live Preview (Front): Portrait Upside Down (270°)")
            default:
                connection.videoRotationAngle = 0
            }
        } else {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 180
                print("📱 Live Preview (Back): Landscape Left (180°)")
            case .landscapeRight:
                connection.videoRotationAngle = 0
                print("📱 Live Preview (Back): Landscape Right (0°)")
            case .portrait:
                connection.videoRotationAngle = 90
                print("📱 Live Preview (Back): Portrait (90°)")
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
                print("📱 Live Preview (Back): Portrait Upside Down (270°)")
            default:
                connection.videoRotationAngle = 0
            }
        }
    }

    private func updatePreviewOrientation() {
        guard let connection = previewLayer?.connection else { return }
        
        let interfaceOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        
        if isFrontCamera {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 0
                print("📱 Initial Live Preview (Front): Landscape Left (0°)")
            case .landscapeRight:
                connection.videoRotationAngle = 180
                print("📱 Initial Live Preview (Front): Landscape Right (180°)")
            case .portrait:
                connection.videoRotationAngle = 90
                print("📱 Initial Live Preview (Front): Portrait (90°)")
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
                print("📱 Initial Live Preview (Front): Portrait Upside Down (270°)")
            default:
                connection.videoRotationAngle = 0
            }
        } else {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 180
                print("📱 Initial Live Preview (Back): Landscape Left (180°)")
            case .landscapeRight:
                connection.videoRotationAngle = 0
                print("📱 Initial Live Preview (Back): Landscape Right (0°)")
            case .portrait:
                connection.videoRotationAngle = 90
                print("📱 Initial Live Preview (Back): Portrait (90°)")
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
                print("📱 Initial Live Preview (Back): Portrait Upside Down (270°)")
            default:
                connection.videoRotationAngle = 0
            }
        }
    }
    
    // MARK: - Camera Diagnostics
    
    private func logCameraCapabilities() {
        print("========================================")
        print("📷 CAMERA CAPABILITIES DIAGNOSTIC")
        print("========================================")
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .unspecified
        )
        
        for device in discoverySession.devices {
            let position = device.position == .front ? "Front" : "Back"
            print("--- Camera: \(device.localizedName) ---")
            print("  Position: \(position)")
            print("  Device Type: \(device.deviceType)")
            print("  Min Zoom: \(device.minAvailableVideoZoomFactor)")
            print("  Max Zoom: \(device.maxAvailableVideoZoomFactor)")
            print("  Switch Over Zoom Factors: \(device.virtualDeviceSwitchOverVideoZoomFactors)")
            print("  Active Format Min Zoom (Center Stage): \(device.activeFormat.videoMinZoomFactorForCenterStage)")
            print("  Center Stage Active: \(device.isCenterStageActive)")
            print("-------------------------------------")
        }
        
        print("========================================")
    }
    
    // MARK: - Ultra-Wide Detection
    
    /// Returns true if an ultra-wide camera exists for the given position.
    static func ultraWideCameraAvailable(for position: AVCaptureDevice.Position) -> Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: position
        )
        return !session.devices.isEmpty
    }
    
    /// Convenience helper using the current camera position setting.
    static func ultraWideCameraAvailableForCurrentPosition() -> Bool {
        let position: AVCaptureDevice.Position = Settings.shared.useFrontCamera ? .front : .back
        return ultraWideCameraAvailable(for: position)
    }
    
    // MARK: - Device Selection
    
    /// Picks the correct AVCaptureDevice based on position and ultra-wide setting.
    private func selectCameraDevice(useFrontCamera: Bool, useUltraWide: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
        
        if useUltraWide {
            // Try ultra-wide first; fall back to wide angle if not available
            if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) {
                print("📷 Using ultra-wide camera (\(position == .front ? "front" : "back"))")
                return ultraWide
            } else {
                print("⚠️ Ultra-wide not available for \(position == .front ? "front" : "back") position, falling back to wide angle")
            }
        }
        
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
    
    // MARK: - Preview Start/Stop
    
    func startPreview(useFrontCamera: Bool, completion: (() -> Void)? = nil) {
        print("📷 Starting live preview")
        self.isFrontCamera = useFrontCamera
        let session = AVCaptureSession()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            session.beginConfiguration()
            session.sessionPreset = .high
            
            let useUltraWide = Settings.shared.useUltraWideCamera
            guard let camera = self.selectCameraDevice(useFrontCamera: useFrontCamera, useUltraWide: useUltraWide) else {
                print("❌ No camera found for preview")
                session.commitConfiguration()
                return
            }
            
            self.currentDevice = camera
            
            // Log camera capabilities for diagnostics
            self.logCameraCapabilities()
            
            // Check for 60fps support
            self.supports60FPS = self.checkFPSSupport(device: camera, fps: 60)
            print("📹 Camera supports 60fps: \(self.supports60FPS)")
            
            // Notify about FPS support change
            DispatchQueue.main.async {
                self.onFPSSupportChanged?(self.supports60FPS)
            }
            
            // Configure frame rate
            let desiredFPS = Settings.shared.currentFPS(isFrontCamera: useFrontCamera)
            let actualFPS = self.configureFPS(device: camera, targetFPS: desiredFPS)
            print("📹 Configured FPS: \(actualFPS)")
            
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
                
                let output = AVCaptureVideoDataOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
                
                // Commit configuration
                session.commitConfiguration()
                print("✅ Session configuration committed")
                
                self.captureSession = session
                
                // START RUNNING immediately after commit (still on background queue)
                if !session.isRunning {
                    session.startRunning()
                    print("✅ Live preview running")
                }
                
                // Now move to main thread for UI updates
                DispatchQueue.main.async {
                    // Prevent screen from dimming or sleeping while camera is active
                    UIApplication.shared.isIdleTimerDisabled = true

                    let preview = AVCaptureVideoPreviewLayer(session: session)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.bounds
                    preview.opacity = 0
                    self.layer.addSublayer(preview)
                    self.previewLayer = preview
                    self.updatePreviewOrientation()
                    print("✅ Preview layer added")
                    
                    // APPLY ZOOM AND FADE IN
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let savedZoom = Settings.shared.currentZoomFactor(isFrontCamera: useFrontCamera)
                        self.applyZoom(savedZoom)
                        print("🔍 Restored zoom on home screen: \(savedZoom)x")
                        
                        // FADE IN PREVIEW
                        UIView.animate(withDuration: 0.3) {
                            self.previewLayer?.opacity = 1
                        } completion: { _ in
                            // Notify that preview is ready
                            completion?()
                        }
                    }
                }
                
            } catch {
                print("❌ Preview setup error: \(error)")
                session.commitConfiguration()
                // Call completion even on failure so splash screen doesn't hang
                DispatchQueue.main.async {
                    completion?()
                }
            }
        }
    }

    func stopPreview(completion: @escaping () -> Void) {
        print("🛑 Stopping live preview")
        
        guard let session = captureSession else {
            completion()
            return
        }
        
        guard session.isRunning else {
            print("⚠️ Session already stopped")
            completion()
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.stopRunning()
            
            DispatchQueue.main.async {
                // Re-enable idle timer now that the camera is no longer active
                UIApplication.shared.isIdleTimerDisabled = false

                self?.previewLayer?.removeFromSuperlayer()
                self?.captureSession = nil
                self?.previewLayer = nil
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("✅ Preview fully stopped")
                    completion()
                }
            }
        }
    }
    
    // MARK: - Zoom
    
    func applyZoom(_ zoomFactor: CGFloat) {
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Get device limits
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let minZoom = device.minAvailableVideoZoomFactor
            
            // Apply custom limits: 0.5x to 5x
            let customMinZoom: CGFloat = 0.5
            let customMaxZoom: CGFloat = 5.0
            
            // Clamp to both device limits AND custom limits
            let effectiveMin = max(minZoom, customMinZoom)
            let effectiveMax = min(maxZoom, customMaxZoom)
            let clampedZoom = min(max(zoomFactor, effectiveMin), effectiveMax)
            
            device.videoZoomFactor = clampedZoom
            lastZoomFactor = clampedZoom
            
            device.unlockForConfiguration()
            
            if isFrontCamera {
                Settings.shared.frontCameraZoom = clampedZoom
            } else {
                Settings.shared.backCameraZoom = clampedZoom
            }
            
            DispatchQueue.main.async {
                self.onZoomChanged?(clampedZoom)
            }
            
        } catch {
            print("❌ Error setting zoom: \(error)")
        }
    }

    @objc func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        guard let device = currentDevice else { return }
        
        switch gesture.state {
        case .began:
            lastZoomFactor = device.videoZoomFactor
            
        case .changed:
            let pinchScale = gesture.scale
            let delta = (pinchScale - 1.0) * 0.9
            let newZoomFactor = lastZoomFactor * (1.0 + delta)
            
            applyZoom(newZoomFactor)
            
            // Reset gesture scale to prevent accumulation
            gesture.scale = 1.0
            lastZoomFactor = device.videoZoomFactor
            
        case .ended:
            if isFrontCamera {
                Settings.shared.frontCameraZoom = device.videoZoomFactor
            } else {
                Settings.shared.backCameraZoom = device.videoZoomFactor
            }
            print("✅ Zoom saved: \(device.videoZoomFactor)x")
            
        default:
            break
        }
    }

    func addPinchGesture() {
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        self.addGestureRecognizer(pinchGesture)
        print("✅ Pinch gesture added to preview")
    }
    
    func setZoom(_ zoomFactor: CGFloat) {
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let minZoom = device.minAvailableVideoZoomFactor
            let customMinZoom: CGFloat = 1.0
            let customMaxZoom: CGFloat = 5.0
            
            let effectiveMin = max(minZoom, customMinZoom)
            let effectiveMax = min(maxZoom, customMaxZoom)
            let clampedZoom = min(max(zoomFactor, effectiveMin), effectiveMax)
            
            device.videoZoomFactor = clampedZoom
            device.unlockForConfiguration()
            
            // Trigger the zoom callback
            onZoomChanged?(clampedZoom)
            
            print("🔍 Zoom set to: \(clampedZoom)x")
        } catch {
            print("❌ Failed to set zoom: \(error)")
        }
    }
    
    // MARK: - FPS Support Methods
    
    /// Check if a device supports a specific frame rate
    func checkFPSSupport(device: AVCaptureDevice, fps: Int) -> Bool {
        let targetFrameRate = Double(fps)
        
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFrameRate && targetFrameRate <= range.maxFrameRate {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Configure the device to use the specified FPS, returns actual FPS set
    @discardableResult
    func configureFPS(device: AVCaptureDevice, targetFPS: Int) -> Int {
        guard checkFPSSupport(device: device, fps: targetFPS) else {
            print("⚠️ \(targetFPS) fps not supported, falling back to 30fps")
            return configureFPS(device: device, targetFPS: 30)
        }
        
        let targetFrameRate = Double(targetFPS)
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?
        
        // Find the best format that supports the target frame rate
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFrameRate && targetFrameRate <= range.maxFrameRate {
                    // Prefer formats with higher max resolution
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    if bestFormat == nil {
                        bestFormat = format
                        bestRange = range
                    } else if let currentBest = bestFormat {
                        let currentDimensions = CMVideoFormatDescriptionGetDimensions(currentBest.formatDescription)
                        if dimensions.width * dimensions.height > currentDimensions.width * currentDimensions.height {
                            bestFormat = format
                            bestRange = range
                        }
                    }
                }
            }
        }
        
        guard let format = bestFormat, let range = bestRange else {
            print("❌ No suitable format found for \(targetFPS)fps")
            return 30
        }
        
        do {
            try device.lockForConfiguration()
            
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            
            device.unlockForConfiguration()
            
            print("✅ Successfully configured \(targetFPS)fps")
            return targetFPS
            
        } catch {
            print("❌ Failed to configure FPS: \(error)")
            return 30
        }
    }
    
    /// Get current FPS support status
    func getCurrentFPSSupport() -> Bool {
        return supports60FPS
    }
    
    /// Apply new FPS setting to current device
    func applyFPS(_ fps: Int) {
        guard let device = currentDevice else { return }
        
        let actualFPS = configureFPS(device: device, targetFPS: fps)
        
        // Save the setting
        if isFrontCamera {
            Settings.shared.frontCameraFPS = actualFPS
        } else {
            Settings.shared.backCameraFPS = actualFPS
        }
        
        print("📹 FPS set to: \(actualFPS)")
    }

}
