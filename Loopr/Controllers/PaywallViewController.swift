import UIKit
import StoreKit

class PaywallViewController: UIViewController {

    // Called by HomeViewController after successful purchase
    var onUnlocked: (() -> Void)?
    var showCloseButton: Bool = false

    // MARK: - Feature Carousel Data

    private struct FeatureCard {
        let icon: String
        let title: String
        let description: String
        let color: UIColor
    }

    private let purple = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)

    private lazy var features: [FeatureCard] = [
        FeatureCard(
            icon: "figure.baseball",
            title: "Instant Replay",
            description: "Watch every swing play back automatically at your chosen delay — no tapping required between reps.",
            color: purple
        ),
        FeatureCard(
            icon: "slider.horizontal.below.rectangle",
            title: "Frame-by-Frame Scrub",
            description: "Pause and drag through the replay one frame at a time. Spot the exact moment contact breaks down.",
            color: purple
        ),
        FeatureCard(
            icon: "scissors",
            title: "Clip & Save",
            description: "Trim the perfect moment and save it directly to Photos. Share it with athletes or parents in seconds.",
            color: purple
        ),
        FeatureCard(
            icon: "rectangle.split.2x1",
            title: "Split View",
            description: "View two clips side by side. Link them to scrub in sync, or unlink to step through each independently.",
            color: purple
        ),
        FeatureCard(
            icon: "camera.rotate",
            title: "Front & Back Camera",
            description: "Switch between front and back cameras. Set up behind the plate or down the third base line.",
            color: purple
        ),
        FeatureCard(
            icon: "clock.arrow.circlepath",
            title: "Adjustable Delay",
            description: "Choose 5s, 7s, or 10s of delay so your athlete finishes their swing before the replay starts.",
            color: purple
        ),
        FeatureCard(
            icon: "record.circle",
            title: "Review Buffer",
            description: "Keep up to 5 minutes of video ready to scrub through after you pause. Never miss a moment worth reviewing.",
            color: purple
        ),
        FeatureCard(
            icon: "infinity",
            title: "Own It Forever",
            description: "One-time purchase. No subscription. No renewal. Pay once and Loopr is yours on every device you own.",
            color: purple
        ),
    ]

    // MARK: - UI

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        sv.showsVerticalScrollIndicator = false
        return sv
    }()

    private let contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let logoImageView: UIImageView = {
        let iv = UIImageView()
        iv.image = UIImage(named: "inapp-logo")
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let headlineLabel: UILabel = {
        let l = UILabel()
        l.text = "Unlock Loopr"
        l.font = UIFont.systemFont(ofSize: 32, weight: .bold)
        l.textColor = .white
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private lazy var subheadlineLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 17, weight: .regular)
        l.textColor = UIColor.lightGray
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let carouselCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 16
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        cv.isPagingEnabled = false
        cv.decelerationRate = .fast
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    private let pageControl: UIPageControl = {
        let pc = UIPageControl()
        pc.currentPageIndicatorTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        pc.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.3)
        pc.translatesAutoresizingMaskIntoConstraints = false
        return pc
    }()

    private let purchaseButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Loading…", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        b.layer.cornerRadius = 12
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.black.cgColor
        b.clipsToBounds = true
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 32)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let priceNoteLabel: UILabel = {
        let l = UILabel()
        l.text = "One-time purchase · No subscription · No hidden fees"
        l.font = UIFont.systemFont(ofSize: 13)
        l.textColor = UIColor.lightGray
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let restoreButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Already purchased? Restore", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        b.setTitleColor(.systemBlue, for: .normal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let legalLabel: UILabel = {
        let l = UILabel()
        l.text = "Payment is charged to your Apple ID at confirmation of purchase."
        l.font = UIFont.systemFont(ofSize: 12)
        l.textColor = UIColor.darkGray
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .large)
        ai.color = .white
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private lazy var closeButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("✕", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .regular)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.systemGray.withAlphaComponent(0.3)
        b.layer.cornerRadius = 22
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return b
    }()

    // Auto-scroll
    private var autoScrollTimer: Timer?
    private var currentPage = 0
    private let repeatCount = 100
    private var totalItems: Int { features.count * repeatCount }
    private let cellID = "FeatureCell"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        refreshPurchaseButton()
        setupSubheadline()
    }

    private var hasPositionedCarousel = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Position once, as soon as the collection view has valid bounds — before first render
        guard !hasPositionedCarousel, carouselCollectionView.bounds.width > 0 else { return }
        hasPositionedCarousel = true

        let cardWidth: CGFloat = 280
        let spacing: CGFloat = 16
        let stride = cardWidth + spacing
        let inset = (carouselCollectionView.bounds.width - cardWidth) / 2

        let midPage = (repeatCount / 2) * features.count
        let midX = CGFloat(midPage) * stride - inset
        carouselCollectionView.setContentOffset(CGPoint(x: midX, y: 0), animated: false)
        currentPage = midPage
        pageControl.currentPage = midPage % features.count
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startAutoScroll()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopAutoScroll()
    }

    // MARK: - Setup

    private func setupSubheadline() {
        switch PurchaseManager.shared.accessState {
        case .trial(let days):
            let word = days == 1 ? "day" : "days"
            subheadlineLabel.text = "You have \(days) free \(word) remaining."
        case .expired:
            subheadlineLabel.text = "Your free trial has ended."
        case .purchased:
            subheadlineLabel.text = "Thanks for supporting Loopr! ⚾️"
        }
    }

    private func setupUI() {
        carouselCollectionView.dataSource = self
        carouselCollectionView.delegate = self
        carouselCollectionView.register(FeatureCarouselCell.self, forCellWithReuseIdentifier: cellID)
        pageControl.numberOfPages = features.count

        view.addSubview(scrollView)
        view.addSubview(activityIndicator)

        if showCloseButton {
            view.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }

        scrollView.addSubview(contentView)
        [logoImageView, headlineLabel, subheadlineLabel,
         carouselCollectionView, pageControl,
         purchaseButton, priceNoteLabel,
         restoreButton, legalLabel].forEach { contentView.addSubview($0) }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            logoImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 50),
            logoImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 180),
            logoImageView.heightAnchor.constraint(equalToConstant: 180),

            headlineLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 16),
            headlineLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            headlineLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            subheadlineLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 8),
            subheadlineLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            subheadlineLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Carousel – full width, fixed 200pt height for cards
            carouselCollectionView.topAnchor.constraint(equalTo: subheadlineLabel.bottomAnchor, constant: 28),
            carouselCollectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            carouselCollectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            carouselCollectionView.heightAnchor.constraint(equalToConstant: 200),  // Fixed 200pt height

            pageControl.topAnchor.constraint(equalTo: carouselCollectionView.bottomAnchor, constant: 8),
            pageControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            purchaseButton.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 28),
            purchaseButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            purchaseButton.heightAnchor.constraint(equalToConstant: 56),

            priceNoteLabel.topAnchor.constraint(equalTo: purchaseButton.bottomAnchor, constant: 12),
            priceNoteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            priceNoteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            restoreButton.topAnchor.constraint(equalTo: priceNoteLabel.bottomAnchor, constant: 16),
            restoreButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            legalLabel.topAnchor.constraint(equalTo: restoreButton.bottomAnchor, constant: 20),
            legalLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            legalLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            legalLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        purchaseButton.addTarget(self, action: #selector(purchaseTapped), for: .touchUpInside)
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
    }

    // MARK: - Auto Scroll

    private func startAutoScroll() {
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scrollToNextCard()
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func scrollToNextCard() {
        let next = currentPage + 1
        guard next < totalItems else { return }
        currentPage = next

        let cardWidth: CGFloat = 280
        let spacing: CGFloat = 16
        let stride = cardWidth + spacing
        let inset = (carouselCollectionView.bounds.width - cardWidth) / 2
        let targetX = CGFloat(currentPage) * stride - inset
        carouselCollectionView.setContentOffset(CGPoint(x: targetX, y: 0), animated: true)
        pageControl.currentPage = currentPage % features.count
    }

    // MARK: - Purchase Button

    private func refreshPurchaseButton() {
        if let product = PurchaseManager.shared.product {
            purchaseButton.setTitle("Unlock Loopr – \(product.displayPrice)", for: .normal)
        } else {
            purchaseButton.setTitle("Unlock Loopr – $4.99", for: .normal)
        }
        purchaseButton.isEnabled = true
    }

    private func setLoading(_ loading: Bool) {
        loading ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
        purchaseButton.isEnabled = !loading
        restoreButton.isEnabled = !loading
    }

    // MARK: - Actions

    @objc private func purchaseTapped() {
        print("💳 Purchase tapped")
        setLoading(true)
        PurchaseManager.shared.onPurchaseSuccess = { [weak self] in
            guard let self else { return }
            self.setLoading(false)
            self.showSuccessAndDismiss()
        }
        Task {
            do {
                try await PurchaseManager.shared.purchase()
            } catch {
                await MainActor.run {
                    self.setLoading(false)
                    self.showError(error.localizedDescription)
                }
            }
            await MainActor.run { self.setLoading(false) }
        }
    }

    @objc private func restoreTapped() {
        print("🔄 Restore tapped")
        setLoading(true)
        PurchaseManager.shared.onPurchaseSuccess = { [weak self] in
            guard let self else { return }
            self.setLoading(false)
            self.showSuccessAndDismiss()
        }
        Task {
            await PurchaseManager.shared.restorePurchases()
            await MainActor.run {
                self.setLoading(false)
                if !PurchaseManager.shared.canStartSession() {
                    self.showError("No previous purchase found for this Apple ID.")
                }
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func showSuccessAndDismiss() {
        let alert = UIAlertController(
            title: "You're all set!",
            message: "Thank you for supporting Loopr. Enjoy training with instant replay for infinite insight!",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Let's go!", style: .default) { [weak self] _ in
            self?.dismiss(animated: true) { self?.onUnlocked?() }
        })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Something went wrong", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDataSource

extension PaywallViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return totalItems
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellID, for: indexPath) as! FeatureCarouselCell
        let feature = features[indexPath.item % features.count]
        cell.configure(icon: feature.icon, title: feature.title, description: feature.description, accentColor: feature.color)
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension PaywallViewController: UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width: CGFloat = 280
        let height: CGFloat = 200
        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        // Calculate inset only if bounds are valid
        guard carouselCollectionView.bounds.width > 0 else {
            return UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        }
        
        let cardWidth: CGFloat = 280
        let inset = (carouselCollectionView.bounds.width - cardWidth) / 2
        return UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === carouselCollectionView else { return }
        let cardWidth: CGFloat = 280
        let spacing: CGFloat = 16
        let stride = cardWidth + spacing
        let inset = (carouselCollectionView.bounds.width - cardWidth) / 2
        let centeredOffset = scrollView.contentOffset.x + inset + cardWidth / 2
        let page = Int((centeredOffset / stride).rounded())
        let clamped = max(0, min(page, totalItems - 1))
        if clamped != currentPage {
            currentPage = clamped
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        stopAutoScroll()

        let cardWidth: CGFloat = 280
        let spacing: CGFloat = 16
        let stride = cardWidth + spacing
        let inset = (carouselCollectionView.bounds.width - cardWidth) / 2

        // Projected landing point (centre of the collection view)
        let projectedOffset = targetContentOffset.pointee.x + inset + cardWidth / 2

        // Which index is closest to the projected landing point?
        var nearestIndex = Int((projectedOffset + stride / 2) / stride)
        nearestIndex = max(0, min(nearestIndex, totalItems - 1))

        // If flicking, advance or retreat exactly one card from current position
        if velocity.x > 0.3 {
            nearestIndex = currentPage + 1
        } else if velocity.x < -0.3 {
            nearestIndex = currentPage - 1
        }
        nearestIndex = max(0, min(nearestIndex, totalItems - 1))

        // Snap to the exact centre of that card
        targetContentOffset.pointee.x = CGFloat(nearestIndex) * stride - inset
        currentPage = nearestIndex
        pageControl.currentPage = nearestIndex % features.count

        // Restart auto-scroll after user settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.startAutoScroll()
        }
    }
}

// MARK: - FeatureCarouselCell

class FeatureCarouselCell: UICollectionViewCell {

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let descLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(0.75)
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let accentBar: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 2
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        contentView.layer.cornerRadius = 20
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        contentView.clipsToBounds = true

        contentView.addSubview(accentBar)
        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(descLabel)

        NSLayoutConstraint.activate([
            // Left accent bar – full height
            accentBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 4),

            // Icon — top left, larger since card is square
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            iconView.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            // Title below icon
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // Description below title
            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            descLabel.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 20),
            descLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            descLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: String, title: String, description: String, accentColor: UIColor) {
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        iconView.image = UIImage(systemName: icon, withConfiguration: config)
        iconView.tintColor = accentColor
        titleLabel.text = title
        descLabel.text = description
        accentBar.backgroundColor = accentColor
    }
}
