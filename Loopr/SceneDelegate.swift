import UIKit
import AVFoundation

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    private var splashVC: SplashViewController?
    private var homeVC: HomeViewController?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        window = UIWindow(windowScene: windowScene)
        
        // Create splash screen
        splashVC = SplashViewController()
        window?.rootViewController = splashVC
        window?.makeKeyAndVisible()
        
        // Pre-warm camera and create HomeVC in background
        prewarmApp()
    }
    
    func showMainApp() {
        // Transition to main app
        guard let homeVC = homeVC else { return }
        let navController = UINavigationController(rootViewController: homeVC)
        navController.setNavigationBarHidden(true, animated: false)
        window?.rootViewController = navController
        
        // Clean up splash reference
        splashVC = nil
    }
    
    private func prewarmApp() {
        // Request camera permissions early
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print(granted ? "✅ Camera access granted" : "❌ Camera access denied")
            
            if granted {
                // Create and prepare HomeViewController in background
                DispatchQueue.main.async {
                    self.setupHomeViewController()
                }
            }
        }
        
        // Preload any heavy resources here
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Settings.shared // Initialize settings singleton
            DispatchQueue.main.async {
                print("✅ App pre-warming complete")
            }
        }
    }
    
    private func setupHomeViewController() {
        // Create HomeVC and set callback
        homeVC = HomeViewController()
        homeVC?.onCameraPreviewReady = { [weak self] in
            print("✅ Camera preview ready, dismissing splash")
            self?.splashVC?.cameraIsReady()
        }
        
        // Trigger the view to load (which starts camera setup)
        _ = homeVC?.view
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
