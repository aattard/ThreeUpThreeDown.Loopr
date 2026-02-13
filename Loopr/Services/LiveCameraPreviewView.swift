import UIKit
import AVFoundation

class LiveCameraPreviewView: UIView {
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isFrontCamera: Bool = false
    private var currentDevice: AVCaptureDevice?
    private var lastZoomFactor: CGFloat = 1.0
    
    var onZoomChanged: ((CGFloat) -> Void)?
    
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
    
    func startPreview(useFrontCamera: Bool, completion: (() -> Void)? = nil) {
        print("📷 Starting live preview")
        self.isFrontCamera = useFrontCamera
        let session = AVCaptureSession()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            session.beginConfiguration()
            session.sessionPreset = .high
            
            let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                print("❌ No camera found for preview")
                session.commitConfiguration()
                return
            }
            
            self.currentDevice = camera
            
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
    
    func applyZoom(_ zoomFactor: CGFloat) {
        guard let device = currentDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // Get device limits
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let minZoom = device.minAvailableVideoZoomFactor
            
            // Apply custom limits: 0.5x to 10x
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
            // Balanced zoom sensitivity
            let pinchScale = gesture.scale
            
            let delta = (pinchScale - 1.0) * 0.9  // Increased from 0.15 to 0.25
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

}

