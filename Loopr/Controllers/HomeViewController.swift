import UIKit
import AVFoundation

class HomeViewController: UIViewController, UIViewControllerTransitioningDelegate {
    
    private var cameraPreviewView: LiveCameraPreviewView!
    private var delayedCameraView: DelayedCameraView?
    
    // Callback to notify when camera preview is ready
    var onCameraPreviewReady: (() -> Void)?
    
    private let logoImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(named: "inapp-logo")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()
    
    private let startButton: UIButton = {
        let button = UIButton(type: .system)
        
        let config = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        let image = UIImage(systemName: "play.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        
        button.tintColor = .white
        button.backgroundColor = .black
        
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.black.cgColor
        button.layer.cornerRadius = 60
        button.clipsToBounds = true
        
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    // Control buttons container - positioned above start button
    private let controlsStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    // Circular icon-only button for camera flip
    private let flipButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = UIImage(systemName: "camera.rotate", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 25
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }()
    
    // Ultra-wide toggle button — only shown when hardware supports it
    private let ultraWideButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        // Default icon: expand arrows = go to ultra-wide
        let image = UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 25
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isHidden = true  // Hidden until we confirm hardware support
        return button
    }()
    
    // Pill: 🔍 magnifyingglass + zoom value
    private let zoomButton: UIButton = makePillButton(
        icon: "magnifyingglass",
        title: "1.0×"
    )
    
    // Pill: ⏱ timer + delay value (e.g. "7s")
    private let delayButton: UIButton = makePillButton(
        icon: "timer",
        title: "7s"
    )
    
    // Pill: ⏺ record.circle + buffer duration (e.g. "1m")
    private let bufferButton: UIButton = makePillButton(
        icon: "record.circle",
        title: "1m"
    )
    
    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Pill Button Factory
    // ─────────────────────────────────────────────────────────────────────

    private static func makePillButton(icon: String, title: String) -> UIButton {
        let button = UIButton(type: .system)
        
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = UIImage(systemName: icon, withConfiguration: iconConfig)
        button.setImage(image, for: .normal)
        
        button.setTitle(" \(title)", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        button.layer.cornerRadius = 25
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Info Button
    private let infoButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let image = UIImage(systemName: "info.circle", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Trial badge
    // ─────────────────────────────────────────────────────────────────────
    private let trialBadgeButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private var isSessionActive = false
    /// True during the brief hardware-release delay after a session stops.
    /// Prevents a new session starting before the OS reclaims the camera.
    private var isTearingDown = false
    
    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Lifecycle
    // ─────────────────────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        print("✅ HomeViewController created")
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true
        setupUI()

        cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera) { [weak self] in
            print("✅ Home camera preview fully ready")
            self?.onCameraPreviewReady?()
        }

        Task {
            await PurchaseManager.shared.initialize()
            await MainActor.run { self.updateTrialBadge() }
        }
    }

    private func checkCameraPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera) { [weak self] in
                print("✅ Home camera preview fully ready")
                self?.onCameraPreviewReady?()
            }

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera) {
                            print("✅ Home camera preview fully ready")
                            self?.onCameraPreviewReady?()
                        }
                    } else {
                        self?.showCameraPermissionAlert()
                    }
                }
            }

        default:
            showCameraPermissionAlert()
        }
    }

    private func showCameraPermissionAlert() {
        let alert = UIAlertController(
            title: "Camera Access Required",
            message: "Loopr needs camera access to record your swing. Tap Open Settings, then enable Camera for Loopr.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        present(alert, animated: true)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateTrialBadge()

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            showCameraPermissionAlert()
        }

        // Consume a pending Universal Link that arrived during cold launch
        if let scene = view.window?.windowScene?.delegate as? SceneDelegate,
           scene.pendingUniversalLink {
            scene.pendingUniversalLink = false
            handleUniversalLinkStart()
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Universal Link Entry Point
    // ─────────────────────────────────────────────────────────────────────

    func handleUniversalLinkStart() {
        // Respect the paywall — same gate as the play button
        guard !isSessionActive, !isTearingDown else { return }

        if !PurchaseManager.shared.canStartSession() {
            showPaywall()
            return
        }

        beginSession()
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Trial Badge
    // ─────────────────────────────────────────────────────────────────────

    private func updateTrialBadge() {
        switch PurchaseManager.shared.accessState {
        case .trial(let days):
            trialBadgeButton.isHidden = false
            let label = days == 1 ? "1 free day left" : "\(days) free days left"
            trialBadgeButton.setTitle(label, for: .normal)
            trialBadgeButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        case .expired:
            trialBadgeButton.isHidden = false
            trialBadgeButton.setTitle("Trial Expired", for: .normal)
            trialBadgeButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.9)
        case .purchased:
            trialBadgeButton.isHidden = true
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - UI Setup
    // ─────────────────────────────────────────────────────────────────────

    private func setupUI() {
        print("🔧 Setting up UI...")
        
        // Camera preview (full screen, always visible)
        cameraPreviewView = LiveCameraPreviewView(frame: view.bounds)
        cameraPreviewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cameraPreviewView)
        
        // Add pinch gesture for zoom
        cameraPreviewView.addPinchGesture()
        
        // Logo at top
        view.addSubview(logoImageView)
        
        // Control buttons in stack view
        // Order: flip | ultraWide (if available) | zoom | delay | buffer
        controlsStackView.addArrangedSubview(flipButton)
        controlsStackView.addArrangedSubview(ultraWideButton)
        controlsStackView.addArrangedSubview(zoomButton)
        controlsStackView.addArrangedSubview(delayButton)
        controlsStackView.addArrangedSubview(bufferButton)
        view.addSubview(controlsStackView)
        
        // Info button - standalone in top right
        view.addSubview(infoButton)

        // Trial badge - bottom left
        view.addSubview(trialBadgeButton)
        
        // Start button
        view.addSubview(startButton)
        
        // Button actions
        startButton.addTarget(self, action: #selector(startSessionTapped), for: .touchUpInside)
        flipButton.addTarget(self, action: #selector(flipCameraTapped), for: .touchUpInside)
        ultraWideButton.addTarget(self, action: #selector(ultraWideButtonTapped), for: .touchUpInside)
        zoomButton.addTarget(self, action: #selector(zoomButtonTapped), for: .touchUpInside)
        delayButton.addTarget(self, action: #selector(delayButtonTapped), for: .touchUpInside)
        bufferButton.addTarget(self, action: #selector(bufferButtonTapped), for: .touchUpInside)
        infoButton.addTarget(self, action: #selector(infoButtonTapped), for: .touchUpInside)
        trialBadgeButton.addTarget(self, action: #selector(trialBadgeTapped), for: .touchUpInside)
        
        NSLayoutConstraint.activate([
            // Logo - small at top center
            logoImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 160),
            logoImageView.heightAnchor.constraint(equalToConstant: 160),
            
            // Start button - bottom center
            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            startButton.widthAnchor.constraint(equalToConstant: 120),
            startButton.heightAnchor.constraint(equalToConstant: 120),
            
            // Controls stack - just above start button
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -30),
            
            // Flip button stays circular (icon-only)
            flipButton.widthAnchor.constraint(equalToConstant: 50),
            flipButton.heightAnchor.constraint(equalToConstant: 50),
            
            // Ultra-wide button same size as flip button
            ultraWideButton.widthAnchor.constraint(equalToConstant: 50),
            ultraWideButton.heightAnchor.constraint(equalToConstant: 50),
            
            // Pill buttons: same height as flip button, width auto-sizes to content
            zoomButton.heightAnchor.constraint(equalToConstant: 50),
            delayButton.heightAnchor.constraint(equalToConstant: 50),
            bufferButton.heightAnchor.constraint(equalToConstant: 50),
            
            // Info button - TOP RIGHT
            infoButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            infoButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            infoButton.widthAnchor.constraint(equalToConstant: 44),
            infoButton.heightAnchor.constraint(equalToConstant: 44),

            // Trial badge - BOTTOM LEFT above safe area
            trialBadgeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            trialBadgeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -1)
        ])
        
        // Update button states
        updateDelayButton()
        updateZoomButton()
        updateBufferButton()
        updateUltraWideButton()
        
        // Zoom callback
        cameraPreviewView.onZoomChanged = { [weak self] zoom in
            self?.updateZoomButton()
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Ultra-Wide Button Helpers
    // ─────────────────────────────────────────────────────────────────────

    /// Updates the ultra-wide button icon to reflect active state (icon swap only, no background change).
    private func updateUltraWideButtonIcon() {
        let isActive = Settings.shared.useUltraWideCamera
        let iconName = isActive
            ? "arrow.down.right.and.arrow.up.left"   // currently ultra-wide: show collapse icon
            : "arrow.up.left.and.arrow.down.right"   // currently standard: show expand icon
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        ultraWideButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
    }

    /// Shows or hides the ultra-wide button with a smooth grow/shrink spring animation.
    private func updateUltraWideButton(animated: Bool = true) {
        let isAvailable = LiveCameraPreviewView.ultraWideCameraAvailableForCurrentPosition()

        // Always sync the icon
        updateUltraWideButtonIcon()

        let isCurrentlyVisible = !ultraWideButton.isHidden

        if isAvailable && !isCurrentlyVisible {
            // Make the button part of the layout BEFORE animating so the stack
            // view sees it as present and smoothly pushes the other buttons apart.
            ultraWideButton.isHidden = false
            ultraWideButton.alpha = 0
            ultraWideButton.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)

            if animated {
                // Force an immediate layout pass so the stack registers the new size
                self.view.layoutIfNeeded()

                UIView.animate(withDuration: 0.38, delay: 0,
                               usingSpringWithDamping: 0.68,
                               initialSpringVelocity: 0.4,
                               options: .curveEaseOut) {
                    self.ultraWideButton.alpha = 1
                    self.ultraWideButton.transform = .identity
                    self.view.layoutIfNeeded()
                }
            } else {
                ultraWideButton.alpha = 1
                ultraWideButton.transform = .identity
            }
        } else if !isAvailable && isCurrentlyVisible {
            if animated {
                UIView.animate(withDuration: 0.28, delay: 0,
                               usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0.2,
                               options: .curveEaseIn) {
                    self.ultraWideButton.alpha = 0
                    self.ultraWideButton.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                    self.view.layoutIfNeeded()
                } completion: { _ in
                    // Hide AFTER animation so the stack collapses smoothly in the
                    // animation block above rather than snapping on completion.
                    self.ultraWideButton.isHidden = true
                    self.ultraWideButton.transform = .identity
                    UIView.animate(withDuration: 0.22, delay: 0,
                                   options: .curveEaseInOut) {
                        self.view.layoutIfNeeded()
                    }
                }
            } else {
                ultraWideButton.isHidden = true
                ultraWideButton.alpha = 0
                ultraWideButton.transform = .identity
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Session Start (with paywall gate)
    // ─────────────────────────────────────────────────────────────────────
    
    @objc private func startSessionTapped() {
        guard !isSessionActive, !isTearingDown else { return }
        print("🎬 Start Session tapped")

        if !PurchaseManager.shared.canStartSession() {
            showPaywall()
            return
        }

        beginSession()
    }

    private func showPaywall() {
        print("🔒 Showing paywall")
        let paywallVC = PaywallViewController()
        paywallVC.modalPresentationStyle = .fullScreen
        paywallVC.onUnlocked = { [weak self] in
            self?.beginSession()
        }
        present(paywallVC, animated: true)
    }

    private func beginSession() {
        isSessionActive = true

        // Fade everything out except startButton — it stays visible so it
        // can crossfade with countdownStopButton in DelayedCameraView.
        UIView.animate(withDuration: 0.3) {
            self.logoImageView.alpha = 0
            self.controlsStackView.alpha = 0
            self.infoButton.alpha = 0
            self.trialBadgeButton.alpha = 0
        }

        cameraPreviewView.stopPreview { [weak self] in
            guard let self = self else { return }
            print("🎬 Starting delayed camera...")

            self.cameraPreviewView.isHidden = true
            self.delayedCameraView = DelayedCameraView(frame: self.view.bounds)
            self.delayedCameraView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.insertSubview(self.delayedCameraView!, at: 0)

            self.delayedCameraView?.onSessionStopped = { [weak self] in
                self?.handleSessionStopped()
            }

            // Keep startButton on top so it's visible during the crossfade.
            self.view.bringSubviewToFront(self.logoImageView)
            self.view.bringSubviewToFront(self.controlsStackView)
            self.view.bringSubviewToFront(self.startButton)

            // startSession immediately fades the X button in (0.3s).
            // Fade startButton out at the same time — play → X crossfade.
            self.delayedCameraView?.startSession(
                delaySeconds: Settings.shared.playbackDelay,
                useFrontCamera: Settings.shared.useFrontCamera
            )
            UIView.animate(withDuration: 0.3) {
                self.startButton.alpha = 0
            }
        }
    }
    
    private func handleSessionStopped() {
        print("🏠 Session stopped, returning to home")
        
        isSessionActive = false
        isTearingDown = true
        
        delayedCameraView?.removeFromSuperview()
        delayedCameraView = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isTearingDown = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.cameraPreviewView.isHidden = false
            self.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera)
        }
        
        UIView.animate(withDuration: 0.3) {
            self.logoImageView.alpha = 1
            self.controlsStackView.alpha = 1
            self.startButton.alpha = 1
            self.infoButton.alpha = 1
            self.trialBadgeButton.alpha = 1
        }

        updateTrialBadge()
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Button Actions
    // ─────────────────────────────────────────────────────────────────────
    
    @objc private func flipCameraTapped() {
        print("🔄 Flip camera tapped")
        
        Settings.shared.useFrontCamera.toggle()
        
        UIView.animate(withDuration: 0.3) {
            self.flipButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        } completion: { _ in
            UIView.animate(withDuration: 0.3) {
                self.flipButton.transform = .identity
            }
        }
        
        cameraPreviewView.stopPreview { [weak self] in
            guard let self = self else { return }
            self.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera)
            self.updateUltraWideButton()
            self.updateZoomButton()
            print("✅ Switched to \(Settings.shared.useFrontCamera ? "front" : "back") camera")
        }
    }
    
    @objc private func ultraWideButtonTapped() {
        print("🔭 Ultra-wide button tapped")

        // Toggle the setting — Settings.shared handles zoom reset internally
        Settings.shared.useUltraWideCamera.toggle()
        let isNowUltraWide = Settings.shared.useUltraWideCamera
        print("🔭 Ultra-wide now: \(isNowUltraWide ? "ON" : "OFF")")

        // Restart preview with the new device
        cameraPreviewView.stopPreview { [weak self] in
            guard let self else { return }
            self.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera) { [weak self] in
                self?.updateZoomButton()
            }
            self.updateUltraWideButtonIcon()
        }
    }
    
    @objc private func zoomButtonTapped() {
        print("🔍 Zoom button tapped - showing zoom controls")
        
        let currentZoom = Settings.shared.currentZoomFactor(isFrontCamera: Settings.shared.useFrontCamera)
        
        let alert = UIAlertController(
            title: "Zoom Level",
            message: "Crop in without moving the camera",
            preferredStyle: .actionSheet
        )
        
        let zoomLevels: [CGFloat] = [1.0, 2.0, 3.0, 4.0, 5.0]
        
        for zoom in zoomLevels {
            let title = String(format: "%.1f×", zoom)
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                Settings.shared.setZoomFactor(zoom, isFrontCamera: Settings.shared.useFrontCamera)
                self?.cameraPreviewView.setZoom(zoom)
                self?.updateZoomButton()
            }
            if abs(currentZoom - zoom) < 0.01 {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = zoomButton
            popover.sourceRect = zoomButton.bounds
            popover.permittedArrowDirections = .down
        }
        
        present(alert, animated: true)
    }
    
    @objc private func delayButtonTapped() {
        print("⏱️ Delay button tapped")
        
        let currentDelay = Settings.shared.playbackDelay
        
        let alert = UIAlertController(
            title: "Playback Delay",
            message: "How far behind live the preview plays",
            preferredStyle: .actionSheet
        )
        
        let delays: [(Int, Bool)] = [(5, false), (7, true), (10, false), (12, false)]
        
        for (delay, recommended) in delays {
            let action = UIAlertAction(title: "\(delay) seconds", style: .default) { [weak self] _ in
                Settings.shared.playbackDelay = delay
                self?.updateDelayButton()
                print("⏱️ Delay changed to: \(delay)s")
            }
            if delay == currentDelay {
                action.setValue(true, forKey: "checked")
            }
            if recommended {
                let starImage = UIImage(systemName: "star.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                action.setValue(starImage, forKey: "image")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = delayButton
            popover.sourceRect = delayButton.bounds
            popover.permittedArrowDirections = .down
        }
        
        present(alert, animated: true)
    }
    
    @objc private func infoButtonTapped() {
        print("ℹ️ Info button tapped")
        let infoVC = InfoViewController()
        infoVC.modalPresentationStyle = .fullScreen
        infoVC.transitioningDelegate = self
        present(infoVC, animated: true)
    }

    @objc private func trialBadgeTapped() {
        print("🏷 Trial badge tapped – showing paywall for early purchase")
        let paywallVC = PaywallViewController()
        paywallVC.modalPresentationStyle = .fullScreen
        paywallVC.showCloseButton = true
        paywallVC.onUnlocked = { [weak self] in
            self?.updateTrialBadge()
        }
        present(paywallVC, animated: true)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - UIViewControllerTransitioningDelegate
    // ─────────────────────────────────────────────────────────────────────

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return HorizontalSlideTransition(isPresenting: true)
    }
    
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return HorizontalSlideTransition(isPresenting: false)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────────────────────────

    private func updateDelayButton() {
        let currentDelay = Settings.shared.playbackDelay
        delayButton.setTitle(" \(currentDelay)s", for: .normal)
    }
    
    private func updateZoomButton() {
        let currentZoom = Settings.shared.currentZoomFactor(isFrontCamera: Settings.shared.useFrontCamera)
        zoomButton.setTitle(String(format: " %.1f×", currentZoom), for: .normal)
    }
    
    private func updateBufferButton() {
        let minutes = Settings.shared.bufferDurationSeconds / 60
        bufferButton.setTitle(" \(minutes)m", for: .normal)
    }
    
    @objc private func bufferButtonTapped() {
        print("⏺ Buffer duration button tapped")
        
        let alert = UIAlertController(
            title: "Review Buffer",
            message: "How much video to keep available for replay",
            preferredStyle: .actionSheet
        )
        
        let options: [(Int, Bool)] = [(1, true), (2, false), (3, false), (4, false), (5, false)]
        
        for (minutes, recommended) in options {
            let title = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                Settings.shared.bufferDurationSeconds = minutes * 60
                self?.updateBufferButton()
                print("⏺ Buffer duration changed to: \(minutes)m (\(minutes * 60)s)")
            }
            if minutes * 60 == Settings.shared.bufferDurationSeconds {
                action.setValue(true, forKey: "checked")
            }
            if recommended {
                let starImage = UIImage(systemName: "star.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                action.setValue(starImage, forKey: "image")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = bufferButton
            popover.sourceRect = bufferButton.bounds
            popover.permittedArrowDirections = .down
        }
        
        present(alert, animated: true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Custom Horizontal Slide Transition (unchanged)
// ─────────────────────────────────────────────────────────────────────────────
class HorizontalSlideTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let isPresenting: Bool
    
    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }
    
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.5
    }
    
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else { return }
        
        let container = transitionContext.containerView
        let screenWidth = container.bounds.width
        
        if isPresenting {
            container.addSubview(toView)
            toView.frame = container.bounds.offsetBy(dx: screenWidth, dy: 0)
            UIView.animate(withDuration: transitionDuration(using: transitionContext), animations: {
                toView.frame = container.bounds
            }, completion: { finished in
                transitionContext.completeTransition(finished)
            })
        } else {
            container.insertSubview(toView, belowSubview: fromView)
            UIView.animate(withDuration: transitionDuration(using: transitionContext), animations: {
                fromView.frame = container.bounds.offsetBy(dx: screenWidth, dy: 0)
            }, completion: { finished in
                transitionContext.completeTransition(finished)
            })
        }
    }
}
