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
        
        // Bigger play icon to fill the circle
        let config = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        let image = UIImage(systemName: "play.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        
        button.tintColor = .white
        button.backgroundColor = .black
        
        // Thicker black border
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
        stack.spacing = 20
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    private let flipButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = UIImage(systemName: "camera.rotate", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 25
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let zoomButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("1.0x", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 25
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let delayButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("7s", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 25
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    // Info button - positioned in top right (like close button toggle)
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
    // MARK: - Trial badge (shown during free trial period)
    // ─────────────────────────────────────────────────────────────────────
    // Small non-intrusive label in the bottom-left showing days remaining.
    // Tapping it opens the paywall so users can purchase early if they want.
    private let trialBadgeButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true   // Hidden until we confirm trial status
        return button
    }()

    private var isSessionActive = false
    
    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Lifecycle
    // ─────────────────────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        print("✅ HomeViewController created")
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true
        setupUI()

        // Just start the preview - permission check happens in viewDidAppear
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
            // Previously denied — show alert immediately
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

        // Safe to show alerts here - view is fully in the window hierarchy
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            showCameraPermissionAlert()
        }
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
        controlsStackView.addArrangedSubview(flipButton)
        controlsStackView.addArrangedSubview(zoomButton)
        controlsStackView.addArrangedSubview(delayButton)
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
        zoomButton.addTarget(self, action: #selector(zoomButtonTapped), for: .touchUpInside)
        delayButton.addTarget(self, action: #selector(delayButtonTapped), for: .touchUpInside)
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
            startButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            startButton.widthAnchor.constraint(equalToConstant: 120),
            startButton.heightAnchor.constraint(equalToConstant: 120),
            
            // Controls stack - just above start button
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -30),
            
            // Individual button sizes (in stack)
            flipButton.widthAnchor.constraint(equalToConstant: 50),
            flipButton.heightAnchor.constraint(equalToConstant: 50),
            zoomButton.widthAnchor.constraint(equalToConstant: 50),
            zoomButton.heightAnchor.constraint(equalToConstant: 50),
            delayButton.widthAnchor.constraint(equalToConstant: 50),
            delayButton.heightAnchor.constraint(equalToConstant: 50),
            
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
        
        // Zoom callback
        cameraPreviewView.onZoomChanged = { [weak self] zoom in
            self?.updateZoomButton()
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Session Start (with paywall gate)
    // ─────────────────────────────────────────────────────────────────────
    
    @objc private func startSessionTapped() {
        guard !isSessionActive else { return }
        print("🎬 Start Session tapped")

        // ── PAYWALL CHECK ──────────────────────────────────────────────
        // If the user's trial has expired and they haven't purchased,
        // show the paywall instead of starting the session.
        // ──────────────────────────────────────────────────────────────
        if !PurchaseManager.shared.canStartSession() {
            showPaywall()
            return
        }

        beginSession()
    }

    /// Presents the paywall. When the user successfully purchases,
    /// onUnlocked fires and we start the session automatically.
    private func showPaywall() {
        print("🔒 Showing paywall")
        let paywallVC = PaywallViewController()
        paywallVC.modalPresentationStyle = .fullScreen
        paywallVC.onUnlocked = { [weak self] in
            // Purchase succeeded – go straight into the session
            self?.beginSession()
        }
        present(paywallVC, animated: true)
    }

    /// The actual session-start logic, extracted so we can call it from
    /// both the normal flow and post-purchase callback.
    private func beginSession() {
        isSessionActive = true

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
            
            self.view.bringSubviewToFront(self.logoImageView)
            self.view.bringSubviewToFront(self.controlsStackView)
            self.view.bringSubviewToFront(self.startButton)
            
            self.delayedCameraView?.startSession(
                delaySeconds: Settings.shared.playbackDelay,
                useFrontCamera: Settings.shared.useFrontCamera
            )
        }
        
        UIView.animate(withDuration: 0.3) {
            self.logoImageView.alpha = 0
            self.controlsStackView.alpha = 0
            self.startButton.alpha = 0
            self.infoButton.alpha = 0
            self.trialBadgeButton.alpha = 0
        }
    }
    
    private func handleSessionStopped() {
        print("🏠 Session stopped, returning to home")
        
        isSessionActive = false
        
        delayedCameraView?.removeFromSuperview()
        delayedCameraView = nil
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.cameraPreviewView.isHidden = false
            self?.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera)
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
    // MARK: - Other Button Actions
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
            print("✅ Switched to \(Settings.shared.useFrontCamera ? "front" : "back") camera")
        }
    }
    
    @objc private func zoomButtonTapped() {
        print("🔍 Zoom button tapped - showing zoom controls")
        
        let alert = UIAlertController(title: "Zoom Level", message: nil, preferredStyle: .actionSheet)
        let zoomLevels: [CGFloat] = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0]
        
        for zoom in zoomLevels {
            let action = UIAlertAction(title: String(format: "%.1fx", zoom), style: .default) { [weak self] _ in
                Settings.shared.setZoomFactor(zoom, isFrontCamera: Settings.shared.useFrontCamera)
                self?.cameraPreviewView.setZoom(zoom)
                self?.updateZoomButton()
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = zoomButton
            popover.sourceRect = zoomButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    @objc private func delayButtonTapped() {
        print("⏱️ Delay button tapped")
        
        let alert = UIAlertController(title: "Playback Delay", message: nil, preferredStyle: .actionSheet)
        let delays = [5, 7, 10]
        
        for delay in delays {
            let action = UIAlertAction(title: "\(delay) seconds", style: .default) { [weak self] _ in
                Settings.shared.playbackDelay = delay
                self?.updateDelayButton()
                print("⏱️ Delay changed to: \(delay)s")
            }
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = delayButton
            popover.sourceRect = delayButton.bounds
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
        paywallVC.showCloseButton = true  // Allow dismissal – they're still in trial
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
        delayButton.setTitle("\(currentDelay)s", for: .normal)
    }
    
    private func updateZoomButton() {
        let currentZoom = Settings.shared.currentZoomFactor(isFrontCamera: Settings.shared.useFrontCamera)
        zoomButton.setTitle(String(format: "%.1fx", currentZoom), for: .normal)
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
