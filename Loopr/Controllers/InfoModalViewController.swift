import UIKit

class InfoModalViewController: UIViewController {
    
    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.layer.cornerRadius = 20
        view.layer.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = true
        return scrollView
    }()
    
    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let logoImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(named: "info-logo")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "How to Use Loopr:"
        label.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let instructionsLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18)
        label.textColor = .white
        
        let instructions = """
        ❶ TAP the flip camera button to switch between front and back cameras

        ❷ TAP the zoom button to adjust your zoom level (1.0x - 5.0x)

        ❸ TAP the delay button to set your playback delay (5s, 7s, or 10s)

        ❹ PINCH on the camera preview to adjust zoom smoothly

        ❺ TAP the PLAY button to start your delayed session

        ❻ During the session, TAP the screen to show/hide controls

        ❼ Use PAUSE to freeze playback or END SESSION to return home


        Perfect for analyzing your baseball/softball swings!
        """
        
        label.text = instructions
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let supportLabel: UILabel = {
        let label = UILabel()
        label.text = "Need Help?"
        label.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let emailButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("3up3down.help@gmail.com", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.setTitleColor(.systemBlue, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let companyLogoImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(named: "splash-company-logo")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()
    
    private let versionLabel: UILabel = {
        let label = UILabel()
        
        // Get app version from bundle
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        
        label.text = "Version \(version) (Build \(build))"
        label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .gray
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("✕", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .regular)
        button.setTitleColor(.black, for: .normal)
        button.backgroundColor = UIColor.systemGray5
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        print("ℹ️ InfoModalViewController loaded")
        
        // Semi-transparent background
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        
        setupUI()
        setupActions()
        
        // Tap outside to dismiss
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        view.addGestureRecognizer(tapGesture)
        
        // Debug: Check if logo loaded
        if logoImageView.image == nil {
            print("⚠️ Warning: inapp-logo image not found")
        } else {
            print("✅ Logo image loaded successfully")
        }
    }
    
    private func setupUI() {
        // Add main container to view
        view.addSubview(containerView)
        
        // Add close button and scroll view to container
        containerView.addSubview(closeButton)
        containerView.addSubview(scrollView)
        
        // Add content view to scroll view
        scrollView.addSubview(contentView)
        
        // Add all UI elements to content view
        contentView.addSubview(logoImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(instructionsLabel)
        // contentView.addSubview(dividerView)  // REMOVED
        contentView.addSubview(supportLabel)
        // contentView.addSubview(supportDescLabel)  // REMOVED
        contentView.addSubview(emailButton)
        contentView.addSubview(companyLogoImageView)
        contentView.addSubview(versionLabel)
        
        // Layout constraints
        NSLayoutConstraint.activate([
            // Container view - centered, fixed constraints
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            containerView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.75),
            
            // Close button - top right corner
            closeButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Scroll view fills the container (below close button)
            scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            
            // Content view inside scroll view - CRITICAL for scroll view to work
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            
            // Logo at top
            logoImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 0),
            logoImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 200),
            logoImageView.heightAnchor.constraint(equalToConstant: 200),
            
            // Title below logo
            titleLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // Instructions below title
            instructionsLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            instructionsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 25),
            instructionsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -25),
            
            // Support label below instructions (no divider anymore)
            supportLabel.topAnchor.constraint(equalTo: instructionsLabel.bottomAnchor, constant: 40),
            supportLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            supportLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // Email button below support label (no support description)
            emailButton.topAnchor.constraint(equalTo: supportLabel.bottomAnchor, constant: 10),
            emailButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            
            // Company logo below email button
            companyLogoImageView.topAnchor.constraint(equalTo: emailButton.bottomAnchor, constant: 40),
            companyLogoImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            companyLogoImageView.widthAnchor.constraint(equalToConstant: 160),
            companyLogoImageView.heightAnchor.constraint(equalToConstant: 60),
            
            // Version below company logo - MORE SPACE
            versionLabel.topAnchor.constraint(equalTo: companyLogoImageView.bottomAnchor, constant: 60),
            versionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            versionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            versionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -25)
        ])
        
        print("✅ UI setup complete")
    }
    
    private func setupActions() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        emailButton.addTarget(self, action: #selector(emailTapped), for: .touchUpInside)
    }
    
    @objc private func closeTapped() {
        print("ℹ️ Close button tapped")
        dismiss(animated: true)
    }
    
    @objc private func emailTapped() {
        print("📧 Email button tapped")
        let email = "3up3down.help@gmail.com"
        if let url = URL(string: "mailto:\(email)") {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                print("✅ Opening mail app")
            } else {
                // Copy to clipboard if mail app isn't available
                UIPasteboard.general.string = email
                showCopiedAlert()
                print("📋 Email copied to clipboard")
            }
        }
    }
    
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        if !containerView.frame.contains(location) {
            print("ℹ️ Background tapped, dismissing")
            dismiss(animated: true)
        }
    }
    
    private func showCopiedAlert() {
        let alert = UIAlertController(
            title: "Email Copied",
            message: "Email address copied to clipboard",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
