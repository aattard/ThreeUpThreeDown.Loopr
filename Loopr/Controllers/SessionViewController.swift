import UIKit
import AVFoundation

class SessionViewController: UIViewController {
    
    private var cameraView: DelayedCameraView!
    private var sessionTimer: Timer?
    private var sessionStartTime: Date?
    private var sessionDuration: TimeInterval = 0
    private var isBuffering = true
    private var isPaused = false
    private var hideControlsTimer: Timer?
    private var showControls = true
    
    // UI Elements
    private let statusBadge: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        label.textColor = .black
        label.textAlignment = .center
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let timerLabel: UILabel = {
        let label = UILabel()
        label.text = "00:00"
        label.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let delayLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let bufferingView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let bufferingLabel: UILabel = {
        let label = UILabel()
        label.text = "Buffering..."
        label.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let bufferingProgress: UILabel = {
        let label = UILabel()
        label.text = "7s remaining"
        label.font = UIFont.systemFont(ofSize: 16)
        label.textColor = .lightGray
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("✕", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 32, weight: .regular)
        button.setTitleColor(.white, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let pauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Pause", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let endButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("End Session", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let hudOverlay: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        setupCameraView()
        setupBufferingView()
        setupHUD()
        setupActions()
        
        // Request camera permission and start
        requestCameraPermission()
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .landscapeRight
    }
    
    private func setupCameraView() {
        cameraView = DelayedCameraView(frame: view.bounds)
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraView)
        
        NSLayoutConstraint.activate([
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupBufferingView() {
        view.addSubview(bufferingView)
        
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        bufferingView.addSubview(spinner)
        bufferingView.addSubview(bufferingLabel)
        bufferingView.addSubview(bufferingProgress)
        
        NSLayoutConstraint.activate([
            bufferingView.topAnchor.constraint(equalTo: view.topAnchor),
            bufferingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bufferingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bufferingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            spinner.centerXAnchor.constraint(equalTo: bufferingView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: bufferingView.centerYAnchor, constant: -40),
            
            bufferingLabel.centerXAnchor.constraint(equalTo: bufferingView.centerXAnchor),
            bufferingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 24),
            
            bufferingProgress.centerXAnchor.constraint(equalTo: bufferingView.centerXAnchor),
            bufferingProgress.topAnchor.constraint(equalTo: bufferingLabel.bottomAnchor, constant: 12)
        ])
    }
    
    private func setupHUD() {
        view.addSubview(hudOverlay)
        hudOverlay.addSubview(statusBadge)
        hudOverlay.addSubview(timerLabel)
        hudOverlay.addSubview(delayLabel)
        hudOverlay.addSubview(closeButton)
        hudOverlay.addSubview(pauseButton)
        hudOverlay.addSubview(endButton)
        
        NSLayoutConstraint.activate([
            hudOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            hudOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hudOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hudOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // Top bar
            statusBadge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusBadge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            statusBadge.heightAnchor.constraint(equalToConstant: 32),
            
            timerLabel.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
            timerLabel.leadingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: 16),
            
            delayLabel.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
            delayLabel.leadingAnchor.constraint(equalTo: timerLabel.trailingAnchor, constant: 16),
            
            closeButton.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            // Bottom controls
            pauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            pauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -130),
            pauseButton.widthAnchor.constraint(equalToConstant: 120),
            pauseButton.heightAnchor.constraint(equalToConstant: 50),
            
            endButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            endButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 130),
            endButton.widthAnchor.constraint(equalToConstant: 140),
            endButton.heightAnchor.constraint(equalToConstant: 50)
        ])
        
        hudOverlay.isHidden = true
    }
    
    private func setupActions() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        endButton.addTarget(self, action: #selector(endTapped), for: .touchUpInside)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(screenTapped))
        view.addGestureRecognizer(tapGesture)
    }
    
    private func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        if status == .authorized {
            // Already authorized, start immediately
            startCameraSession()
        } else if status == .notDetermined {
            // Request permission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        // Small delay to ensure system is ready
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self?.startCameraSession()
                        }
                    } else {
                        print("❌ Camera permission denied")
                    }
                }
            }
        } else {
            print("❌ Camera permission previously denied")
        }
    }

    
    private func startCameraSession() {
        let settings = Settings.shared
        sessionStartTime = Date()
        
        // Update delay label
        delayLabel.text = "Delay: \(settings.playbackDelay)s"
        
        // Start camera
        cameraView.startSession(delaySeconds: settings.playbackDelay,
                               useFrontCamera: settings.useFrontCamera)
        
        // Start buffering countdown
        startBufferingCountdown(duration: settings.playbackDelay)
        
        // Start session timer
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateSessionTimer()
        }
    }
    
    private func startBufferingCountdown(duration: Int) {
        var remaining = duration
        bufferingProgress.text = "\(remaining)s remaining"
        
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            
            if remaining > 0 {
                self?.bufferingProgress.text = "\(remaining)s remaining"
            } else {
                timer.invalidate()
                self?.finishBuffering()
            }
        }
    }
    
    private func finishBuffering() {
        isBuffering = false
        bufferingView.isHidden = true
        hudOverlay.isHidden = false
        updateStatusBadge()
        resetHideControlsTimer()
    }
    
    private func updateSessionTimer() {
        guard let startTime = sessionStartTime else { return }
        sessionDuration = Date().timeIntervalSince(startTime)
        
        let minutes = Int(sessionDuration) / 60
        let seconds = Int(sessionDuration) % 60
        timerLabel.text = String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func updateStatusBadge() {
        if isPaused {
            statusBadge.text = "PAUSED"
            statusBadge.backgroundColor = .systemYellow
        } else {
            statusBadge.text = "DELAYED"
            statusBadge.backgroundColor = .systemGreen
        }
    }
    
    @objc private func pauseTapped() {
        isPaused.toggle()
        
        if isPaused {
            cameraView.pausePlayback()
            pauseButton.setTitle("Resume", for: .normal)
        } else {
            cameraView.resumePlayback()
            pauseButton.setTitle("Pause", for: .normal)
        }
        
        updateStatusBadge()
    }
    
    @objc private func endTapped() {
        stopSession()
        dismiss(animated: true)
    }
    
    @objc private func closeTapped() {
        stopSession()
        dismiss(animated: true)
    }
    
    @objc private func screenTapped() {
        resetHideControlsTimer()
    }
    
    private func resetHideControlsTimer() {
        guard !isBuffering else { return }
        
        showControls = true
        hudOverlay.alpha = 1.0
        
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.3) {
                self?.hudOverlay.alpha = 0.0
            }
        }
    }
    
    private func stopSession() {
        sessionTimer?.invalidate()
        hideControlsTimer?.invalidate()
        cameraView.stopSession()
    }
    
    deinit {
        stopSession()
    }
}

