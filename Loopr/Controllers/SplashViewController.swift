import UIKit

class SplashViewController: UIViewController {
    
    private let logoImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()
    
    private let companyLogoImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(named: "splash-company-logo")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.alpha = 0 // Start hidden, will fade in
        return imageView
    }()
    
    private var cameraIsReadyFlag = false
    private var minimumDurationPassed = false
    private let minimumSplashDuration: TimeInterval = 2.5 // Adjust this value (in seconds)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        animateSplash()
        startMinimumTimer()
    }
    
    private func setupViews() {
        view.addSubview(logoImageView)
        view.addSubview(companyLogoImageView)
        
        NSLayoutConstraint.activate([
            // Main logo - center with max size and padding
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            logoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            logoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 400),
            logoImageView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9), // Changed from 0.8 to 0.9
            logoImageView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.5),
            
            // Company logo - bottom center
            companyLogoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            companyLogoImageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            companyLogoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            companyLogoImageView.heightAnchor.constraint(equalToConstant: 60),
            companyLogoImageView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.5)
        ])
        
        logoImageView.image = UIImage(named: "splash-logo")
        logoImageView.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        logoImageView.alpha = 0
    }
    
    private func animateSplash() {
        // Phase 1: Logo fade in and scale up (0.5s)
        UIView.animate(withDuration: 0.5, delay: 0.2, options: .curveEaseOut) {
            self.logoImageView.alpha = 1.0
            self.logoImageView.transform = CGAffineTransform(scaleX: 1.0, y: 1.0)
        }
        
        // Phase 2: Subtle pulse animation - REDUCED scale so it doesn't overflow
        UIView.animate(withDuration: 1.0, delay: 1.0, options: [.repeat, .autoreverse]) {
            self.logoImageView.transform = CGAffineTransform(scaleX: 1.1, y: 1.1) // Changed from 1.5 to 1.1
        }
        
        // Phase 3: Company logo fade in immediately
        UIView.animate(withDuration: 0.4, delay: 0.0, options: .curveEaseIn) {
            self.companyLogoImageView.alpha = 1.0
        }
    }
    
    private func startMinimumTimer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumSplashDuration) { [weak self] in
            self?.minimumDurationPassed = true
            self?.checkIfReadyToTransition()
        }
    }
    
    func cameraIsReady() {
        // Called by HomeViewController when camera preview is ready
        print("✅ Camera ready notification received")
        cameraIsReadyFlag = true
        checkIfReadyToTransition()
    }
    
    private func checkIfReadyToTransition() {
        // Only transition when BOTH conditions are met:
        // 1. Camera is ready
        // 2. Minimum splash duration has passed
        if cameraIsReadyFlag && minimumDurationPassed {
            print("✅ Both conditions met, transitioning to main app")
            transitionToMainApp()
        } else {
            print("⏳ Waiting... Camera ready: \(cameraIsReadyFlag), Min duration: \(minimumDurationPassed)")
        }
    }
    
    private func transitionToMainApp() {
        // Fade out animation
        UIView.animate(withDuration: 0.4, animations: {
            self.view.alpha = 0
        }) { _ in
            // Get the scene delegate and show main app
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let sceneDelegate = windowScene.delegate as? SceneDelegate {
                sceneDelegate.showMainApp()
            }
        }
    }
}

