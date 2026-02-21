import UIKit
import AVFoundation
import Photos
import UniformTypeIdentifiers

final class SplitVideoView: UIViewController {

    // MARK: - Public API

    var leftURL: URL?
    var rightURL: URL?

    /// Called when user closes this view so the owner can return to RecordedVideoView
    /// and clean up temp files.
    var onDismiss: (() -> Void)?
    
    var onRestartRequested: (() -> Void)?
    var onStopSessionRequested: (() -> Void)?

    // MARK: - Private AV state

    private var leftPlayer: AVPlayer?
    private var rightPlayer: AVPlayer?

    private var leftTimeObserver: Any?
    private var rightTimeObserver: Any?

    private var isLinked: Bool = false
    private var isSharedPlaying: Bool = false
    private var syncOffsetSeconds: Double = 0.0

    // MARK: - UI

    private let closeButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 22 // 44 / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()

    private let closeButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular) // Match right side exactly
        let img = UIImage(systemName: "chevron.backward.circle", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        b.setTitle(" Back", for: .normal)
        b.tintColor = .white
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = .clear
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let linkButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular) // Match right side exactly
        b.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
        b.setTitle(" Link", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.tintColor = .systemGray
        b.setTitleColor(.systemGray, for: .normal)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isEnabled = false
        return b
    }()
    
    private let editButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        b.setImage(UIImage(systemName: "film.circle", withConfiguration: cfg), for: .normal)
        b.setTitle(" Edit", for: .normal)
        b.tintColor = .white
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = .clear
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let topRightContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()

    private let restartButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold) // Changed to 32
        b.setImage(UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemGreen
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let stopSessionButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold) // Changed to 32
        b.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemRed
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let stackView: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.alignment = .fill
        s.distribution = .fillEqually
        s.spacing = 1
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let leftContainer = VideoPaneView()
    private let rightContainer = VideoPaneView()

    // MARK: - Shared UI
    private let sharedControlsContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 24
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true // Hidden by default
        return v
    }()
    
    private let sharedPlayPauseButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        b.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    
    private let sharedScrubSlider: UISlider = {
        let s = UISlider()
        
        // 20x20 thumb - stroke fits PERFECTLY inside slider bounds
        let thumbSize: CGFloat = 20
        let strokeWidth: CGFloat = 1.5  // Thinner stroke
        let padding: CGFloat = 1.5      // Extra safety margin

        let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize))
            .image { context in
                // White fill (smaller circle)
                let fillSize = thumbSize - (strokeWidth * 2) - (padding * 2)
                let fillRect = CGRect(x: padding + strokeWidth, y: padding + strokeWidth,
                                     width: fillSize, height: fillSize)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: fillRect).fill()
                
                // Yellow stroke (slightly inset)
                let strokeRect = CGRect(x: padding, y: padding,
                                       width: thumbSize - (padding * 2),
                                       height: thumbSize - (padding * 2))
                UIColor.systemYellow.setStroke()
                let strokePath = UIBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = strokeWidth
                strokePath.lineCapStyle = .round
                strokePath.lineJoinStyle = .round
                strokePath.stroke()
            }

        s.setThumbImage(thumbImage.withRenderingMode(.alwaysOriginal), for: .normal)

        s.minimumTrackTintColor = .white
        s.maximumTrackTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let sharedTimeLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        l.textColor = .white
        l.text = "00:00.00"
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()
    
    // MARK: - Lifecycle

    init(leftURL: URL?, rightURL: URL?) {
        self.leftURL = leftURL
        self.rightURL = rightURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupUI()
        setupActions()
        configurePlayers()
        
        // Listen for Remove button taps
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoveNotification(_:)),
            name: Notification.Name("VideoPaneViewRemoveTapped"),
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateStackAxisForOrientation()
    }

    deinit {
        tearDownPlayers()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.addSubview(stackView)
        
        view.addSubview(closeButtonContainer)
        closeButtonContainer.addSubview(closeButton)
        closeButtonContainer.addSubview(linkButton)
        closeButtonContainer.addSubview(editButton)
        
        view.addSubview(topRightContainer)
        topRightContainer.addSubview(restartButton)
        topRightContainer.addSubview(stopSessionButton)

        stackView.addArrangedSubview(leftContainer)
        stackView.addArrangedSubview(rightContainer)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // Left Container (Back & Link & Edit button)
            closeButtonContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButtonContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            closeButtonContainer.heightAnchor.constraint(equalToConstant: 44),
            closeButtonContainer.widthAnchor.constraint(equalToConstant: 320), // Widened for 3 buttons
            
            closeButton.leadingAnchor.constraint(equalTo: closeButtonContainer.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            
            linkButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 16),
            linkButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            
            editButton.leadingAnchor.constraint(equalTo: linkButton.trailingAnchor, constant: 16),
            editButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),

            // Top Right Container
            topRightContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            topRightContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            topRightContainer.heightAnchor.constraint(equalToConstant: 64),
            topRightContainer.widthAnchor.constraint(equalToConstant: 108),

            restartButton.leadingAnchor.constraint(equalTo: topRightContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: topRightContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: 44),
            restartButton.heightAnchor.constraint(equalToConstant: 44),

            stopSessionButton.trailingAnchor.constraint(equalTo: topRightContainer.trailingAnchor, constant: -10),
            stopSessionButton.centerYAnchor.constraint(equalTo: topRightContainer.centerYAnchor),
            stopSessionButton.widthAnchor.constraint(equalToConstant: 44),
            stopSessionButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        linkButton.setContentHuggingPriority(.required, for: .horizontal)
        linkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        // Add Shared Controls to view
        view.addSubview(sharedControlsContainer)
        sharedControlsContainer.addSubview(sharedPlayPauseButton)
        sharedControlsContainer.addSubview(sharedScrubSlider)
        sharedControlsContainer.addSubview(sharedTimeLabel)

        NSLayoutConstraint.activate([
            sharedControlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            sharedControlsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            sharedControlsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            sharedControlsContainer.heightAnchor.constraint(equalToConstant: 48),

            sharedPlayPauseButton.leadingAnchor.constraint(equalTo: sharedControlsContainer.leadingAnchor, constant: 8),
            sharedPlayPauseButton.centerYAnchor.constraint(equalTo: sharedControlsContainer.centerYAnchor),
            sharedPlayPauseButton.widthAnchor.constraint(equalToConstant: 32),
            sharedPlayPauseButton.heightAnchor.constraint(equalToConstant: 32),

            sharedTimeLabel.trailingAnchor.constraint(equalTo: sharedControlsContainer.trailingAnchor, constant: -12),
            sharedTimeLabel.centerYAnchor.constraint(equalTo: sharedControlsContainer.centerYAnchor),
            sharedTimeLabel.widthAnchor.constraint(equalToConstant: 72),

            sharedScrubSlider.leadingAnchor.constraint(equalTo: sharedPlayPauseButton.trailingAnchor, constant: 10),
            sharedScrubSlider.trailingAnchor.constraint(equalTo: sharedTimeLabel.leadingAnchor, constant: -10),
            sharedScrubSlider.centerYAnchor.constraint(equalTo: sharedControlsContainer.centerYAnchor)
        ])
    }

    private func setupActions() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        linkButton.addTarget(self, action: #selector(linkTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)

        restartButton.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped), for: .touchUpInside)

        leftContainer.addButton.addTarget(self, action: #selector(addLeftTapped), for: .touchUpInside)
        rightContainer.addButton.addTarget(self, action: #selector(addRightTapped), for: .touchUpInside)

        leftContainer.scrubSlider.addTarget(self, action: #selector(leftSliderChanged(_:)), for: .valueChanged)
        rightContainer.scrubSlider.addTarget(self, action: #selector(rightSliderChanged(_:)), for: .valueChanged)
        
        sharedPlayPauseButton.addTarget(self, action: #selector(sharedPlayPauseTapped), for: .touchUpInside)
        sharedScrubSlider.addTarget(self, action: #selector(sharedSliderChanged(_:)), for: .valueChanged)
    }
    
    private func updateLinkButtonState() {
        let bothLoaded = (leftPlayer != nil && rightPlayer != nil)
        
        if !bothLoaded && isLinked {
            linkTapped()
        }
        
        linkButton.isEnabled = bothLoaded
        
        if bothLoaded {
            let color: UIColor = isLinked ? .systemYellow : .white
            linkButton.tintColor = color
            linkButton.setTitleColor(color, for: .normal)
        } else {
            linkButton.tintColor = .systemGray
            linkButton.setTitleColor(.systemGray, for: .normal)
        }
        
        // Force layout to recalculate the button width after text changes
        closeButtonContainer.setNeedsLayout()
        closeButtonContainer.layoutIfNeeded()
    }

    private func updateStackAxisForOrientation() {
        if view.bounds.width > view.bounds.height {
            // Landscape: side by side
            stackView.axis = .horizontal
        } else {
            // Portrait: top / bottom
            stackView.axis = .vertical
        }
    }

    // MARK: - Player setup

    private func configurePlayers() {
        configureLeftPlayer()
        configureRightPlayer()
        updateLinkButtonState()
    }

    private func configureLeftPlayer() {
        if let url = leftURL {
            leftContainer.showVideo()
            leftContainer.resetPlayState()
            let player = AVPlayer(url: url)
            leftPlayer = player
            leftContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: true)
        } else {
            leftContainer.showAddButton()
        }
    }

    private func configureRightPlayer() {
        if let url = rightURL {
            rightContainer.showVideo()
            rightContainer.resetPlayState()
            let player = AVPlayer(url: url)
            rightPlayer = player
            rightContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: false)
        } else {
            rightContainer.showAddButton()
        }
    }

    private func addTimeObserver(for player: AVPlayer, isLeft: Bool) {
        let interval = CMTime(value: 1, timescale: 60)
        
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            guard let self = self, let p = player else { return }
            guard p.currentItem?.status == .readyToPlay else { return }
            
            let current = CMTimeGetSeconds(time)
            var calculatedValue: Float = 0.0 // Renamed to avoid any shadow confusion
            
            if let durationTime = p.currentItem?.duration, CMTIME_IS_NUMERIC(durationTime) {
                let total = CMTimeGetSeconds(durationTime)
                if total > 0 {
                    calculatedValue = Float(current / total)
                }
            }
            
            DispatchQueue.main.async {
                if self.isLinked {
                    if isLeft {
                        if !self.sharedScrubSlider.isTracking {
                            // Assign explicitly
                            self.sharedScrubSlider.value = calculatedValue
                        }
                        self.sharedTimeLabel.text = self.formatTime(current)

                        if calculatedValue >= 0.99 && self.isSharedPlaying {
                            self.isSharedPlaying = false
                            self.updateSharedPlayPauseIcon()
                        }
                    }
                } else {
                    if isLeft {
                        self.leftContainer.updateSlider(value: calculatedValue, currentTime: current, totalTime: 0)
                    } else {
                        self.rightContainer.updateSlider(value: calculatedValue, currentTime: current, totalTime: 0)
                    }
                }
            }
        }
        
        if isLeft {
            leftTimeObserver = observer
        } else {
            rightTimeObserver = observer
        }
    }
    
    private func formatTime(_ secs: Double) -> String {
        guard secs.isFinite && secs >= 0 else { return "00:00.00" }
        let totalSeconds = Int(secs)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let fraction = secs.truncatingRemainder(dividingBy: 1.0)
        let hundredths = Int(fraction * 100)
        return String(format: "%02d:%02d.%02d", m, s, hundredths)
    }

    private func tearDownPlayers() {
        if let obs = leftTimeObserver {
            leftPlayer?.removeTimeObserver(obs)
        }
        if let obs = rightTimeObserver {
            rightPlayer?.removeTimeObserver(obs)
        }
        leftTimeObserver = nil
        rightTimeObserver = nil

        leftPlayer?.pause()
        leftPlayer = nil
        rightPlayer?.pause()
        rightPlayer = nil
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        tearDownPlayers()
        dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }
    
    @objc private func restartTapped() {
        // Just signal up; do NOT dismiss here.
        onRestartRequested?()
    }

    @objc private func stopSessionTapped() {
        // Just signal up; do NOT dismiss here.
        onStopSessionRequested?()
    }

    @objc private func addLeftTapped() {
        leftContainer.showLoading()
        presentPicker(forLeft: true)
    }

    @objc private func addRightTapped() {
        rightContainer.showLoading()
        presentPicker(forLeft: false)
    }

    private func presentPicker(forLeft: Bool) {
        let picker = UIImagePickerController()
        picker.sourceType = .savedPhotosAlbum // shows recent first
        picker.mediaTypes = [UTType.movie.identifier, UTType.video.identifier]
        picker.delegate = self
        picker.videoExportPreset = AVAssetExportPresetPassthrough
        picker.modalPresentationStyle = .fullScreen
        picker.view.tag = forLeft ? 1 : 2  // use tag to know which side

        present(picker, animated: true)
    }

    @objc private func leftSliderChanged(_ sender: UISlider) {
        guard let player = leftPlayer, let duration = player.currentItem?.duration, CMTIME_IS_NUMERIC(duration) else { return }
        let total = CMTimeGetSeconds(duration)
        let targetSeconds = Double(sender.value) * total
        
        // Update the text instantly while dragging!
        leftContainer.updateSlider(value: sender.value, currentTime: targetSeconds, totalTime: 0)
        
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func rightSliderChanged(_ sender: UISlider) {
        guard let player = rightPlayer, let duration = player.currentItem?.duration, CMTIME_IS_NUMERIC(duration) else { return }
        let total = CMTimeGetSeconds(duration)
        let targetSeconds = Double(sender.value) * total
        
        // Update the text instantly while dragging!
        rightContainer.updateSlider(value: sender.value, currentTime: targetSeconds, totalTime: 0)
        
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func linkTapped() {
        guard let leftP = leftPlayer, let rightP = rightPlayer else {
            let alert = UIAlertController(title: "Cannot Link", message: "Please load both videos first.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        isLinked.toggle()
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)

        if isLinked {
            // Linked state
            linkButton.setImage(UIImage(systemName: "link.circle.fill", withConfiguration: cfg), for: .normal)
            linkButton.setTitle(" Unlink", for: .normal)
            linkButton.tintColor = .systemYellow
            linkButton.setTitleColor(.systemYellow, for: .normal)

            // Pause both to sync
            leftP.pause()
            rightP.pause()
            leftContainer.resetPlayState()
            rightContainer.resetPlayState()
            isSharedPlaying = false
            updateSharedPlayPauseIcon()

            // Calculate the exact offset between the two videos
            let leftT = CMTimeGetSeconds(leftP.currentTime())
            let rightT = CMTimeGetSeconds(rightP.currentTime())
            syncOffsetSeconds = rightT - leftT

            // Swap UI
            leftContainer.controlsContainer.isHidden = true
            rightContainer.controlsContainer.isHidden = true
            sharedControlsContainer.isHidden = false

            // Set initial shared slider state (Driven by Left Video)
            if let dur = leftP.currentItem?.duration, CMTIME_IS_NUMERIC(dur) {
                let total = CMTimeGetSeconds(dur)
                if total > 0 {
                    sharedScrubSlider.value = Float(leftT / total)
                }
            }
            sharedTimeLabel.text = formatTime(leftT)

        } else {
            // Unlinked state
            linkButton.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
            linkButton.setTitle(" Link", for: .normal)
            linkButton.tintColor = .white
            linkButton.setTitleColor(.white, for: .normal)

            // Pause shared
            leftP.pause()
            rightP.pause()
            isSharedPlaying = false
            updateSharedPlayPauseIcon()

            // Swap UI back
            sharedControlsContainer.isHidden = true
            leftContainer.controlsContainer.isHidden = false
            rightContainer.controlsContainer.isHidden = false
        }
    }
    
    @objc private func editTapped() {
        leftContainer.toggleEditMode()
        rightContainer.toggleEditMode()
    }

    @objc private func handleRemoveNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let container = userInfo["container"] as? VideoPaneView else { return }
        
        if container === leftContainer {
            leftURL = nil
            leftPlayer?.pause()
            if let obs = leftTimeObserver {
                leftPlayer?.removeTimeObserver(obs)
                leftTimeObserver = nil
            }
            leftPlayer = nil
            leftContainer.clearPlayer()  // ← ADD THIS LINE
            leftContainer.showAddButton()
            
            // Clean up temp file
            if let url = leftURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
            
        } else if container === rightContainer {
            rightURL = nil
            rightPlayer?.pause()
            if let obs = rightTimeObserver {
                rightPlayer?.removeTimeObserver(obs)
                rightTimeObserver = nil
            }
            rightPlayer = nil
            rightContainer.clearPlayer()  // ← ADD THIS LINE
            rightContainer.showAddButton()
            
            // Clean up temp file
            if let url = rightURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        updateLinkButtonState()
    }

    @objc private func sharedPlayPauseTapped() {
        guard let leftP = leftPlayer, let rightP = rightPlayer else { return }
        
        if isSharedPlaying {
            // Pause both
            leftP.pause()
            rightP.pause()
            isSharedPlaying = false
        } else {
            // Seek both to start + play (restart behavior)
            leftP.seek(to: .zero)
            rightP.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in
                leftP.play()
                rightP.play()
                self.isSharedPlaying = true
                self.updateSharedPlayPauseIcon()
            })
            updateSharedPlayPauseIcon()  // Immediate feedback
        }
    }

    private func updateSharedPlayPauseIcon() {
        let iconName = isSharedPlaying ? "pause.circle.fill" : "play.circle.fill"
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        sharedPlayPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: cfg), for: .normal)
    }

    @objc private func sharedSliderChanged(_ sender: UISlider) {
        guard let leftP = leftPlayer, let rightP = rightPlayer else { return }
        guard let leftDur = leftP.currentItem?.duration, CMTIME_IS_NUMERIC(leftDur) else { return }

        let totalLeft = CMTimeGetSeconds(leftDur)
        
        // Calculate exact target times based on the offset
        let targetLeft = Double(sender.value) * totalLeft
        let targetRight = targetLeft + syncOffsetSeconds

        // Update text instantly
        sharedTimeLabel.text = formatTime(targetLeft)

        // Seek both players simultaneously!
        let timeL = CMTime(seconds: targetLeft, preferredTimescale: 600)
        let timeR = CMTime(seconds: targetRight, preferredTimescale: 600)

        leftP.seek(to: timeL, toleranceBefore: .zero, toleranceAfter: .zero)
        rightP.seek(to: timeR, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - Picker delegate

extension SplitVideoView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        if picker.view.tag == 1 {
            leftContainer.hideLoading()
        } else {
            rightContainer.hideLoading()
        }
        dismiss(animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        defer {
            if picker.view.tag == 1 {
                leftContainer.hideLoading()
            } else {
                rightContainer.hideLoading()
            }
            picker.dismiss(animated: true)
        }
        guard let url = info[.mediaURL] as? URL else { return }

        let forLeft = (picker.view.tag == 1)

        if isLinked {
            linkTapped()
        }
        
        if forLeft {
            leftURL = url
            leftPlayer?.pause()
            leftPlayer = AVPlayer(url: url)
            leftContainer.showVideo()
            leftContainer.resetPlayState()
            leftContainer.playerView.player = leftPlayer
            if let obs = leftTimeObserver {
                leftPlayer?.removeTimeObserver(obs)
                leftTimeObserver = nil
            }
            if let player = leftPlayer {
                addTimeObserver(for: player, isLeft: true)
            }
        } else {
            rightURL = url
            rightPlayer?.pause()
            rightPlayer = AVPlayer(url: url)
            rightContainer.showVideo()
            rightContainer.resetPlayState()
            rightContainer.playerView.player = rightPlayer
            if let obs = rightTimeObserver {
                rightPlayer?.removeTimeObserver(obs)
                rightTimeObserver = nil
            }
            if let player = rightPlayer {
                addTimeObserver(for: player, isLeft: false)
            }
        }
        
        updateLinkButtonState()
    }
    
    @objc private func removeVideoForContainer(_ container: VideoPaneView) {
        if container === leftContainer {
            leftURL = nil
            leftPlayer?.pause()
            leftPlayer = nil
            leftContainer.showAddButton()
            leftContainer.resetPlayState()
            
            // Clean up temp file if it was one of our clips
            if let url = leftURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
            
        } else if container === rightContainer {
            rightURL = nil
            rightPlayer?.pause()
            rightPlayer = nil
            rightContainer.showAddButton()
            rightContainer.resetPlayState()
            
            // Clean up temp file if it was one of our clips
            if let url = rightURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        // Update link button state and unlink if necessary
        updateLinkButtonState()
    }

}

// MARK: - VideoPaneView (subview for each side)
private final class VideoPaneView: UIView {
    let playerView = PlayerContainerView()
    let addButton = UIButton(type: .system)
    let removeButton = UIButton(type: .system)

    // Controls matching RecordedVideoView
    let controlsContainer = UIView()
    let playPauseButton = UIButton(type: .system)
    let scrubSlider = UISlider()
    let timeLabel = UILabel()
    let loadingSpinner = UIActivityIndicatorView(style: .large)
    
    private var isPlaying = false
    var isInEditMode = false

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .black

        playerView.translatesAutoresizingMaskIntoConstraints = false

        addButton.setTitle("Add Video", for: .normal)
        addButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        addButton.setTitleColor(.white, for: .normal)
        // Changed to match the scrubber purple color from RecordedVideoView
        addButton.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        // Reduced from 16 to 12 for less rounded look
        addButton.layer.cornerRadius = 12
        addButton.clipsToBounds = true
        addButton.translatesAutoresizingMaskIntoConstraints = false
        
        removeButton.setTitle("Remove", for: .normal)
        removeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        removeButton.setTitleColor(.white, for: .normal)
        removeButton.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1) // Purple
        removeButton.layer.cornerRadius = 12
        removeButton.clipsToBounds = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isHidden = true // Hidden by default
        removeButton.addTarget(self, action: #selector(removeVideoTapped), for: .touchUpInside)

        // Loading spinner
        loadingSpinner.color = .white
        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.isHidden = true
        
        // Container matches RecordedVideoView (black with 0.7 alpha)
        controlsContainer.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        controlsContainer.layer.cornerRadius = 24
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false

        // Play/Pause button
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)

        // Scrubber
        // Custom yellow-bordered white thumb
        // 20x20 thumb - stroke fits PERFECTLY inside slider bounds
        let thumbSize: CGFloat = 20
        let strokeWidth: CGFloat = 1.5  // Thinner stroke
        let padding: CGFloat = 1.5      // Extra safety margin

        let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize))
            .image { context in
                // White fill (smaller circle)
                let fillSize = thumbSize - (strokeWidth * 2) - (padding * 2)
                let fillRect = CGRect(x: padding + strokeWidth, y: padding + strokeWidth,
                                     width: fillSize, height: fillSize)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: fillRect).fill()
                
                // Yellow stroke (slightly inset)
                let strokeRect = CGRect(x: padding, y: padding,
                                       width: thumbSize - (padding * 2),
                                       height: thumbSize - (padding * 2))
                UIColor.systemYellow.setStroke()
                let strokePath = UIBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = strokeWidth
                strokePath.lineCapStyle = .round
                strokePath.lineJoinStyle = .round
                strokePath.stroke()
            }

        scrubSlider.setThumbImage(thumbImage.withRenderingMode(.alwaysOriginal), for: .normal)

        scrubSlider.minimumTrackTintColor = .white
        scrubSlider.maximumTrackTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        scrubSlider.translatesAutoresizingMaskIntoConstraints = false

        // Time Label
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.text = "00:00.00"
        timeLabel.textAlignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(playerView)
        addSubview(addButton)
        addSubview(removeButton)
        addSubview(loadingSpinner)
        addSubview(controlsContainer)
        
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(scrubSlider)
        controlsContainer.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            // Player spans the top without the title label pushing it down
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            // Give player the most space, keep controls at the bottom
            controlsContainer.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 8),
            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controlsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            controlsContainer.heightAnchor.constraint(equalToConstant: 48),

            addButton.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            addButton.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 140),
            addButton.heightAnchor.constraint(equalToConstant: 44),
            
            removeButton.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            removeButton.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 140),
            removeButton.heightAnchor.constraint(equalToConstant: 44),
            
            loadingSpinner.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),

            // Controls inside container
            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 8),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 32),
            playPauseButton.heightAnchor.constraint(equalToConstant: 32),

            timeLabel.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 72),

            scrubSlider.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            scrubSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            scrubSlider.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor)
        ])
    }

    @objc private func togglePlayPause() {
        guard let player = playerView.player else { return }
        
        if player.rate > 0 {
            // Currently playing → pause
            player.pause()
            isPlaying = false
        } else {
            // Paused OR at end → restart from beginning and play
            player.seek(to: .zero) { _ in
                player.play()
                self.isPlaying = true
                self.updatePlayPauseIcon()
            }
            updatePlayPauseIcon()  // Immediate visual feedback
        }
    }
    
    func toggleEditMode() {
        isInEditMode.toggle()
        
        if isInEditMode {
            if playerView.player != nil {
                showRemoveButton()
            } else {
                showAddButton()
            }
        } else {
            if playerView.player != nil {
                showVideo()
            } else {
                showAddButton()
            }
        }
    }
    
    func clearPlayer() {
        playerView.player = nil
        resetPlayState()
    }

    func resetPlayState() {
        isPlaying = false
        updatePlayPauseIcon()
        scrubSlider.value = 0
        timeLabel.text = "00:00.00"
    }

    private func updatePlayPauseIcon() {
        let iconName = isPlaying ? "pause.circle.fill" : "play.circle.fill"
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: cfg), for: .normal)
    }

    func showVideo() {
        addButton.isHidden = true
        removeButton.isHidden = true
        controlsContainer.isHidden = false
        playerView.isHidden = false
    }

    func showAddButton() {
        addButton.isHidden = false
        removeButton.isHidden = true
        controlsContainer.isHidden = true
        playerView.isHidden = false
    }

    func showRemoveButton() {
        addButton.isHidden = true
        removeButton.isHidden = false
        controlsContainer.isHidden = true
    }
    
    func showLoading() {
        addButton.isHidden = true
        loadingSpinner.startAnimating()
        loadingSpinner.isHidden = false
    }

    func hideLoading() {
        loadingSpinner.stopAnimating()
        loadingSpinner.isHidden = true
        // Restore appropriate state
        if playerView.player == nil {
            showAddButton()
        }
    }
    
    @objc private func removeVideoTapped() {
        // Post a notification that SplitVideoView can listen for
        let notificationName = Notification.Name("VideoPaneViewRemoveTapped")
        let userInfo: [String: VideoPaneView] = ["container": self]
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }

    func updateSlider(value: Float, currentTime: Double, totalTime: Double) {
        // ALWAYS update the text
        timeLabel.text = formatTime(currentTime)
        
        // Only override the physical slider position if the user IS NOT actively dragging it
        if !scrubSlider.isTracking {
            scrubSlider.value = value
        }
        
        // Auto-pause UI at the end of the video
        if value >= 0.99 && isPlaying {
            isPlaying = false
            updatePlayPauseIcon()
        }
    }

    private func formatTime(_ secs: Double) -> String {
        guard secs.isFinite && secs >= 0 else { return "00:00.00" }
        let totalSeconds = Int(secs)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let fraction = secs.truncatingRemainder(dividingBy: 1.0)
        let hundredths = Int(fraction * 100)
        return String(format: "%02d:%02d.%02d", m, s, hundredths)
    }
}

// Simple view whose backing layer is AVPlayerLayer
private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = newValue
        }
    }
}
