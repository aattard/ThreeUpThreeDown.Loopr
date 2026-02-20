import UIKit
import AVFoundation

final class DelayedCameraView: UIView {

    // MARK: - Capture

    private var captureSession: AVCaptureSession!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var isFrontCamera: Bool = false
    private var currentDevice: AVCaptureDevice?

    var onSessionStopped: (() -> Void)?

    // MARK: - Buffer

    private var videoFileBuffer: VideoFileBuffer?

    // MARK: - State

    private var delaySeconds: Int = 7
    private var isActive: Bool = false
    private var isShowingDelayed: Bool = false
    private var isPaused: Bool = false

    // MARK: - Recording indicator

    private var recordingDurationTimer: Timer?
    private var recordingStartTime: TimeInterval = 0

    // MARK: - Live-delay display

    private var displayTimer: Timer?
    private var displayImageView: UIImageView!

    // MARK: - Activity check

    private var activityCheckTimer: Timer?
    private var activityCountdownTimer: Timer?
    private var activityTimeRemaining: Int = 60
    private let activityCheckInterval: TimeInterval = 2700

    // MARK: - Queues / context

    private lazy var captureQueue = DispatchQueue(label: "com.loopr.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Child view (recorded playback UI)

    private let recordedView = RecordedVideoView()

    // MARK: - UI — countdown / pause overlay

    private let countdownLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 120, weight: .bold)
        l.textColor = .white
        l.textAlignment = .center
        l.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        l.layer.cornerRadius = 20
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let countdownStopButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        b.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = .black
        b.layer.borderWidth = 2
        b.layer.borderColor = UIColor.black.cgColor
        b.layer.cornerRadius = 60
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let livePauseButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        b.setImage(UIImage(systemName: "pause.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        b.layer.cornerRadius = 60
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        b.alpha = 0
        return b
    }()

    // MARK: - UI — recording indicator (LIVE / -Xs / duration)

    private let recordingIndicator: UIView = {
        let c = UIView()
        c.backgroundColor = .systemRed
        c.layer.cornerRadius = 18
        c.translatesAutoresizingMaskIntoConstraints = false
        c.alpha = 0

        let dot = UIView()
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.tag = 999

        let live = UILabel()
        live.text = "LIVE"
        live.textColor = .white
        live.font = .systemFont(ofSize: 14, weight: .bold)
        live.translatesAutoresizingMaskIntoConstraints = false
        live.tag = 998

        let bg = UIView()
        bg.backgroundColor = .white
        bg.layer.cornerRadius = 8
        bg.translatesAutoresizingMaskIntoConstraints = false

        let delay = UILabel()
        delay.text = "-7s"
        delay.textColor = .systemRed
        delay.font = .monospacedDigitSystemFont(ofSize: 12, weight: .heavy)
        delay.textAlignment = .center
        delay.translatesAutoresizingMaskIntoConstraints = false
        delay.tag = 997

        let dur = UILabel()
        dur.text = "00:00:00"
        dur.textColor = .white
        dur.font = .monospacedDigitSystemFont(ofSize: 14, weight: .light)
        dur.translatesAutoresizingMaskIntoConstraints = false
        dur.tag = 996

        c.addSubview(dot)
        c.addSubview(live)
        c.addSubview(bg)
        bg.addSubview(delay)
        c.addSubview(dur)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            live.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            live.centerYAnchor.constraint(equalTo: c.centerYAnchor),

            bg.leadingAnchor.constraint(equalTo: live.trailingAnchor, constant: 5),
            bg.centerYAnchor.constraint(equalTo: c.centerYAnchor),

            delay.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4),
            delay.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
            delay.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            delay.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),

            dur.leadingAnchor.constraint(equalTo: bg.trailingAnchor, constant: 6),
            dur.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            dur.centerYAnchor.constraint(equalTo: c.centerYAnchor)
        ])

        return c
    }()

    // MARK: - UI — activity alert

    private lazy var activityAlertContainer: UIView = {
        let c = UIView()
        c.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        c.layer.cornerRadius = 20
        c.clipsToBounds = true
        c.translatesAutoresizingMaskIntoConstraints = false
        c.alpha = 0

        let msg = UILabel()
        msg.text = "Are you still there?"
        msg.font = .systemFont(ofSize: 32, weight: .semibold)
        msg.textColor = .white
        msg.textAlignment = .center
        msg.numberOfLines = 0
        msg.translatesAutoresizingMaskIntoConstraints = false

        let yes = UIButton(type: .system)
        yes.setTitle("Yes, Continue", for: .normal)
        yes.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        yes.setTitleColor(.white, for: .normal)
        yes.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        yes.layer.cornerRadius = 12
        yes.layer.borderWidth = 1
        yes.layer.borderColor = UIColor.black.cgColor
        yes.clipsToBounds = true
        yes.translatesAutoresizingMaskIntoConstraints = false
        yes.tag = 1001

        let prog = UIView()
        prog.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        prog.translatesAutoresizingMaskIntoConstraints = false
        prog.tag = 1002
        yes.insertSubview(prog, at: 0)

        let no = UIButton(type: .system)
        no.setTitle("No, Pause", for: .normal)
        no.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        no.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .normal)
        no.translatesAutoresizingMaskIntoConstraints = false
        no.tag = 1003

        c.addSubview(msg)
        c.addSubview(yes)
        c.addSubview(no)

        NSLayoutConstraint.activate([
            msg.topAnchor.constraint(equalTo: c.topAnchor, constant: 40),
            msg.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 30),
            msg.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -30),

            yes.topAnchor.constraint(equalTo: msg.bottomAnchor, constant: 40),
            yes.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 30),
            yes.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -30),
            yes.heightAnchor.constraint(equalToConstant: 56),

            prog.leadingAnchor.constraint(equalTo: yes.leadingAnchor),
            prog.topAnchor.constraint(equalTo: yes.topAnchor),
            prog.bottomAnchor.constraint(equalTo: yes.bottomAnchor),

            no.topAnchor.constraint(equalTo: yes.bottomAnchor, constant: 10),
            no.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            no.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10)
        ])

        yes.addTarget(self, action: #selector(activityYesTapped), for: .touchUpInside)
        no.addTarget(self, action: #selector(activityNoTapped), for: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(activityBackgroundTapped(_:)))
        c.addGestureRecognizer(tap)

        return c
    }()

    private var activityProgressConstraint: NSLayoutConstraint?

    // MARK: - Init

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

        recordedView.translatesAutoresizingMaskIntoConstraints = false
        recordedView.alpha = 0
        addSubview(recordedView)

        addSubview(countdownLabel)
        addSubview(countdownStopButton)
        addSubview(livePauseButton)
        addSubview(recordingIndicator)
        addSubview(activityAlertContainer)

        NSLayoutConstraint.activate([
            recordedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordedView.topAnchor.constraint(equalTo: topAnchor),
            recordedView.bottomAnchor.constraint(equalTo: bottomAnchor),

            countdownLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),
            countdownLabel.widthAnchor.constraint(equalToConstant: 200),
            countdownLabel.heightAnchor.constraint(equalToConstant: 200),

            countdownStopButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownStopButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            countdownStopButton.widthAnchor.constraint(equalToConstant: 120),
            countdownStopButton.heightAnchor.constraint(equalToConstant: 120),

            livePauseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            livePauseButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            livePauseButton.widthAnchor.constraint(equalToConstant: 120),
            livePauseButton.heightAnchor.constraint(equalToConstant: 120),

            recordingIndicator.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            recordingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            recordingIndicator.heightAnchor.constraint(equalToConstant: 36),
            recordingIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),

            activityAlertContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityAlertContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityAlertContainer.widthAnchor.constraint(equalToConstant: 340)
        ])

        countdownStopButton.addTarget(self, action: #selector(countdownStopTapped), for: .touchUpInside)
        livePauseButton.addTarget(self, action: #selector(livePauseTapped), for: .touchUpInside)

        recordedView.onRestartRequested = { [weak self] in self?.restartCountdown() }
        recordedView.onStopSessionRequested = { [weak self] in self?.stopSession() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        recordingDurationTimer?.invalidate()
        activityCheckTimer?.invalidate()
        activityCountdownTimer?.invalidate()
        displayTimer?.invalidate()
        recordedView.resetUIAndTearDown()
        videoFileBuffer?.cleanup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayImageView.frame = bounds
        previewLayer?.frame = bounds
        recordedView.applyPlayerTransformNow()
    }

    // MARK: - Public API

    func startSession(delaySeconds: Int, useFrontCamera: Bool) {
        self.delaySeconds = delaySeconds
        self.isActive = true
        self.isFrontCamera = useFrontCamera
        self.isPaused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupCamera(useFrontCamera: useFrontCamera)
        }
    }

    func stopSession() {
        guard isActive else { return }

        isActive = false
        isShowingDelayed = false
        isPaused = false

        displayTimer?.invalidate(); displayTimer = nil
        stopRecordingIndicator()
        hideLivePauseButton()
        hideActivityAlert()

        recordedView.resetUIAndTearDown()
        recordedView.alpha = 0

        captureQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession?.stopRunning()
            let old = self.videoFileBuffer
            self.videoFileBuffer = nil
            old?.cleanup()

            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.previewLayer = nil
                self.displayImageView.alpha = 0
                self.onSessionStopped?()
            }
        }
    }

    // MARK: - Camera setup

    private func setupCamera(useFrontCamera: Bool) {
        captureSession = AVCaptureSession()

        captureQueue.async { [weak self] in
            guard let self else { return }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            let pos: AVCaptureDevice.Position = useFrontCamera ? .front : .back
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) else {
                self.captureSession.commitConfiguration()
                return
            }
            self.currentDevice = camera

            let actualFPS = Settings.shared.currentFPS(isFrontCamera: useFrontCamera)

            do {
                try camera.lockForConfiguration()
                var fpsSet = false
                for r in camera.activeFormat.videoSupportedFrameRateRanges {
                    if Double(actualFPS) >= r.minFrameRate && Double(actualFPS) <= r.maxFrameRate {
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        fpsSet = true
                        break
                    }
                }
                if !fpsSet {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    Settings.shared.setFPS(30, isFrontCamera: useFrontCamera)
                }
                camera.unlockForConfiguration()
            } catch { }

            let maxDuration = Settings.shared.bufferDurationSeconds + self.delaySeconds + 10
            self.videoFileBuffer = VideoFileBuffer(
                maxDurationSeconds: maxDuration,
                delaySeconds: self.delaySeconds,
                fps: actualFPS,
                writeQueue: self.captureQueue,
                ciContext: self.ciContext
            )

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) { self.captureSession.addInput(input) }
            } catch {
                self.captureSession.commitConfiguration()
                return
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            if self.captureSession.canAddOutput(output) {
                self.captureSession.addOutput(output)
            }
            self.videoDataOutput = output
            self.captureSession.commitConfiguration()

            do {
                try camera.lockForConfiguration()
                let saved = Settings.shared.currentZoomFactor(isFrontCamera: useFrontCamera)
                let clamped = min(max(saved, camera.minAvailableVideoZoomFactor),
                                  min(camera.activeFormat.videoMaxZoomFactor, 10.0))
                camera.videoZoomFactor = clamped
                camera.unlockForConfiguration()
            } catch { }

            let videoWidth = 1920, videoHeight = 1080
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoWidth * videoHeight * 11,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: actualFPS,
                    AVVideoMaxKeyFrameIntervalKey: actualFPS
                ]
            ]

            try? self.videoFileBuffer?.startWriting(videoSettings: videoSettings, isInitialStart: true)

            DispatchQueue.main.async {
                let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.bounds
                self.layer.insertSublayer(preview, at: 0)
                self.previewLayer = preview
                self.forceOrientationUpdate()

                // Bring UI layers to front.
                for v in [self.displayImageView!, self.countdownLabel, self.countdownStopButton,
                          self.livePauseButton, self.recordingIndicator,
                          self.recordedView, self.activityAlertContainer] as [UIView] {
                    self.bringSubviewToFront(v)
                }
            }

            self.captureQueue.async {
                if !self.captureSession.isRunning { self.captureSession.startRunning() }
                DispatchQueue.main.async { self.startCountdown() }
            }
        }
    }

    // MARK: - Display

    private func startCountdown() {
        var countdown = delaySeconds
        countdownLabel.text = "\(countdown)"
        countdownLabel.alpha = 1
        countdownStopButton.alpha = 1

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.isActive else { timer.invalidate(); return }
            countdown -= 1
            if countdown <= 0 {
                timer.invalidate()
                self.countdownLabel.alpha = 0
                self.countdownStopButton.alpha = 0
                self.startDelayedDisplay()
            } else {
                self.countdownLabel.text = "\(countdown)"
            }
        }
    }

    private func startDelayedDisplay() {
        isShowingDelayed = true

        if let lbl = recordingIndicator.viewWithTag(997) as? UILabel {
            lbl.text = "-\(delaySeconds)s"
        }
        recordingStartTime = CACurrentMediaTime()
        recordingDurationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRecordingDuration()
        }
        startRecordingIndicator()

        UIView.animate(withDuration: 0.3) {
            self.displayImageView.alpha = 1
            self.previewLayer?.opacity = 0
        }

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let delayFrames = delaySeconds * actualFPS
        let frameInterval = 1.0 / Double(actualFPS)

        displayTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            guard let self, let buf = self.videoFileBuffer else { return }
            let total = buf.getCurrentFrameCount()
            let target = total - delayFrames
            guard target >= 0 else { return }
            if let img = buf.getRecentFrame(at: target) {
                self.displayFrame(img)
            }
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
        showLivePauseButton()
        startActivityCheckTimer()
    }

    private func displayFrame(_ rawImage: UIImage) {
        guard let cg = rawImage.cgImage else {
            DispatchQueue.main.async { self.displayImageView.image = rawImage }
            return
        }

        let angle = previewLayer?.connection?.videoRotationAngle ?? 0
        let ori = VideoPlaybackHelpers.imageOrientation(forRotationAngle: angle)
        let img = UIImage(cgImage: cg, scale: 1.0, orientation: ori)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayImageView.image = img
            self.displayImageView.transform = self.isFrontCamera ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        }
    }

    // MARK: - Actions

    @objc private func handleTap() {
        guard isShowingDelayed, !isPaused else { return }
        restartActivityCheckTimer()
        livePauseButton.alpha == 0 ? showLivePauseButton() : hideLivePauseButton()
    }

    @objc private func livePauseTapped() { pausePlayback() }
    @objc private func countdownStopTapped() { stopSession() }

    private func pausePlayback() {
        guard !isPaused, isShowingDelayed else { return }

        captureSession?.stopRunning()
        isPaused = true
        displayTimer?.invalidate(); displayTimer = nil

        stopRecordingIndicator()
        hideLivePauseButton()
        activityCheckTimer?.invalidate()
        activityCountdownTimer?.invalidate()

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        
        videoFileBuffer?.pauseRecording { [weak self] item, composition in
            guard let self else { return }
            guard let item, let composition, let buf = self.videoFileBuffer else {
                print("❌ pauseRecording returned nil")
                return
            }

            let totalFrames = buf.getTimestampCount()
            let requiredFrames = self.delaySeconds * actualFPS
            let pausePoint = max(0, totalFrames - requiredFrames)
            let initialScrubberIndex = max(0, pausePoint - 1)

            let recordedSeconds = totalFrames / max(actualFPS, 1)
            let bufferDurationSeconds = Settings.shared.bufferDurationSeconds

            self.recordedView.presentPausedRecording(
                buffer: buf,
                playerItem: item,
                composition: composition,
                delaySeconds: self.delaySeconds,
                isFrontCamera: self.isFrontCamera,
                //rotationAngleProvider: { [weak self] in
                //    self?.previewLayer?.connection?.videoRotationAngle ?? 0
                //},
                recordedRotationAngle: self.previewLayer?.connection?.videoRotationAngle ?? 0,
                initialScrubberIndex: initialScrubberIndex,
                recordedSeconds: recordedSeconds,
                bufferDurationSeconds: bufferDurationSeconds
            )

            UIView.animate(withDuration: 0.3) {
                self.recordedView.alpha = 1
                self.displayImageView.alpha = 0
            }
        }
    }

    private func restartCountdown() {
        hideActivityAlert()
        activityCheckTimer?.invalidate()
        activityCountdownTimer?.invalidate()
        stopRecordingIndicator()
        displayTimer?.invalidate()
        displayTimer = nil

        recordedView.resetUIAndTearDown()
        UIView.animate(withDuration: 0.3) {
            self.recordedView.alpha = 0
        }

        isPaused = false
        isShowingDelayed = false
        isActive = false

        if let durationLabel = recordingIndicator.viewWithTag(996) as? UILabel {
            durationLabel.text = "00:00:00"
        }

        let savedDelay = delaySeconds
        let savedFront = isFrontCamera

        captureQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession?.stopRunning()

            let oldBuffer = self.videoFileBuffer
            self.videoFileBuffer = nil
            oldBuffer?.cleanup()

            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.previewLayer = nil

                if let session = self.captureSession {
                    session.beginConfiguration()
                    session.inputs.forEach { session.removeInput($0) }
                    session.outputs.forEach { session.removeOutput($0) }
                    session.commitConfiguration()
                }
                self.captureSession = nil
                self.videoDataOutput = nil
                self.currentDevice = nil
                self.displayImageView.alpha = 0

                self.isActive = true
                self.isFrontCamera = savedFront
                self.delaySeconds = savedDelay
                self.isPaused = false

                self.setupCamera(useFrontCamera: savedFront)
            }
        }
    }

    // MARK: - UI Helpers

    private func showLivePauseButton() {
        UIView.animate(withDuration: 0.3) { self.livePauseButton.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.isPaused else { return }
            self.hideLivePauseButton()
        }
    }

    private func hideLivePauseButton() {
        UIView.animate(withDuration: 0.3) { self.livePauseButton.alpha = 0 }
    }

    private func startRecordingIndicator() {
        UIView.animate(withDuration: 0.3) { self.recordingIndicator.alpha = 1 }
        if let dot = recordingIndicator.viewWithTag(999) {
            let b = CABasicAnimation(keyPath: "opacity")
            b.fromValue = 1.0; b.toValue = 0.0; b.duration = 0.8
            b.repeatCount = .infinity; b.autoreverses = true
            dot.layer.add(b, forKey: "blinking")
        }
    }

    private func updateRecordingDuration() {
        guard let lbl = recordingIndicator.viewWithTag(996) as? UILabel else { return }
        let e = CACurrentMediaTime() - recordingStartTime
        lbl.text = String(format: "%02d:%02d:%02d", Int(e) / 3600, (Int(e) % 3600) / 60, Int(e) % 60)
    }

    private func stopRecordingIndicator() {
        recordingDurationTimer?.invalidate(); recordingDurationTimer = nil
        recordingIndicator.viewWithTag(999)?.layer.removeAnimation(forKey: "blinking")
        UIView.animate(withDuration: 0.3) { self.recordingIndicator.alpha = 0 }
    }

    // MARK: - Activity check

    private func startActivityCheckTimer() {
        activityCheckTimer?.invalidate()
        activityCheckTimer = Timer.scheduledTimer(withTimeInterval: activityCheckInterval, repeats: false) { [weak self] _ in
            self?.showActivityAlert()
        }
    }

    private func restartActivityCheckTimer() {
        if activityAlertContainer.alpha > 0 { return }
        startActivityCheckTimer()
    }

    private func showActivityAlert() {
        guard !isPaused else { return }
        activityTimeRemaining = 60
        updateActivityProgress(animated: false)

        UIView.animate(withDuration: 0.3) { self.activityAlertContainer.alpha = 1 }

        activityCountdownTimer?.invalidate()
        activityCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.activityTimeRemaining -= 1
            self.updateActivityProgress(animated: true)

            if self.activityTimeRemaining <= 0 {
                timer.invalidate()
                self.hideActivityAlert()
                self.pausePlayback()
            }
        }
    }

    private func hideActivityAlert() {
        UIView.animate(withDuration: 0.3) { self.activityAlertContainer.alpha = 0 }
        activityCountdownTimer?.invalidate()
    }

    private func updateActivityProgress(animated: Bool) {
        guard let btn = activityAlertContainer.viewWithTag(1001),
              let prog = btn.viewWithTag(1002) else { return }

        let fraction = CGFloat(activityTimeRemaining) / 60.0
        let newWidth = btn.bounds.width * fraction

        if activityProgressConstraint == nil {
            activityProgressConstraint = prog.widthAnchor.constraint(equalToConstant: newWidth)
            activityProgressConstraint?.isActive = true
        }

        if animated {
            UIView.animate(withDuration: 0.9, delay: 0, options: .curveLinear) {
                self.activityProgressConstraint?.constant = newWidth
                btn.layoutIfNeeded()
            }
        } else {
            activityProgressConstraint?.constant = newWidth
            btn.layoutIfNeeded()
        }
    }

    @objc private func activityYesTapped() {
        activityCountdownTimer?.invalidate()
        hideActivityAlert()
        restartActivityCheckTimer()
    }

    @objc private func activityNoTapped() {
        activityCountdownTimer?.invalidate()
        hideActivityAlert()
        pausePlayback()
    }

    @objc private func activityBackgroundTapped(_ gesture: UITapGestureRecognizer) {}

    // MARK: - Orientation

    private func forceOrientationUpdate() {
        guard let conn = previewLayer?.connection else { return }
        let ori = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        if isFrontCamera {
            switch ori {
            case .landscapeLeft:      conn.videoRotationAngle = 0
            case .landscapeRight:     conn.videoRotationAngle = 180
            case .portrait:           conn.videoRotationAngle = 90
            case .portraitUpsideDown: conn.videoRotationAngle = 270
            default:                  conn.videoRotationAngle = 0
            }
        } else {
            switch ori {
            case .landscapeLeft:      conn.videoRotationAngle = 180
            case .landscapeRight:     conn.videoRotationAngle = 0
            case .portrait:           conn.videoRotationAngle = 90
            case .portraitUpsideDown: conn.videoRotationAngle = 270
            default:                  conn.videoRotationAngle = 0
            }
        }
    }

    @objc private func orientationDidChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.forceOrientationUpdate()
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension DelayedCameraView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isActive, !isPaused, let buf = videoFileBuffer else { return }
        buf.appendFrame(sampleBuffer: sampleBuffer) { _ in }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}
}

