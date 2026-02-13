import UIKit
import AVFoundation

class DelayedCameraView: UIView {
    
    private var captureSession: AVCaptureSession!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var isFrontCamera: Bool = false
    private var currentDevice: AVCaptureDevice?
    
    // NEW: Callback for when session stops
    var onSessionStopped: (() -> Void)?
    
    // NEW: Replace frameBuffer with VideoFileBuffer
    private var videoFileBuffer: VideoFileBuffer?
    private var frameMetadata: [(timestamp: CMTime, index: Int)] = []
    private let metadataLock = NSLock()
    
    private var delaySeconds: Int = 7
    private var isActive: Bool = false
    private var isShowingDelayed: Bool = false
    private var isPaused: Bool = false
    
    private var displayTimer: Timer?
    private var displayImageView: UIImageView!
    
    // Scrubbing properties
    private var scrubberPosition: Int = 0
    private var lastUpdateTime: TimeInterval = 0
    
    // Current display state
    private var currentDisplayFrameIndex: Int = 0
    
    private let countdownLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 120, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.layer.cornerRadius = 20
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    // Stop button during countdown (matches home screen style)
    private let countdownStopButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        let image = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = .black
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.black.cgColor
        button.layer.cornerRadius = 60  // Matches 120×120 size
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let recordingIndicator: UIView = {
        let container = UIView()
        container.backgroundColor = UIColor.systemRed
        container.layer.cornerRadius = 18  // Half of height for pill shape
        container.translatesAutoresizingMaskIntoConstraints = false
        container.alpha = 0
        
        // Blinking dot
        let dot = UIView()
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.tag = 999  // For accessing later for blink animation
        
        // "LIVE" label
        let liveLabel = UILabel()
        liveLabel.text = "LIVE"
        liveLabel.textColor = .white
        liveLabel.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        liveLabel.tag = 998  // For accessing later
        
        // Delay label (shows "-7s")
        let delayLabel = UILabel()
        delayLabel.text = "-7s"
        delayLabel.textColor = .white.withAlphaComponent(0.9)
        delayLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        delayLabel.translatesAutoresizingMaskIntoConstraints = false
        delayLabel.tag = 997  // For updating with actual delay
        
        container.addSubview(dot)
        container.addSubview(liveLabel)
        container.addSubview(delayLabel)
        
        NSLayoutConstraint.activate([
            // Dot on the left
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            
            // "LIVE" label next to dot
            liveLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            liveLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            
            // Delay label after "LIVE"
            delayLabel.leadingAnchor.constraint(equalTo: liveLabel.trailingAnchor, constant: 3),
            delayLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            delayLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        
        return container
    }()
    
    // YouTube-style controls
    private let controlsContainer: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        view.layer.cornerRadius = 40  // NEW: Half of height (80/2 = 40) for half-circle ends
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        return view
    }()
    
    private let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "pause.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let scrubberSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 1
        slider.minimumTrackTintColor = .systemRed
        //slider.minimumTrackTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }()
    
    private let timeLabel: UILabel = {
        let label = UILabel()
        label.text = "LIVE"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let stopSessionButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)  // Changed from 24 to 32
        let image = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .systemRed
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private var hideControlsTimer: Timer?
    
    private lazy var captureQueue: DispatchQueue = {
        return DispatchQueue(label: "com.loopr.capture", qos: .userInteractive, attributes: [])
    }()
    
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        
        displayImageView = UIImageView(frame: bounds)
        displayImageView.contentMode = .scaleAspectFill
        displayImageView.clipsToBounds = true
        displayImageView.backgroundColor = .clear
        displayImageView.alpha = 0
        displayImageView.isUserInteractionEnabled = false
        addSubview(displayImageView)
        
        addSubview(countdownLabel)
        addSubview(countdownStopButton)
        setupControls()
        
        NSLayoutConstraint.activate([
            countdownLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countdownLabel.widthAnchor.constraint(equalToConstant: 200),
            countdownLabel.heightAnchor.constraint(equalToConstant: 200),
            
            // Stop button during countdown - bottom center (like home screen)
            countdownStopButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownStopButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -40),
            countdownStopButton.widthAnchor.constraint(equalToConstant: 120),  // Changed from 100
            countdownStopButton.heightAnchor.constraint(equalToConstant: 120)  // Changed from 100
        ])
        
        countdownStopButton.addTarget(self, action: #selector(countdownStopTapped), for: .touchUpInside)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
        
        print("🎬 DelayedCameraView initialized")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        hideControlsTimer?.invalidate()
        videoFileBuffer?.cleanup()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        displayImageView.frame = bounds
        previewLayer?.frame = bounds
        layer.layoutIfNeeded()
    }
    
    private func setupControls() {
        addSubview(controlsContainer)
        addSubview(recordingIndicator)
        
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(scrubberSlider)
        controlsContainer.addSubview(timeLabel)
        controlsContainer.addSubview(stopSessionButton)
        
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        scrubberSlider.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        scrubberSlider.addTarget(self, action: #selector(scrubberTouchEnded), for: [.touchUpInside, .touchUpOutside])
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped), for: .touchUpInside)
        
        NSLayoutConstraint.activate([
            // Recording indicator - top center
            recordingIndicator.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            recordingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            recordingIndicator.heightAnchor.constraint(equalToConstant: 36),
            recordingIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
                    
            // Container - floated up from bottom with side padding
            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),  // Side padding
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),  // Side padding
            controlsContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),  // Float up from bottom
            controlsContainer.heightAnchor.constraint(equalToConstant: 80),
            
            // Play/Pause button
            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 20),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Stop button - same size as play/pause
            stopSessionButton.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -20),
            stopSessionButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            stopSessionButton.widthAnchor.constraint(equalToConstant: 44),  // Same as play/pause
            stopSessionButton.heightAnchor.constraint(equalToConstant: 44),  // Same as play/pause
            
            // Time label
            timeLabel.trailingAnchor.constraint(equalTo: stopSessionButton.leadingAnchor, constant: -15),
            timeLabel.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 60),
            
            // Scrubber slider
            scrubberSlider.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 20),
            scrubberSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -20),
            scrubberSlider.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor)
        ])
    }
    
    @objc private func handleTap() {
        guard isShowingDelayed else { return }
        if controlsContainer.alpha == 0 {
            showControls()
        } else {
            hideControls()
        }
    }
    
    private func showControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 1
        }
        
        if !isPaused {
            resetHideControlsTimer()
        }
    }
    
    private func hideControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 0
        }
    }
    
    private func resetHideControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            if self?.isPaused == false {
                self?.hideControls()
            }
        }
    }
    
    private func startRecordingIndicator() {
        UIView.animate(withDuration: 0.3) {
            self.recordingIndicator.alpha = 1
        }
        
        // Blinking dot animation
        if let dot = recordingIndicator.viewWithTag(999) {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.0
            blink.duration = 0.8
            blink.repeatCount = .infinity
            blink.autoreverses = true
            dot.layer.add(blink, forKey: "blinking")
        }
    }

    private func stopRecordingIndicator() {
        if let dot = recordingIndicator.viewWithTag(999) {
            dot.layer.removeAnimation(forKey: "blinking")
        }
        
        UIView.animate(withDuration: 0.3) {
            self.recordingIndicator.alpha = 0
        }
    }
    
    @objc private func playPauseTapped() {
        if isPaused {
            resumePlayback()
        } else {
            pausePlayback()
        }
    }
    
    @objc private func stopSessionTapped() {
        print("🛑 Stop button tapped from controls")
        stopSession()
    }
    
    @objc private func countdownStopTapped() {
        print("🛑 Stop button tapped during countdown")
        stopSession()
    }
    
    @objc private func scrubberChanged() {
        // Auto-pause if user tries to scrub while playing
        if !isPaused {
            pausePlayback()
            return  // Let the pause complete, then they can scrub
        }
        
        let currentTime = CACurrentMediaTime()
        if currentTime - lastUpdateTime < 0.1 {
            return
        }
        
        lastUpdateTime = currentTime
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let requiredFrames = delaySeconds * 30
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        let scrubBackFrames = 30 * 30
        let oldestAllowedIndex = max(0, pausePointIndex - scrubBackFrames)
        
        let scrubRange = pausePointIndex - oldestAllowedIndex
        if scrubRange > 0 {
            let frameIndex = oldestAllowedIndex + Int(scrubberSlider.value * Float(scrubRange))
            scrubberPosition = max(oldestAllowedIndex, min(frameIndex, pausePointIndex))
            
            let secondsFromPause = Float(pausePointIndex - scrubberPosition) / 30.0
            DispatchQueue.main.async {
                if secondsFromPause < 0.1 {
                    self.timeLabel.text = "0.0s"
                } else {
                    self.timeLabel.text = String(format: "-%.1fs", secondsFromPause)
                }
            }
            
            // Extract frame (will use cache or file as appropriate)
            videoFileBuffer?.extractFrameFromFile(at: scrubberPosition) { [weak self] image in
                guard let self = self, let image = image else { return }
                self.displayFrame(image)
            }
        }
    }
    
    @objc private func scrubberTouchEnded() {
        // Keep paused
    }
    
    @objc private func orientationDidChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.forceOrientationUpdate()
        }
    }
    
    private func forceOrientationUpdate() {
        guard let connection = previewLayer?.connection else { return }
        let interfaceOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        
        if isFrontCamera {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 0
            case .landscapeRight:
                connection.videoRotationAngle = 180
            case .portrait:
                connection.videoRotationAngle = 90
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
            default:
                connection.videoRotationAngle = 0
            }
        } else {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 180
            case .landscapeRight:
                connection.videoRotationAngle = 0
            case .portrait:
                connection.videoRotationAngle = 90
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
            default:
                connection.videoRotationAngle = 0
            }
        }
    }
    
    func startSession(delaySeconds: Int, useFrontCamera: Bool) {
        print("🎥 Starting session - delay: \(delaySeconds)s, front: \(useFrontCamera)")
        self.delaySeconds = delaySeconds
        self.isActive = true
        self.isFrontCamera = useFrontCamera
        self.isPaused = false
        
        // FIXED: Buffer needs to hold scrubbing window (30s) + delay + safety margin
        // The maxDuration determines when file rotation happens
        let maxDuration = 30 + delaySeconds + 10  // 30s scrubbing + delay + 10s safety margin
        videoFileBuffer = VideoFileBuffer(maxDurationSeconds: maxDuration, writeQueue: captureQueue)
        
        metadataLock.lock()
        frameMetadata.removeAll()
        metadataLock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupCamera(useFrontCamera: useFrontCamera)
        }
    }
    
    private func setupCamera(useFrontCamera: Bool) {
        captureSession = AVCaptureSession()
        
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high
            
            let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                print("❌ No camera found")
                self.captureSession.commitConfiguration()
                return
            }
            
            self.currentDevice = camera
            
            do {
                try camera.lockForConfiguration()
                
                for range in camera.activeFormat.videoSupportedFrameRateRanges {
                    if 30.0 >= range.minFrameRate && 30.0 <= range.maxFrameRate {
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        print("✅ Set to 30fps")
                        break
                    }
                }
                
                camera.unlockForConfiguration()
                
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    print("✅ Input added")
                } else {
                    print("❌ Cannot add input")
                    self.captureSession.commitConfiguration()
                    return
                }
                
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = false
                output.setSampleBufferDelegate(self, queue: self.captureQueue)
                
                if self.captureSession.canAddOutput(output) {
                    self.captureSession.addOutput(output)
                    print("✅ Output added")
                } else {
                    print("❌ Cannot add output")
                    self.captureSession.commitConfiguration()
                    return
                }
                
                self.videoDataOutput = output
                self.captureSession.commitConfiguration()
                
                try camera.lockForConfiguration()
                let savedZoom = Settings.shared.currentZoomFactor(isFrontCamera: useFrontCamera)
                let maxZoom = camera.activeFormat.videoMaxZoomFactor
                let minZoom = camera.minAvailableVideoZoomFactor
                let customMinZoom: CGFloat = 1.0
                let customMaxZoom: CGFloat = 10.0
                let effectiveMin = max(minZoom, customMinZoom)
                let effectiveMax = min(maxZoom, customMaxZoom)
                let clampedZoom = min(max(savedZoom, effectiveMin), effectiveMax)
                camera.videoZoomFactor = clampedZoom
                camera.unlockForConfiguration()
                print("🔍 Applied zoom: \(clampedZoom)x")
                
                // Setup video writer
                let videoWidth = 1920
                let videoHeight = 1080
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: videoWidth,
                    AVVideoHeightKey: videoHeight,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: videoWidth * videoHeight * 11,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 30
                    ]
                ]
                
                try self.videoFileBuffer?.startWriting(videoSettings: videoSettings, isInitialStart: true)
                
                DispatchQueue.main.async {
                    let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.bounds
                    self.layer.insertSublayer(preview, at: 0)
                    self.previewLayer = preview
                    
                    DispatchQueue.main.async {
                        self.forceOrientationUpdate()
                    }
                    
                    self.bringSubviewToFront(self.displayImageView)
                    self.bringSubviewToFront(self.countdownLabel)
                    self.bringSubviewToFront(self.countdownStopButton)
                    self.bringSubviewToFront(self.recordingIndicator)
                    self.bringSubviewToFront(self.controlsContainer)
                    print("✅ Preview layer added")
                    
                    self.captureQueue.async {
                        if !self.captureSession.isRunning {
                            self.captureSession.startRunning()
                            print("✅ Camera session RUNNING")
                        }
                        
                        // Start countdown on MAIN thread
                        DispatchQueue.main.async {
                            self.startCountdown()
                        }
                    }
                }
                
            } catch {
                print("❌ Camera setup error: \(error)")
                self.captureSession.commitConfiguration()
            }
        }
    }
    
    private func startCountdown() {
        var countdown = delaySeconds
        countdownLabel.text = "\(countdown)"
        countdownLabel.alpha = 1
        countdownStopButton.alpha = 1  // Show stop button during countdown
        
        print("⏱️ Starting countdown from \(countdown)")
        
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isActive else {
                timer.invalidate()
                return
            }
            
            countdown -= 1
            if countdown > 0 {
                self.countdownLabel.text = "\(countdown)"
                print("⏱️ Countdown: \(countdown)")
            } else {
                timer.invalidate()
                self.countdownLabel.text = "🎬"
                print("⏱️ Countdown complete!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.switchToDelayedView()
                }
            }
        }
    }
    
    private func switchToDelayedView() {
        print("🔄 Switching to delayed view")
        isShowingDelayed = true
        
        // Update the delay label with actual delay time
        if let delayLabel = recordingIndicator.viewWithTag(997) as? UILabel {
            delayLabel.text = "-\(delaySeconds)s"
        }
        
        startRecordingIndicator()  // This already handles the pulsing dot
        
        UIView.animate(withDuration: 0.5) {
            self.previewLayer?.opacity = 0
            self.displayImageView.alpha = 1
            self.countdownLabel.alpha = 0
            self.countdownStopButton.alpha = 0  // Hide countdown stop button
        }
        
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.updateDisplay()
        }
        
        RunLoop.main.add(displayTimer!, forMode: .common)
        print("✅ Display timer started")
    }
    
    private func updateDisplay() {
        guard isActive, isShowingDelayed, !isPaused else { return }
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let requiredFrames = delaySeconds * 30
        guard totalFrames >= requiredFrames, requiredFrames > 0 else { return }
        
        let index = totalFrames - requiredFrames
        guard index >= 0 && index < totalFrames else { return }
        
        currentDisplayFrameIndex = index
        
        // Get frame from memory cache
        if let image = videoFileBuffer?.getRecentFrame(at: index) {
            displayFrame(image)
        }
        
        DispatchQueue.main.async {
            self.scrubberSlider.value = 1.0
            self.timeLabel.text = "LIVE"
        }
    }
    
    private func displayFrame(_ rawImage: UIImage) {
        guard let cgImage = rawImage.cgImage else {
            displayImageView.image = rawImage
            return
        }
        
        let rotationAngle = previewLayer?.connection?.videoRotationAngle ?? 0
        
        let displayImage: UIImage
        switch rotationAngle {
        case 0:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        case 90:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        case 180:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .down)
        case 270:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .left)
        default:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        }
        
        DispatchQueue.main.async {
            self.displayImageView.image = displayImage
            if self.isFrontCamera {
                self.displayImageView.transform = CGAffineTransform(scaleX: -1, y: 1)
            } else {
                self.displayImageView.transform = .identity
            }
        }
    }
    
    func pausePlayback() {
        print("⏸️ Paused - Stopping capture")
        isPaused = true
        
        stopRecordingIndicator()  // ADD THIS LINE - Hide recording indicator when paused
        
        displayTimer?.fireDate = Date.distantFuture
        videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        
        // Finish writing so we can read from file
        videoFileBuffer?.pauseRecording { [weak self] fileURL in
            guard let self = self else { return }
            if fileURL != nil {
                print("✅ File ready for scrubbing")
            } else {
                print("⚠️ File not ready, scrubbing may not work")
            }
        }
        
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "play.fill", withConfiguration: config)
        playPauseButton.setImage(image, for: .normal)
        
        scrubberSlider.value = 1.0
        timeLabel.text = "0.0s"
        
        showControls()
        hideControlsTimer?.invalidate()
    }
    
    func resumePlayback() {
        print("▶️ Resuming - Starting new countdown")
        isPaused = false
        isShowingDelayed = false
        
        videoDataOutput?.setSampleBufferDelegate(self, queue: captureQueue)
        
        metadataLock.lock()
        frameMetadata.removeAll()
        metadataLock.unlock()
        
        // FIXED: Same calculation as startSession
        let maxDuration = 30 + delaySeconds + 10
        videoFileBuffer = VideoFileBuffer(maxDurationSeconds: maxDuration, writeQueue: captureQueue)
        
        let videoWidth = 1920
        let videoHeight = 1080
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoWidth * videoHeight * 11,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        try? videoFileBuffer?.startWriting(videoSettings: videoSettings, isInitialStart: true)
        
        hideControls()
        
        displayTimer?.invalidate()
        displayTimer = nil
        
        UIView.animate(withDuration: 0.3) {
            self.previewLayer?.opacity = 1
            self.displayImageView.alpha = 0
        }
        
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "pause.fill", withConfiguration: config)
        playPauseButton.setImage(image, for: .normal)
        
        startCountdown()
    }
    
    func stopSession() {
        print("🛑 Stopping session")
        isActive = false
        isShowingDelayed = false
        isPaused = false
        
        stopRecordingIndicator()  // ADD THIS LINE - Hide recording indicator when session stops
        
        displayTimer?.invalidate()
        displayTimer = nil
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.captureSession?.isRunning == true {
                self.captureSession?.stopRunning()
                print("✅ Capture session stopped")
            }
            
            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.captureSession = nil
                self.videoDataOutput = nil
                self.previewLayer = nil
                self.controlsContainer.alpha = 0
                self.countdownStopButton.alpha = 0
                
                // NEW: Notify HomeViewController that session stopped
                self.onSessionStopped?()
            }
            
            self.videoFileBuffer?.stopWriting {
                print("✅ Video file buffer stopped")
            }
        }
        
        metadataLock.lock()
        frameMetadata.removeAll()
        metadataLock.unlock()
        
        displayImageView.image = nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension DelayedCameraView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isActive, !isPaused else { return }
        
        videoFileBuffer?.appendFrame(sampleBuffer: sampleBuffer) { [weak self] success in
            guard let self = self, success else { return }
            
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            self.metadataLock.lock()
            let frameIndex = self.frameMetadata.count
            self.frameMetadata.append((timestamp: timestamp, index: frameIndex))
            
            let count = self.frameMetadata.count
            self.metadataLock.unlock()
            
            if count == 1 {
                print("🎬 First frame captured to file!")
            } else if count % 300 == 0 {
                print("📹 Metadata: \(count) frames (~\(count/30)s)")
            }
        }
    }
}


