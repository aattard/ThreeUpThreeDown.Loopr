import UIKit
import AVFoundation
import Photos

final class RecordedVideoView: UIView, UIGestureRecognizerDelegate {

    // MARK: - Dependencies (injected)
    private weak var videoFileBuffer: VideoFileBuffer?
    private var isFrontCamera: Bool = false
    private var delaySeconds: Int = 7
    private var recordedRotationAngle: CGFloat = 0

    var onRestartRequested: (() -> Void)?
    var onStopSessionRequested: (() -> Void)?

    /// Called when the user taps Split (enabled when either bucket has a temp clip).
    /// `leftURL` corresponds to bucket 1, `rightURL` corresponds to bucket 2.
    var onSplitScreenRequested: ((URL?, URL?) -> Void)?

    // MARK: - AVPlayer (scrub + playback)
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerTimeObserver: Any?
    private var playerLoopObserver: NSObjectProtocol?
    private var isSeeking: Bool = false
    private var pendingScrubIndex: Int?

    // MARK: - Scrub / loop state
    private var scrubberPosition: Int = 0 // global frame index
    private var isLooping: Bool = false

    // MARK: - Clip selection
    private var clipStartIndex: Int = 0
    private var clipEndIndex: Int = 0
    private var isClipMode: Bool = false
    private var clipPlayheadPosition: Int = 0

    // MARK: - Split temp clips (buckets)
    private var tempClipBucket1URL: URL?
    private var tempClipBucket2URL: URL?

    // MARK: - Pan gesture tracking
    private var initialLeftPosition: CGFloat = 0
    private var initialRightPosition: CGFloat = 0
    private var initialPlayheadPosition: CGFloat = 0
    private var initialClipStartIndex: Int = 0
    private var initialClipEndIndex: Int = 0
    private var initialClipPlayheadPosition: Int = 0
    private var isDraggingHandle: Bool = false
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Frame dial
    private let frameDial = FrameDial()

    // MARK: - Zoom / pan
    private let zoomContainer = UIView()
    private var currentScale: CGFloat = 1.0
    private var lastScale: CGFloat = 1.0
    private var currentOffset: CGPoint = .zero
    private var lastOffset: CGPoint = .zero

    // MARK: - Config
    private var scrubDurationSeconds: Int { Settings.shared.bufferDurationSeconds }
    private var scrubberGrabOffsetX: CGFloat = 0
    private let handleWidth: CGFloat = 20

    // MARK: - UI
    private let successFeedbackView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.layer.cornerRadius = 20
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0

        let cfg = UIImage.SymbolConfiguration(pointSize: 120, weight: .bold)
        let iv = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: cfg))
        iv.tintColor = .white
        iv.contentMode = .center
        iv.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(iv)

        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 150),
            iv.heightAnchor.constraint(equalToConstant: 150)
        ])
        return v
    }()

    private let controlsContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 40
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()

    private let playPauseButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let timelineContainer: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = false
        return v
    }()

    private let scrubberBackground: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        v.layer.cornerRadius = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let scrubberPlayhead: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    private let scrubberPlayheadKnob: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.layer.cornerRadius = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    private let scrubberTouchArea: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = true
        return v
    }()

    private let leftDimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 0.5)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.layer.cornerRadius = 6
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        return v
    }()

    private let rightDimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 0.5)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.layer.cornerRadius = 6
        v.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        return v
    }()

    private let clipRegionBackground: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        v.layer.cornerRadius = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let leftTrimHandle: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.layer.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.isUserInteractionEnabled = true

        let ch = UIImageView(image: UIImage(systemName: "chevron.compact.left"))
        ch.tintColor = .black
        ch.contentMode = .center
        ch.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(ch)

        NSLayoutConstraint.activate([
            ch.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            ch.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ch.widthAnchor.constraint(equalToConstant: 12),
            ch.heightAnchor.constraint(equalToConstant: 20)
        ])
        return v
    }()

    private let rightTrimHandle: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.layer.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.isUserInteractionEnabled = true

        let ch = UIImageView(image: UIImage(systemName: "chevron.compact.right"))
        ch.tintColor = .black
        ch.contentMode = .center
        ch.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(ch)

        NSLayoutConstraint.activate([
            ch.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            ch.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ch.widthAnchor.constraint(equalToConstant: 12),
            ch.heightAnchor.constraint(equalToConstant: 20)
        ])
        return v
    }()

    private let topBorder: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let bottomBorder: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let clipPlayhead: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }()

    private let clipPlayheadKnob: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.layer.cornerRadius = 8
        v.layer.borderWidth = 2
        v.layer.borderColor = UIColor.systemYellow.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    private let playheadTouchArea: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = true
        return v
    }()

    private let timeLabel: UILabel = {
        let l = UILabel()
        l.text = "LIVE"
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Clip / Save-to-Photos toggle button (film -> download icon in clip mode)
    private let clipSaveButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "film.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let closeButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 22
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()
    
    // Cancel clip mode button
    private let cancelClipButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        let img = UIImage(systemName: "chevron.backward.circle", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        //b.setTitle(" Back", for: .normal) // space so text doesnâ€™t touch icon
        b.tintColor = .white
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = UIColor.clear
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()

    // NEW: Top-left container for clip controls
    private let topLeftButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        v.clipsToBounds = true
        return v
    }()

    private let topLeftButtonStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.alignment = .center
        s.distribution = .fill
        s.spacing = 6
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let bucketDivider: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }()

    private let bucket1Button: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        b.setImage(UIImage(systemName: "1.square", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()

    private let bucket2Button: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        b.setImage(UIImage(systemName: "2.square", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()

    private let splitScreenButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        b.setImage(UIImage(systemName: "square.split.2x1", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemGray3
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        b.isEnabled = false
        return b
    }()

    // MARK: - Top right container (restart / end session)
    private let topRightButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()

    private let stopSessionButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemRed
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let restartButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemGreen
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let bufferLimitLabel: UIButton = {
        let b = UIButton(type: .system)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        b.layer.cornerRadius = 12
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isUserInteractionEnabled = false
        b.isHidden = true
        b.alpha = 0
        return b
    }()

    // MARK: - Mutable constraints
    private var leftHandleConstraint: NSLayoutConstraint?
    private var rightHandleConstraint: NSLayoutConstraint?
    private var playheadConstraint: NSLayoutConstraint?
    private var playheadWidthConstraint: NSLayoutConstraint?
    private var clipBackgroundLeadingConstraint: NSLayoutConstraint?
    private var clipBackgroundTrailingConstraint: NSLayoutConstraint?
    private var scrubberPlayheadConstraint: NSLayoutConstraint?
    private var scrubberTouchAreaConstraint: NSLayoutConstraint?

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        // zoomContainer sits beneath everything — playerLayer lives inside it
        clipsToBounds = true
        zoomContainer.clipsToBounds = true
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomContainer)
        sendSubviewToBack(zoomContainer)
        NSLayoutConstraint.activate([
            zoomContainer.topAnchor.constraint(equalTo: topAnchor),
            zoomContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            zoomContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            zoomContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        addSubview(successFeedbackView)
        setupControls()

        NSLayoutConstraint.activate([
            successFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            successFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            successFeedbackView.widthAnchor.constraint(equalToConstant: 200),
            successFeedbackView.heightAnchor.constraint(equalToConstant: 200)
        ])

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)

        setupZoomGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        tearDownPlayer()
        cleanupTempSplitClips()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // playerLayer must fill zoomContainer (AutoLayout positions zoomContainer itself)
        // Do NOT set zoomContainer.frame manually — its AutoLayout constraints handle that.
        playerLayer?.frame = zoomContainer.bounds
        applyPlayerTransformNow()

        // Force the timeline to figure out its new width FIRST, so bounds.width is accurate.
        timelineContainer.layoutIfNeeded()

        // Update split icon on rotations / size changes.
        updateSplitIconForCurrentOrientation()

        if isClipMode {
            updateClipHandlePositions()
            updatePlayheadPosition()
        } else {
            updateScrubberPlayheadPosition()
        }
    }

    // MARK: - Public API
    func presentPausedRecording(
        buffer: VideoFileBuffer,
        playerItem: AVPlayerItem,
        composition: AVMutableComposition,
        delaySeconds: Int,
        isFrontCamera: Bool,
        recordedRotationAngle: CGFloat,
        initialScrubberIndex: Int,
        recordedSeconds: Int,
        bufferDurationSeconds: Int
    ) {
        // Reset split temps whenever a new recording is presented
        cleanupTempSplitClips()

        self.videoFileBuffer = buffer
        self.delaySeconds = delaySeconds
        self.isFrontCamera = isFrontCamera
        self.recordedRotationAngle = recordedRotationAngle

        // Reset zoom whenever a new recording is presented
        currentScale = 1.0
        currentOffset = .zero
        lastScale = 1.0
        lastOffset = .zero
        zoomContainer.transform = .identity

        scrubberPosition = initialScrubberIndex
        clipStartIndex = 0
        clipEndIndex = 0
        clipPlayheadPosition = 0
        isClipMode = false
        isLooping = false

        if recordedSeconds > bufferDurationSeconds {
            bufferLimitLabel.isHidden = false
            bufferLimitLabel.alpha = 1

            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.minute, .second]
            formatter.unitsStyle = .full
            let rawTimeString = formatter.string(from: TimeInterval(bufferDurationSeconds)) ?? "\(bufferDurationSeconds) seconds"
            let capitalizedTimeString = rawTimeString.capitalized
            bufferLimitLabel.setTitle("Last \(capitalizedTimeString) Recorded", for: .normal)
        } else {
            bufferLimitLabel.isHidden = true
            bufferLimitLabel.alpha = 0
        }

        setupPlayer(with: playerItem, composition: composition)

        showControls()
        seekPlayer(toFrameIndex: scrubberPosition, completion: nil)
        updateScrubberPlayheadPosition()
        updateTimeLabel()
        setupFrameDial()

        // Re-apply zoom transform after layout settles
        DispatchQueue.main.async {
            self.updateTransform()
        }
    }

    private func setupFrameDial() {
        guard let buf = videoFileBuffer else { return }
        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let displayableFrames = max(1, pausePoint - oldest)

        frameDial.totalFrames  = displayableFrames
        frameDial.currentFrame = max(0, scrubberPosition - oldest)

        frameDial.onFrameStep = { [weak self] delta in
            guard let self, let buf = self.videoFileBuffer else { return }
            let fps = Settings.shared.currentFPS(isFrontCamera: self.isFrontCamera)
            let totalFrames = buf.getCurrentFrameCount()
            let requiredFrames = self.delaySeconds * fps
            let pausePoint = max(0, totalFrames - requiredFrames)
            let oldest = self.oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)

            if self.isClipMode {
                let newPos = self.clipPlayheadPosition + delta
                let clamped = max(self.clipStartIndex, min(newPos, self.clipEndIndex))
                self.clipPlayheadPosition = clamped
                self.frameDial.currentFrame = max(0, clamped - oldest)
                self.updatePlayheadPosition()
                self.updateTimeLabel()
                self.seekPlayer(toFrameIndex: clamped, completion: nil)
            } else {
                let newPos = self.scrubberPosition + delta
                let clamped = max(oldest, min(newPos, pausePoint))
                self.scrubberPosition = clamped
                self.frameDial.currentFrame = max(0, clamped - oldest)
                self.updateScrubberPlayheadPosition()
                self.updateTimeLabel()
                self.seekPlayer(toFrameIndex: clamped, completion: nil)
            }
        }
    }

    // MARK: - Player transform
    func applyPlayerTransformNow() {
        guard let pl = playerLayer else { return }

        // Reset the layer's own transform (rotation/mirror handled by videoComposition)
        // Use zoomContainer.bounds — playerLayer lives inside zoomContainer, not self
        pl.setAffineTransform(.identity)
        pl.frame = zoomContainer.bounds.isEmpty ? bounds : zoomContainer.bounds

        let currentOri = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        let isAppPortrait = currentOri == .portrait || currentOri == .portraitUpsideDown || currentOri == .unknown
        let isVideoPortrait = Int(recordedRotationAngle) == 90 || Int(recordedRotationAngle) == 270

        if isAppPortrait == isVideoPortrait {
            pl.videoGravity = .resizeAspectFill
        } else {
            pl.videoGravity = .resizeAspect
        }
    }

    // MARK: - Controls setup
    private func setupControls() {
        addSubview(controlsContainer)
        addSubview(topRightButtonContainer)
        addSubview(topLeftButtonContainer)
        addSubview(bufferLimitLabel)
        frameDial.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.addSubview(frameDial)

        // Bottom controls
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(timelineContainer)
        controlsContainer.addSubview(timeLabel)

        // Top right controls
        topRightButtonContainer.addSubview(restartButton)
        topRightButtonContainer.addSubview(stopSessionButton)

        topLeftButtonContainer.addSubview(topLeftButtonStack)

        // Order: Cancel, Save, divider, 1, 2, Split
        topLeftButtonStack.addArrangedSubview(cancelClipButton)
        topLeftButtonStack.addArrangedSubview(clipSaveButton)
        topLeftButtonStack.addArrangedSubview(bucketDivider)
        topLeftButtonStack.addArrangedSubview(bucket1Button)
        topLeftButtonStack.addArrangedSubview(bucket2Button)
        topLeftButtonStack.addArrangedSubview(splitScreenButton)

        // Use custom spacing to keep normal spacing around cancel/save and tight spacing around the buckets
        topLeftButtonStack.spacing = 6
        topLeftButtonStack.setCustomSpacing(-6, after: cancelClipButton)
        topLeftButtonStack.setCustomSpacing(10, after: clipSaveButton)
        topLeftButtonStack.setCustomSpacing(-6, after: bucket1Button)
        topLeftButtonStack.setCustomSpacing(-6, after: bucket2Button)

        // Timeline subviews
        timelineContainer.addSubview(scrubberBackground)
        timelineContainer.addSubview(scrubberPlayhead)
        scrubberPlayhead.addSubview(scrubberPlayheadKnob)
        timelineContainer.addSubview(scrubberTouchArea)

        timelineContainer.addSubview(clipRegionBackground)
        timelineContainer.addSubview(leftDimView)
        timelineContainer.addSubview(rightDimView)
        timelineContainer.addSubview(topBorder)
        timelineContainer.addSubview(bottomBorder)

        timelineContainer.addSubview(playheadTouchArea)
        timelineContainer.addSubview(leftTrimHandle)
        timelineContainer.addSubview(rightTrimHandle)
        timelineContainer.addSubview(clipPlayhead)
        clipPlayhead.addSubview(clipPlayheadKnob)

        // Targets
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped), for: .touchUpInside)
        restartButton.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)

        clipSaveButton.addTarget(self, action: #selector(clipSaveButtonTapped), for: .touchUpInside)
        cancelClipButton.addTarget(self, action: #selector(cancelClipTapped), for: .touchUpInside)

        bucket1Button.addTarget(self, action: #selector(bucket1Tapped), for: .touchUpInside)
        bucket2Button.addTarget(self, action: #selector(bucket2Tapped), for: .touchUpInside)
        splitScreenButton.addTarget(self, action: #selector(splitScreenTapped), for: .touchUpInside)

        // Gestures
        let leftPan = UIPanGestureRecognizer(target: self, action: #selector(handleLeftTrimPan(_:)))
        leftTrimHandle.addGestureRecognizer(leftPan)

        let rightPan = UIPanGestureRecognizer(target: self, action: #selector(handleRightTrimPan(_:)))
        rightTrimHandle.addGestureRecognizer(rightPan)

        let playheadPan = UIPanGestureRecognizer(target: self, action: #selector(handlePlayheadPan(_:)))
        playheadTouchArea.addGestureRecognizer(playheadPan)

        let scrubberPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubberPan(_:)))
        scrubberPan.delegate = self
        timelineContainer.addGestureRecognizer(scrubberPan)

        let timelineTap = UITapGestureRecognizer(target: self, action: #selector(handleTimelineTap(_:)))
        timelineTap.cancelsTouchesInView = false
        timelineContainer.addGestureRecognizer(timelineTap)

        // Constraints
        NSLayoutConstraint.activate([
            // Top right container
            topRightButtonContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            topRightButtonContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            topRightButtonContainer.heightAnchor.constraint(equalToConstant: 64),
            topRightButtonContainer.widthAnchor.constraint(equalToConstant: 108),

            restartButton.leadingAnchor.constraint(equalTo: topRightButtonContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: topRightButtonContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: 44),
            restartButton.heightAnchor.constraint(equalToConstant: 44),

            stopSessionButton.trailingAnchor.constraint(equalTo: topRightButtonContainer.trailingAnchor, constant: -10),
            stopSessionButton.centerYAnchor.constraint(equalTo: topRightButtonContainer.centerYAnchor),
            stopSessionButton.widthAnchor.constraint(equalToConstant: 44),
            stopSessionButton.heightAnchor.constraint(equalToConstant: 44),

            // Top left container
            topLeftButtonContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            topLeftButtonContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            topLeftButtonContainer.heightAnchor.constraint(equalToConstant: 64),

            // Prevent overlap with top right (compress if needed on small phones)
            topLeftButtonContainer.trailingAnchor.constraint(lessThanOrEqualTo: topRightButtonContainer.leadingAnchor, constant: -10),

            // Let the stack dictate the width of the container
            topLeftButtonStack.leadingAnchor.constraint(equalTo: topLeftButtonContainer.leadingAnchor, constant: 10),
            topLeftButtonStack.trailingAnchor.constraint(equalTo: topLeftButtonContainer.trailingAnchor, constant: -10),
            topLeftButtonStack.centerYAnchor.constraint(equalTo: topLeftButtonContainer.centerYAnchor),

            // Button sizing in stack
            //cancelClipButton.heightAnchor.constraint(equalToConstant: 44),

            clipSaveButton.widthAnchor.constraint(equalToConstant: 44),
            clipSaveButton.heightAnchor.constraint(equalToConstant: 44),

            bucket1Button.widthAnchor.constraint(equalToConstant: 44),
            bucket1Button.heightAnchor.constraint(equalToConstant: 44),

            bucket2Button.widthAnchor.constraint(equalToConstant: 44),
            bucket2Button.heightAnchor.constraint(equalToConstant: 44),

            splitScreenButton.widthAnchor.constraint(equalToConstant: 44),
            splitScreenButton.heightAnchor.constraint(equalToConstant: 44),

            bucketDivider.heightAnchor.constraint(equalToConstant: 34),

            // Bottom controls container — taller to fit dial row
            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controlsContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            controlsContainer.heightAnchor.constraint(equalToConstant: 98),

            // Row 1: play | timeline | time  (pinned to top of container)
            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 20),
            playPauseButton.topAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: 10),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            timeLabel.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -20),
            timeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 58),

            timelineContainer.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            timelineContainer.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            timelineContainer.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            timelineContainer.heightAnchor.constraint(equalToConstant: 36),

            // Row 2: frame dial — 75% of timeline width, centred below it
            frameDial.centerXAnchor.constraint(equalTo: timelineContainer.centerXAnchor),
            frameDial.widthAnchor.constraint(equalTo: timelineContainer.widthAnchor, multiplier: 0.75),
            frameDial.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 6),
            frameDial.heightAnchor.constraint(equalToConstant: 28),
            frameDial.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: -10),

            scrubberBackground.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            scrubberBackground.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            scrubberBackground.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberBackground.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            scrubberPlayhead.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberPlayhead.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            scrubberPlayhead.widthAnchor.constraint(equalToConstant: 3),

            scrubberPlayheadKnob.centerXAnchor.constraint(equalTo: scrubberPlayhead.centerXAnchor),
            scrubberPlayheadKnob.topAnchor.constraint(equalTo: scrubberPlayhead.topAnchor, constant: -6),
            scrubberPlayheadKnob.widthAnchor.constraint(equalToConstant: 16),
            scrubberPlayheadKnob.heightAnchor.constraint(equalToConstant: 16),

            scrubberTouchArea.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberTouchArea.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            scrubberTouchArea.widthAnchor.constraint(equalToConstant: 44),

            clipRegionBackground.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            clipRegionBackground.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            leftDimView.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            leftDimView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            leftDimView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            leftDimView.trailingAnchor.constraint(equalTo: leftTrimHandle.leadingAnchor),

            rightDimView.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            rightDimView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rightDimView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            rightDimView.leadingAnchor.constraint(equalTo: rightTrimHandle.trailingAnchor),

            topBorder.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor),
            topBorder.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 3),

            bottomBorder.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 3),

            leftTrimHandle.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            leftTrimHandle.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            leftTrimHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            rightTrimHandle.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rightTrimHandle.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            rightTrimHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            clipPlayhead.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            clipPlayhead.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            clipPlayheadKnob.centerXAnchor.constraint(equalTo: clipPlayhead.centerXAnchor),
            clipPlayheadKnob.topAnchor.constraint(equalTo: clipPlayhead.topAnchor, constant: -6),
            clipPlayheadKnob.widthAnchor.constraint(equalToConstant: 16),
            clipPlayheadKnob.heightAnchor.constraint(equalToConstant: 16),

            playheadTouchArea.centerXAnchor.constraint(equalTo: clipPlayhead.centerXAnchor),
            playheadTouchArea.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            playheadTouchArea.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            playheadTouchArea.widthAnchor.constraint(equalToConstant: 44),

            bufferLimitLabel.topAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: 3),
            bufferLimitLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bufferLimitLabel.heightAnchor.constraint(equalToConstant: 24)
        ])

        // Mutable constraints
        leftHandleConstraint = leftTrimHandle.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor)
        rightHandleConstraint = rightTrimHandle.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor)
        playheadConstraint = clipPlayhead.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor)
        playheadWidthConstraint = clipPlayhead.widthAnchor.constraint(equalToConstant: 3)
        clipBackgroundLeadingConstraint = clipRegionBackground.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor)
        clipBackgroundTrailingConstraint = clipRegionBackground.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor)
        scrubberPlayheadConstraint = scrubberPlayhead.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor)
        scrubberTouchAreaConstraint = scrubberTouchArea.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor, constant: -22)

        [
            leftHandleConstraint,
            rightHandleConstraint,
            playheadConstraint,
            playheadWidthConstraint,
            clipBackgroundLeadingConstraint,
            clipBackgroundTrailingConstraint,
            scrubberPlayheadConstraint,
            scrubberTouchAreaConstraint
        ].forEach { $0?.isActive = true }

        // Initial UI state
        refreshBucketIcons()
        updateSplitButtonState()
    }

    // MARK: - Tap & controls visibility
    @objc private func handleTap() {
        if controlsContainer.alpha == 0 {
            showControls()
        } else {
            hideControls()
        }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 1
            self.topRightButtonContainer.alpha = 1
            self.topLeftButtonContainer.alpha = 1
            if !self.bufferLimitLabel.isHidden { self.bufferLimitLabel.alpha = 1 }
        }
    }

    private func hideControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 0
            self.topRightButtonContainer.alpha = 0
            self.topLeftButtonContainer.alpha = 0
            self.bufferLimitLabel.alpha = 0
        }
    }

    // MARK: - Button actions
    @objc private func playPauseTapped() {
        if isLooping { stopLoop() } else { startLoop() }
    }

    @objc private func clipSaveButtonTapped() {
        if isClipMode {
            saveClipToPhotos()
        } else {
            if isLooping { stopLoop() }
            enterClipMode()
        }
    }

    @objc private func restartTapped() {
        cleanupTempSplitClips()
        onRestartRequested?()
    }

    @objc private func stopSessionTapped() {
        cleanupTempSplitClips()
        onStopSessionRequested?()
    }

    @objc private func cancelClipTapped() {
        exitClipMode()
    }

    @objc private func bucket1Tapped() {
        handleBucketTap(bucket: 1)
    }

    @objc private func bucket2Tapped() {
        handleBucketTap(bucket: 2)
    }

    @objc private func splitScreenTapped() {
        guard tempClipBucket1URL != nil || tempClipBucket2URL != nil else { return }
        if isLooping { stopLoop() }

        // Stay in clip mode, keep handles and playhead where they are.
        onSplitScreenRequested?(tempClipBucket1URL, tempClipBucket2URL)
    }

    // MARK: - Bucket logic
    private func handleBucketTap(bucket: Int) {
        guard isClipMode else { return }
        if isLooping { stopLoop() }

        switch bucket {
        case 1:
            if let url = tempClipBucket1URL {
                print("ðŸ—‘ Clearing bucket 1 temp clip at \(url.path)")
                try? FileManager.default.removeItem(at: url)
                tempClipBucket1URL = nil
                refreshBucketIcons()
                updateSplitButtonState()
                return
            }
            // creating a new one:
            exportCurrentSelectionToTemp { [weak self] url in
                guard let self, let url else { return }
                print("âœ… Bucket 1 assigned temp clip at \(url.path)")
                self.tempClipBucket1URL = url
                self.refreshBucketIcons()
                self.updateSplitButtonState()
            }

        case 2:
            if let url = tempClipBucket2URL {
                print("ðŸ—‘ Clearing bucket 2 temp clip at \(url.path)")
                try? FileManager.default.removeItem(at: url)
                tempClipBucket2URL = nil
                refreshBucketIcons()
                updateSplitButtonState()
                return
            }
            exportCurrentSelectionToTemp { [weak self] url in
                guard let self, let url else { return }
                print("âœ… Bucket 2 assigned temp clip at \(url.path)")
                self.tempClipBucket2URL = url
                self.refreshBucketIcons()
                self.updateSplitButtonState()
            }

        default:
            return
        }
    }

    private func exportCurrentSelectionToTemp(completion: @escaping (URL?) -> Void) {
        guard let buf = videoFileBuffer else { completion(nil); return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)

        let overlay = createLoadingView(text: "Creating clip...")
        addSubview(overlay)
        overlay.frame = bounds

        SplitTempClipExportManager.exportTempClip(
            from: buf,
            startIndex: clipStartIndex,
            endIndex: clipEndIndex,
            isFrontCamera: isFrontCamera,
            rotationAngle: recordedRotationAngle,
            fps: fps
        ) { [weak self] result in
            guard let self else { return }
            overlay.removeFromSuperview()

            switch result {
            case .success(let url):
                completion(url)
            case .failure(let err):
                self.showError(err.localizedDescription)
                completion(nil)
            }
        }
    }

    private func refreshBucketIcons() {
        setBucketIcon(button: bucket1Button, number: 1, filled: tempClipBucket1URL != nil)
        setBucketIcon(button: bucket2Button, number: 2, filled: tempClipBucket2URL != nil)
        updateSplitButtonState()
    }

    private func setBucketIcon(button: UIButton, number: Int, filled: Bool) {
        // Change .bold to .light or .thin here!
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        let base = "\(number).square"
        let name = filled ? "\(base).fill" : base
        button.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
        button.tintColor = filled ? .systemYellow : .white
    }

    private func updateSplitButtonState() {
        let enabled = (tempClipBucket1URL != nil || tempClipBucket2URL != nil)
        splitScreenButton.isEnabled = enabled
        splitScreenButton.tintColor = enabled ? .white : .systemGray3
    }

    private func updateSplitIconForCurrentOrientation() {
        let ori = window?.windowScene?.interfaceOrientation
        let isLandscape: Bool
        if let ori {
            isLandscape = ori.isLandscape
        } else {
            isLandscape = bounds.width > bounds.height
        }

        let name = isLandscape ? "square.split.2x1" : "square.split.1x2"
        // Change weight from .bold to .light here!
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        splitScreenButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
    }

    /// Call this from the controller when SplitVideoView closes, per your cleanup rules.
    func cleanupTempSplitClips() {
        if let url = tempClipBucket1URL {
            print("ðŸ—‘ Deleting temp clip 1 at \(url.path)")
            try? FileManager.default.removeItem(at: url)
        }
        if let url = tempClipBucket2URL {
            print("ðŸ—‘ Deleting temp clip 2 at \(url.path)")
            try? FileManager.default.removeItem(at: url)
        }
        tempClipBucket1URL = nil
        tempClipBucket2URL = nil
        refreshBucketIcons()
    }

    // MARK: - AVPlayer setup / teardown
    private func setupPlayer(with item: AVPlayerItem, composition: AVMutableComposition) {
        tearDownPlayer()

        // Trim to bufferâ€™s displayable end time
        if let buf = videoFileBuffer {
            let endTime = buf.pausedCompositionEndTime
            if CMTimeGetSeconds(endTime) > 0 {
                item.forwardPlaybackEndTime = endTime
            }
        }

        // Rotate/mirror the video natively
        if let videoTrack = composition.tracks(withMediaType: .video).first {
            let natural = videoTrack.naturalSize
            let transform = VideoPlaybackHelpers.exportTransformForRotationAngle(
                recordedRotationAngle,
                naturalSize: natural,
                isFrontCamera: isFrontCamera
            )

            let vc = AVMutableVideoComposition()
            let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))

            // Swap width/height for portrait angles
            let isPortrait = Int(recordedRotationAngle) == 90 || Int(recordedRotationAngle) == 270
            vc.renderSize = isPortrait ? CGSize(width: natural.height, height: natural.width) : natural

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: .zero)

            instruction.layerInstructions = [layerInstruction]
            vc.instructions = [instruction]
            item.videoComposition = vc
        }

        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        self.player = p

        let pl = AVPlayerLayer(player: p)
        pl.videoGravity = .resizeAspectFill
        zoomContainer.layer.insertSublayer(pl, at: 0)
        self.playerLayer = pl
        // Set frame immediately in case layoutSubviews hasn't run yet
        pl.frame = zoomContainer.bounds.isEmpty ? bounds : zoomContainer.bounds

        applyPlayerTransformNow()

        // Periodic observer keeps scrubber in sync during playback.
        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let buf = self.videoFileBuffer else { return }
            self.playerDidAdvance(to: time, duration: buf.pausedCompositionEndTime)
        }

        // Loop observer.
        playerLoopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isLooping else { return }
            self.loopBackToStart()
        }
    }

    private func tearDownPlayer() {
        if let obs = playerTimeObserver {
            player?.removeTimeObserver(obs)
            playerTimeObserver = nil
        }

        if let obs = playerLoopObserver {
            NotificationCenter.default.removeObserver(obs)
            playerLoopObserver = nil
        }

        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        isSeeking = false
        pendingScrubIndex = nil
    }

    // MARK: - Loop playback
    private func startLoop() {
        guard let buf = videoFileBuffer, let comp = buf.pausedComposition else { return }

        isLooping = true
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "pause.circle.fill", withConfiguration: cfg), for: .normal)

        if player == nil {
            let item = AVPlayerItem(asset: comp)
            setupPlayer(with: item, composition: comp)
        }

        let idx = isClipMode ? clipPlayheadPosition : scrubberPosition
        seekPlayer(toFrameIndex: idx) { [weak self] in
            self?.player?.play()
        }
    }

    private func stopLoop() {
        isLooping = false
        player?.pause()

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)

        let idx = isClipMode ? clipPlayheadPosition : scrubberPosition
        seekPlayer(toFrameIndex: idx, completion: nil)
    }

    private func loopBackToStart() {
        guard let buf = videoFileBuffer else { return }

        let loopStart: CMTime
        if isClipMode {
            loopStart = buf.compositionTime(forFrameIndex: clipStartIndex) ?? .zero
        } else {
            loopStart = buf.pausedCompositionDisplayStartTime
        }

        player?.seek(to: loopStart, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, finished, self.isLooping else { return }

            if let item = self.player?.currentItem {
                item.forwardPlaybackEndTime = self.isClipMode
                ? (buf.compositionTime(forFrameIndex: self.clipEndIndex) ?? buf.pausedCompositionEndTime)
                : buf.pausedCompositionEndTime
            }

            self.player?.play()
        }
    }

    // MARK: - Player time -> UI mapping
    private func playerDidAdvance(to time: CMTime, duration: CMTime) {
        guard isLooping, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let scrubRange = max(1, pausePoint - oldest)

        if isClipMode {
            let clipRange = max(1, clipEndIndex - clipStartIndex)
            let endSecs = CMTimeGetSeconds(buf.compositionTime(forFrameIndex: clipEndIndex) ?? duration)
            let startSecs = CMTimeGetSeconds(buf.compositionTime(forFrameIndex: clipStartIndex) ?? .zero)
            let rangeSecs = max(0.001, endSecs - startSecs)

            let fraction = (CMTimeGetSeconds(time) - startSecs) / rangeSecs
            clipPlayheadPosition = clipStartIndex + min(Int(fraction * Double(clipRange)), clipRange)

            let fps2 = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
            let tot2 = buf.getCurrentFrameCount()
            let req2 = delaySeconds * fps2
            let pp2  = max(0, tot2 - req2)
            let old2 = oldestAllowedIndex(totalFrames: tot2, pausePoint: pp2, fps: fps2)
            frameDial.currentFrame = max(0, clipPlayheadPosition - old2)

            updatePlayheadPosition()
            updateTimeLabel()
        } else {
            let displayStart = CMTimeGetSeconds(buf.pausedCompositionDisplayStartTime)
            let displayEnd = CMTimeGetSeconds(buf.pausedCompositionEndTime)
            let displayRange = max(0.001, displayEnd - displayStart)

            let fraction = (CMTimeGetSeconds(time) - displayStart) / displayRange
            let clamped = max(0.0, min(fraction, 1.0))

            scrubberPosition = oldest + Int(clamped * Double(scrubRange))
            scrubberPosition = min(scrubberPosition, pausePoint)

            frameDial.currentFrame = max(0, scrubberPosition - oldest)

            updateScrubberPlayheadPosition()
            updateTimeLabel()
        }
    }

    // MARK: - Seek helper
    private func seekPlayer(toFrameIndex index: Int, completion: (() -> Void)? = nil) {
        guard let buf = videoFileBuffer,
              let compositionTime = buf.compositionTime(forFrameIndex: index) else {
            completion?()
            return
        }

        if isSeeking {
            pendingScrubIndex = index
            return
        }

        isSeeking = true
        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let half = CMTime(value: 1, timescale: CMTimeScale(max(fps * 2, 1)))

        player?.seek(to: compositionTime, toleranceBefore: half, toleranceAfter: half) { [weak self] _ in
            guard let self else { return }
            self.isSeeking = false

            if let next = self.pendingScrubIndex {
                self.pendingScrubIndex = nil
                self.seekPlayer(toFrameIndex: next, completion: completion)
                return
            }

            completion?()
        }
    }

    // MARK: - Scrubber pan (non-clip mode)
    @objc private func handleScrubberPan(_ gesture: UIPanGestureRecognizer) {
        guard !isClipMode, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)

        guard pausePoint > oldest else { return }

        let range = pausePoint - oldest
        let width = timelineContainer.bounds.width
        guard width > 0 else { return }

        let loc = gesture.location(in: timelineContainer)
        let currentHandleCenterX = (scrubberTouchAreaConstraint?.constant ?? 0) + 22.0

        switch gesture.state {
        case .began:
            if isLooping { stopLoop() }
            scrubberGrabOffsetX = currentHandleCenterX - loc.x

        case .changed, .ended, .cancelled:
            var desiredCenterX = loc.x + scrubberGrabOffsetX
            desiredCenterX = max(0, min(desiredCenterX, width))

            let frac = desiredCenterX / width
            scrubberPosition = oldest + Int(frac * CGFloat(range))
            scrubberPosition = max(oldest, min(scrubberPosition, pausePoint))

            updateScrubberPlayheadPosition()
            updateTimeLabel()
            seekPlayer(toFrameIndex: scrubberPosition, completion: nil)

        default:
            break
        }
    }

    private func updateScrubberPlayheadPosition() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        let width = timelineContainer.bounds.width
        guard width > 0 else { return }

        let frac = CGFloat(scrubberPosition - oldest) / CGFloat(range)
        let x = frac * width

        scrubberPlayheadConstraint?.constant = x
        scrubberTouchAreaConstraint?.constant = x - 22
        layoutIfNeeded()
        
        // ✅ Keep dial in sync so rightward drag is never falsely blocked
        frameDial.currentFrame = max(0, scrubberPosition - oldest)
    }

    // MARK: - Oldest allowed index helper
    private func oldestAllowedIndex(totalFrames: Int, pausePoint: Int, fps: Int) -> Int {
        guard let buf = videoFileBuffer else { return 0 }

        let actualFPS = max(fps, 1)

        let maxScrubFrames = max(scrubDurationSeconds * actualFPS, 1)
        let mathOldest = max(0, pausePoint - maxScrubFrames)

        let startSeconds = CMTimeGetSeconds(buf.pausedCompositionDisplayStartTime)
        let prunedOldest = Int(startSeconds * Double(actualFPS))

        return max(mathOldest, prunedOldest)
    }

    // MARK: - Clip mode
    private func enterClipMode() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        guard totalFrames > requiredFrames else { return }

        let pausePoint = totalFrames - requiredFrames
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        guard pausePoint > oldest else { return }

        isClipMode = true
        clipStartIndex = oldest
        clipEndIndex = pausePoint
        clipPlayheadPosition = scrubberPosition

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        clipSaveButton.setImage(UIImage(systemName: "arrow.down.to.line.circle.fill", withConfiguration: cfg), for: .normal)
        clipSaveButton.tintColor = .white

        cancelClipButton.isHidden = false
        bucketDivider.isHidden = false
        bucket1Button.isHidden = false
        bucket2Button.isHidden = false
        splitScreenButton.isHidden = false

        refreshBucketIcons()
        updateSplitIconForCurrentOrientation()

        // Reorder z-index: keep gesture areas from smothering handles.
        timelineContainer.bringSubviewToFront(playheadTouchArea)
        timelineContainer.bringSubviewToFront(clipPlayhead)
        timelineContainer.bringSubviewToFront(leftTrimHandle)
        timelineContainer.bringSubviewToFront(rightTrimHandle)

        UIView.animate(withDuration: 0.3) {
            self.scrubberBackground.alpha = 0
            self.scrubberPlayhead.alpha = 0

            self.clipRegionBackground.isHidden = false
            self.leftDimView.isHidden = false
            self.rightDimView.isHidden = false
            self.leftTrimHandle.isHidden = false
            self.rightTrimHandle.isHidden = false
            self.topBorder.isHidden = false
            self.bottomBorder.isHidden = false
            self.clipPlayhead.isHidden = false
        }

        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()

        // Re-apply zoom transform after layout settles so the video stays in place
        DispatchQueue.main.async {
            self.updateTransform()
        }
    }

    private func exitClipMode() {
        scrubberPosition = clipPlayheadPosition
        exitClipModeClean(shouldDeleteTempClips: true) // ensure true here
        seekPlayer(toFrameIndex: scrubberPosition, completion: nil)
        updateScrubberPlayheadPosition()
        updateTimeLabel()
    }

    // MARK: - Split restore helper
    func restoreClipModeAfterSplit() {
        guard let buf = videoFileBuffer else { return }

        // Recompute valid bounds
        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)

        // Clamp existing indices to safe range (we keep previous clipStartIndex/endIndex/playhead)
        clipStartIndex = max(oldest, min(clipStartIndex, pausePoint))
        clipEndIndex = max(clipStartIndex + 1, min(clipEndIndex, pausePoint))
        clipPlayheadPosition = min(max(clipPlayheadPosition, clipStartIndex), clipEndIndex)

        // Reâ€‘enter clip mode UI with same selection, buckets untouched
        isClipMode = true

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        clipSaveButton.setImage(UIImage(systemName: "arrow.down.to.line.circle.fill", withConfiguration: cfg), for: .normal)
        clipSaveButton.tintColor = .white

        cancelClipButton.isHidden = false
        bucketDivider.isHidden = false
        bucket1Button.isHidden = false
        bucket2Button.isHidden = false
        splitScreenButton.isHidden = false

        refreshBucketIcons()
        updateSplitIconForCurrentOrientation()

        UIView.animate(withDuration: 0.3) {
            self.scrubberBackground.alpha = 0
            self.scrubberPlayhead.alpha = 0

            self.clipRegionBackground.isHidden = false
            self.leftDimView.isHidden = false
            self.rightDimView.isHidden = false
            self.leftTrimHandle.isHidden = false
            self.rightTrimHandle.isHidden = false
            self.topBorder.isHidden = false
            self.bottomBorder.isHidden = false
            self.clipPlayhead.isHidden = false
        }

        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()

        DispatchQueue.main.async {
            self.updateTransform()
        }
    }

    func resetUIAndTearDown() {
        if isLooping { stopLoop() }
        if isClipMode { exitClipModeClean(shouldDeleteTempClips: true) }

        // Also ensure no lingering temps if we somehow werenâ€™t in clip mode:
        cleanupTempSplitClips()

        tearDownPlayer()
        bufferLimitLabel.isHidden = true
        bufferLimitLabel.alpha = 0
        hideControls()
    }

    private func exitClipModeClean(shouldDeleteTempClips: Bool) {
        isClipMode = false

        cancelClipButton.isHidden = true
        bucketDivider.isHidden = true
        bucket1Button.isHidden = true
        bucket2Button.isHidden = true
        splitScreenButton.isHidden = true

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        clipSaveButton.setImage(UIImage(systemName: "film.circle.fill", withConfiguration: cfg), for: .normal)
        clipSaveButton.tintColor = .white

        if shouldDeleteTempClips {
            cleanupTempSplitClips()
        } else {
            refreshBucketIcons()
        }

        UIView.animate(withDuration: 0.3) {
            self.scrubberBackground.alpha = 1
            self.scrubberPlayhead.alpha = 1

            self.clipRegionBackground.isHidden = true
            self.leftDimView.isHidden = true
            self.rightDimView.isHidden = true
            self.leftTrimHandle.isHidden = true
            self.rightTrimHandle.isHidden = true
            self.topBorder.isHidden = true
            self.bottomBorder.isHidden = true
            self.clipPlayhead.isHidden = true
        }
    }

    private func updateClipHandlePositions() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        let safeWidth = timelineContainer.bounds.width - (handleWidth * 2)
        guard safeWidth > 0 else { return }

        let leftFrac = CGFloat(clipStartIndex - oldest) / CGFloat(range)
        let rightFrac = CGFloat(clipEndIndex - oldest) / CGFloat(range)

        let leftX = leftFrac * safeWidth
        let rightX = (1.0 - rightFrac) * safeWidth

        leftHandleConstraint?.constant = leftX
        rightHandleConstraint?.constant = -rightX

        clipBackgroundLeadingConstraint?.constant = 0
        clipBackgroundTrailingConstraint?.constant = 0

        layoutIfNeeded()
    }

    private func updatePlayheadPosition() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        let playheadWidth: CGFloat = 3
        let safeWidth = timelineContainer.bounds.width - (handleWidth * 2) - playheadWidth
        guard safeWidth > 0 else { return }

        let frac = CGFloat(clipPlayheadPosition - oldest) / CGFloat(range)
        let playheadX = (frac * safeWidth) + handleWidth

        playheadConstraint?.constant = playheadX
        playheadWidthConstraint?.constant = playheadWidth

        layoutIfNeeded()
        
        // ✅ Keep dial in sync
        frameDial.currentFrame = max(0, clipPlayheadPosition - oldest)
    }

    private func updateTimeLabel() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)

        let idx = isClipMode ? clipPlayheadPosition : scrubberPosition
        let clamped = min(max(idx, oldest), pausePoint)
        let secs = Float(clamped - oldest) / Float(max(fps, 1))
        timeLabel.text = VideoPlaybackHelpers.formatTime(secs)
    }

    // MARK: - Trim handle gestures
    @objc private func handleLeftTrimPan(_ gesture: UIPanGestureRecognizer) {
        guard isClipMode, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        let safeWidth = timelineContainer.bounds.width - (handleWidth * 2)
        guard safeWidth > 0 else { return }

        let tr = gesture.translation(in: timelineContainer)

        switch gesture.state {
        case .began:
            if isLooping { stopLoop() }
            isDraggingHandle = true
            initialLeftPosition = leftHandleConstraint?.constant ?? 0
            initialClipStartIndex = clipStartIndex
            clipPlayhead.alpha = 0
            playheadTouchArea.alpha = 0

        case .changed:
            let newLeft = initialLeftPosition + tr.x
            let norm = max(0, min(newLeft / safeWidth, 1))
            let newStart = oldest + Int(norm * CGFloat(range))

            clipStartIndex = max(oldest, min(newStart, clipEndIndex - max(fps, 1)))
            clipPlayheadPosition = clipStartIndex

            updateClipHandlePositions()
            updatePlayheadPosition()
            updateTimeLabel()

            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)
            }

        case .ended, .cancelled:
            isDraggingHandle = false
            seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)
            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha = 1
                self.playheadTouchArea.alpha = 1
            }

        default:
            break
        }
    }

    @objc private func handleRightTrimPan(_ gesture: UIPanGestureRecognizer) {
        guard isClipMode, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        let safeWidth = timelineContainer.bounds.width - (handleWidth * 2)
        guard safeWidth > 0 else { return }

        let tr = gesture.translation(in: timelineContainer)

        switch gesture.state {
        case .began:
            if isLooping { stopLoop() }
            isDraggingHandle = true
            initialRightPosition = rightHandleConstraint?.constant ?? 0
            initialClipEndIndex = clipEndIndex
            clipPlayhead.alpha = 0
            playheadTouchArea.alpha = 0

        case .changed:
            let w = timelineContainer.bounds.width
            let currentFromLeft = w + initialRightPosition + tr.x
            let norm = max(0, min((currentFromLeft - (handleWidth * 2)) / safeWidth, 1))
            let newEnd = oldest + Int(norm * CGFloat(range))

            clipEndIndex = max(clipStartIndex + max(fps, 1), min(newEnd, pausePoint))
            clipPlayheadPosition = clipEndIndex

            updateClipHandlePositions()
            updatePlayheadPosition()
            updateTimeLabel()

            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)
            }

        case .ended, .cancelled:
            isDraggingHandle = false
            seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)

            if let item = player?.currentItem {
                item.forwardPlaybackEndTime = buf.compositionTime(forFrameIndex: clipEndIndex) ?? buf.pausedCompositionEndTime
            }

            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha = 1
                self.playheadTouchArea.alpha = 1
            }

        default:
            break
        }
    }

    @objc private func handlePlayheadPan(_ gesture: UIPanGestureRecognizer) {
        guard isClipMode, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        switch gesture.state {
        case .began:
            isDraggingHandle = true
            initialPlayheadPosition = playheadConstraint?.constant ?? 0
            initialClipPlayheadPosition = clipPlayheadPosition

        case .changed:
            let dx = gesture.translation(in: timelineContainer).x
            let newX = max(0, min(initialPlayheadPosition + dx, timelineContainer.bounds.width))
            playheadConstraint?.constant = newX

            let frac = newX / max(timelineContainer.bounds.width, 1)
            let newIndex = oldest + Int(frac * CGFloat(range))
            clipPlayheadPosition = min(max(newIndex, clipStartIndex), clipEndIndex)

            updatePlayheadPosition()
            updateTimeLabel()
            seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)

        default:
            isDraggingHandle = false
        }
    }

    @objc private func handleTimelineTap(_ gesture: UITapGestureRecognizer) {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getCurrentFrameCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        guard pausePoint > oldest else { return }

        let loc = gesture.location(in: timelineContainer)
        let x = max(0, min(loc.x, timelineContainer.bounds.width))
        let frac = x / max(timelineContainer.bounds.width, 1)

        let range = pausePoint - oldest
        let idx = oldest + Int(frac * CGFloat(range))

        if isClipMode {
            clipPlayheadPosition = min(max(idx, clipStartIndex), clipEndIndex)
            updatePlayheadPosition()
        } else {
            scrubberPosition = min(max(idx, oldest), pausePoint)
            updateScrubberPlayheadPosition()
        }

        updateTimeLabel()
        seekPlayer(toFrameIndex: isClipMode ? clipPlayheadPosition : scrubberPosition, completion: nil)
    }

    // MARK: - Save clip to Photos
    private func saveClipToPhotos() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let frames = clipEndIndex - clipStartIndex
        let secs = frames / max(fps, 1)

        let executeExport = { [weak self] in
            guard let self else { return }

            let overlay = self.createLoadingView(text: "Saving to Photos")
            self.addSubview(overlay)
            overlay.frame = self.bounds

            let angle = self.recordedRotationAngle
            VideoExportManager.exportAndSaveClip(
                from: buf,
                startIndex: self.clipStartIndex,
                endIndex: self.clipEndIndex,
                isFrontCamera: self.isFrontCamera,
                rotationAngle: angle,
                fps: fps
            ) { result in
                overlay.removeFromSuperview()

                switch result {
                case .success():
                    self.showSuccessFeedback()
                case .failure(let error):
                    if case .permissionDenied = error {
                        self.showPhotosPermissionAlert()
                    } else {
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }

        // Show warning for long clips, otherwise just export immediately
        if secs > 60 {
            let alert = UIAlertController(
                title: "Long Clip",
                message: "This clip is \(secs / 60):\(String(format: "%02d", secs % 60)) long. Saving may take a moment.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in executeExport() })
            parentViewController?.present(alert, animated: true)
        } else {
            executeExport()
        }
    }

    private func showPhotosPermissionAlert() {
        let alert = UIAlertController(
            title: "Photos Permission",
            message: "Enable Photos access to save clips.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        parentViewController?.present(alert, animated: true)
    }

    private func showSuccessFeedback() {
        successFeedbackView.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 2.0) {
            self.successFeedbackView.alpha = 0
        }
    }

    // MARK: - Loading view / error helpers
    private func createLoadingView(text: String) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        v.addSubview(spinner)
        v.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor)
        ])

        return v
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        parentViewController?.present(alert, animated: true)
    }

    // MARK: - Zoom gestures
    private func setupZoomGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @objc private func resetZoom() {
        currentScale = 1.0
        currentOffset = .zero
        lastScale = 1.0
        lastOffset = .zero
        UIView.animate(withDuration: 0.3) {
            self.zoomContainer.transform = .identity
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastScale = currentScale

        case .changed:
            // Allow shrinking below 1.0 for the "bounce" feel — no max(1.0) clamp here
            currentScale = max(0.5, lastScale * gesture.scale)
            updateTransform()

        case .ended, .cancelled, .failed:
            if currentScale < 1.0 {
                // Snap back to full size with a spring animation
                currentScale = 1.0
                currentOffset = .zero
                lastScale = 1.0
                lastOffset = .zero
                UIView.animate(withDuration: 0.35,
                               delay: 0,
                               usingSpringWithDamping: 0.7,
                               initialSpringVelocity: 0.5,
                               options: .curveEaseOut) {
                    self.zoomContainer.transform = .identity
                }
            }

        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { lastOffset = currentOffset }
        let translation = gesture.translation(in: self)
        currentOffset = CGPoint(x: lastOffset.x + translation.x,
                                y: lastOffset.y + translation.y)
        updateTransform()
    }

    private func updateTransform() {
        let scaleT = CGAffineTransform(scaleX: currentScale, y: currentScale)
        let translateT = CGAffineTransform(translationX: currentOffset.x, y: currentOffset.y)
        zoomContainer.transform = scaleT.concatenating(translateT)
    }

    // MARK: - UIGestureRecognizerDelegate
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                            shouldReceive touch: UITouch) -> Bool {
        // Only apply this exclusion to the zoom-pan gesture.
        // The scrubber/clip pan gestures are on subviews and handle themselves.
        guard gestureRecognizer.view === self else { return true }

        // Exclude any touch that lands on the bottom controls container
        // (scrubber, timeline, clip handles, frame dial, play button, time label)
        // or the top UI containers.
        let excludedViews: [UIView] = [
            controlsContainer,
            topLeftButtonContainer,
            topRightButtonContainer
        ]

        for view in excludedViews {
            if touch.view?.isDescendant(of: view) == true {
                return false
            }
        }
        return true
    }

    // MARK: - Parent VC helper
    private var parentViewController: UIViewController? {
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc }
            r = next
        }
        return nil
    }
}

// MARK: - Temp split clip exporter (mp4 in /tmp)
enum SplitTempClipExportError: LocalizedError {
    case missingComposition
    case exporterCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingComposition:
            return "Video buffer or composition is missing."
        case .exporterCreationFailed:
            return "Could not create an export session."
        case .exportFailed(let msg):
            return "Export failed: \(msg)"
        }
    }
}
