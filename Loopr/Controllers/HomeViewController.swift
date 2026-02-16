import UIKit
import AVFoundation

class HomeViewController: UIViewController {
    
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
    
    // NEW: Info button
    private let infoButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = UIImage(systemName: "info.circle", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 25
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private var isSessionActive = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("✅ HomeViewController created")
        view.backgroundColor = .black
        
        // Prevent screen from dimming or sleeping
        UIApplication.shared.isIdleTimerDisabled = true
        
        setupUI()
        
        // Start live preview and notify when ready
        cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera) { [weak self] in
            print("✅ Home camera preview fully ready")
            self?.onCameraPreviewReady?()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Re-enable auto-lock when leaving this screen
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
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
        controlsStackView.addArrangedSubview(infoButton)
        view.addSubview(controlsStackView)
        
        // Start button
        view.addSubview(startButton)
        
        // Button actions
        startButton.addTarget(self, action: #selector(startSessionTapped), for: .touchUpInside)
        flipButton.addTarget(self, action: #selector(flipCameraTapped), for: .touchUpInside)
        zoomButton.addTarget(self, action: #selector(zoomButtonTapped), for: .touchUpInside)
        delayButton.addTarget(self, action: #selector(delayButtonTapped), for: .touchUpInside)
        infoButton.addTarget(self, action: #selector(infoButtonTapped), for: .touchUpInside)
        
        NSLayoutConstraint.activate([
            // Logo - small at top center
            logoImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 160),
            logoImageView.heightAnchor.constraint(equalToConstant: 160),
            
            // Start button - bottom center, bigger (120x120 vs 60x60 circles)
            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            startButton.widthAnchor.constraint(equalToConstant: 120),
            startButton.heightAnchor.constraint(equalToConstant: 120),
            
            // Controls stack - just above start button
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -30),
            
            // Individual button sizes
            flipButton.widthAnchor.constraint(equalToConstant: 50),
            flipButton.heightAnchor.constraint(equalToConstant: 50),
            
            zoomButton.widthAnchor.constraint(equalToConstant: 50),
            zoomButton.heightAnchor.constraint(equalToConstant: 50),
            
            delayButton.widthAnchor.constraint(equalToConstant: 50),
            delayButton.heightAnchor.constraint(equalToConstant: 50),
            
            // NEW: Info button size
            infoButton.widthAnchor.constraint(equalToConstant: 50),
            infoButton.heightAnchor.constraint(equalToConstant: 50)
        ])
        
        // Update button states
        updateDelayButton()
        updateZoomButton()
        
        // Zoom callback
        cameraPreviewView.onZoomChanged = { [weak self] zoom in
            self?.updateZoomButton()
        }
    }
    
    @objc private func startSessionTapped() {
        guard !isSessionActive else { return }
        print("🎬 Start Session tapped")
        isSessionActive = true
        
        cameraPreviewView.stopPreview { [weak self] in
            guard let self = self else { return }
            print("🎬 Starting delayed camera...")
            
            self.cameraPreviewView.isHidden = true
            self.delayedCameraView = DelayedCameraView(frame: self.view.bounds)
            self.delayedCameraView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.insertSubview(self.delayedCameraView!, at: 0)
            
            // NEW: Set callback for when session stops
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
        
        // UI changes
        UIView.animate(withDuration: 0.3) {
            self.logoImageView.alpha = 0
            self.controlsStackView.alpha = 0
            self.startButton.alpha = 0
        }
    }
    
    private func handleSessionStopped() {
        print("🏠 Session stopped, returning to home")
        
        isSessionActive = false
        
        delayedCameraView?.removeFromSuperview()
        delayedCameraView = nil
        
        // Wait before showing live preview again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.cameraPreviewView.isHidden = false
            self?.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera)
        }
        
        // UI changes
        UIView.animate(withDuration: 0.3) {
            self.logoImageView.alpha = 1
            self.controlsStackView.alpha = 1
            self.startButton.alpha = 1
        }
    }
    
    @objc private func flipCameraTapped() {
        print("🔄 Flip camera tapped")
        
        Settings.shared.useFrontCamera.toggle()
        
        // Animate button
        UIView.animate(withDuration: 0.3) {
            self.flipButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        } completion: { _ in
            UIView.animate(withDuration: 0.3) {
                self.flipButton.transform = .identity
            }
        }
        
        // Stop current preview and restart with new camera
        cameraPreviewView.stopPreview { [weak self] in
            guard let self = self else { return }
            self.cameraPreviewView.startPreview(useFrontCamera: Settings.shared.useFrontCamera)
            print("✅ Switched to \(Settings.shared.useFrontCamera ? "front" : "back") camera")
        }
    }
    
    @objc private func zoomButtonTapped() {
        print("🔍 Zoom button tapped - showing zoom controls")
        
        // Create alert with zoom options
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
        
        // For iPad
        if let popover = alert.popoverPresentationController {
            popover.sourceView = zoomButton
            popover.sourceRect = zoomButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    @objc private func delayButtonTapped() {
        print("⏱️ Delay button tapped")
        
        // Create alert with delay options
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
        
        // For iPad
        if let popover = alert.popoverPresentationController {
            popover.sourceView = delayButton
            popover.sourceRect = delayButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    // NEW: Info button action
    @objc private func infoButtonTapped() {
        print("ℹ️ Info button tapped")
        
        let infoVC = InfoModalViewController()
        infoVC.modalPresentationStyle = .overFullScreen
        infoVC.modalTransitionStyle = .crossDissolve
        present(infoVC, animated: true)
    }
    
    private func updateDelayButton() {
        let currentDelay = Settings.shared.playbackDelay
        delayButton.setTitle("\(currentDelay)s", for: .normal)
    }
    
    private func updateZoomButton() {
        let currentZoom = Settings.shared.currentZoomFactor(isFrontCamera: Settings.shared.useFrontCamera)
        zoomButton.setTitle(String(format: "%.1fx", currentZoom), for: .normal)
    }
}
