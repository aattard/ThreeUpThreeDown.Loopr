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

    // MARK: - Pan gesture tracking

    private var initialLeftPosition: CGFloat = 0
    private var initialRightPosition: CGFloat = 0
    private var initialPlayheadPosition: CGFloat = 0

    private var initialClipStartIndex: Int = 0
    private var initialClipEndIndex: Int = 0
    private var initialClipPlayheadPosition: Int = 0

    private var isDraggingHandle: Bool = false
    private var lastUpdateTime: TimeInterval = 0

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

    private let clipSaveButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "film.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let cancelClipButton: UIButton = {
        let b = UIButton(type: .system)
        b.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        b.layer.cornerRadius = 18
        b.clipsToBounds = true
        b.setTitle("Cancel", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()

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

        addSubview(successFeedbackView)
        addSubview(cancelClipButton)

        setupControls()

        NSLayoutConstraint.activate([
            successFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            successFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            successFeedbackView.widthAnchor.constraint(equalToConstant: 200),
            successFeedbackView.heightAnchor.constraint(equalToConstant: 200),

            cancelClipButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            cancelClipButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        tearDownPlayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
        applyPlayerTransformNow()
        
        // Force the timeline to figure out its new width FIRST,
        // so bounds.width is accurate for the playhead math below.
        timelineContainer.layoutIfNeeded()

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
        self.videoFileBuffer = buffer
        self.delaySeconds = delaySeconds
        self.isFrontCamera = isFrontCamera
        self.recordedRotationAngle = recordedRotationAngle

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
            
            // Generate the string, then capitalize the first letter of each word
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
    }

    func resetUIAndTearDown() {
        if isLooping { stopLoop() }
        if isClipMode { exitClipModeClean() }

        tearDownPlayer()

        bufferLimitLabel.isHidden = true
        bufferLimitLabel.alpha = 0

        hideControls()
    }

    func applyPlayerTransformNow() {
        guard let pl = playerLayer else { return }
        
        // Remove manual layer rotation entirely
        pl.setAffineTransform(.identity)
        pl.frame = bounds
        
        // Let the player handle gravity dynamically based on app orientation
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
        addSubview(bufferLimitLabel)

        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(timelineContainer)
        controlsContainer.addSubview(timeLabel)
        controlsContainer.addSubview(clipSaveButton)

        topRightButtonContainer.addSubview(restartButton)
        topRightButtonContainer.addSubview(stopSessionButton)

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

        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped), for: .touchUpInside)
        restartButton.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        clipSaveButton.addTarget(self, action: #selector(clipSaveButtonTapped), for: .touchUpInside)
        cancelClipButton.addTarget(self, action: #selector(cancelClipTapped), for: .touchUpInside)

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

        NSLayoutConstraint.activate([
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

            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controlsContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            controlsContainer.heightAnchor.constraint(equalToConstant: 80),

            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 20),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            clipSaveButton.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -20),
            clipSaveButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            clipSaveButton.widthAnchor.constraint(equalToConstant: 44),
            clipSaveButton.heightAnchor.constraint(equalToConstant: 44),

            timeLabel.trailingAnchor.constraint(equalTo: clipSaveButton.leadingAnchor, constant: -5),
            timeLabel.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 58),

            timelineContainer.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            timelineContainer.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            timelineContainer.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timelineContainer.heightAnchor.constraint(equalToConstant: 44),

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
            bufferLimitLabel.heightAnchor.constraint(equalToConstant: 24),
        ])

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
            if !self.bufferLimitLabel.isHidden { self.bufferLimitLabel.alpha = 1 }
        }
    }

    private func hideControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 0
            self.topRightButtonContainer.alpha = 0
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
        onRestartRequested?()
    }

    @objc private func stopSessionTapped() {
        onStopSessionRequested?()
    }

    @objc private func cancelClipTapped() {
        exitClipMode()
    }

    // MARK: - AVPlayer setup / teardown

    private func setupPlayer(with item: AVPlayerItem, composition: AVMutableComposition) {
        tearDownPlayer()

        // Trim to buffer’s displayable end time
        if let buf = videoFileBuffer {
            let endTime = buf.pausedCompositionEndTime
            if CMTimeGetSeconds(endTime) > 0 {
                item.forwardPlaybackEndTime = endTime
            }
        }

        // ✅ NEW: Tell the AVPlayerItem to rotate/mirror the video natively
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
        layer.insertSublayer(pl, at: 0)
        self.playerLayer = pl

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
        playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: cfg), for: .normal)

        if player == nil {
            let item = AVPlayerItem(asset: comp)
            setupPlayer(with: item, composition: comp)
        }

        // Seek to current playhead position.
        let idx = isClipMode ? clipPlayheadPosition : scrubberPosition
        seekPlayer(toFrameIndex: idx) { [weak self] in
            guard let self else { return }
            self.player?.play()
        }
    }

    private func stopLoop() {
        isLooping = false
        player?.pause()

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)

        // Snap still frame at the current position and hide player layer.
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
        let totalFrames = buf.getTimestampCount()
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

            updatePlayheadPosition()
            updateTimeLabel()
        } else {
            // Ratio mapping across display range.
            let displayStart = CMTimeGetSeconds(buf.pausedCompositionDisplayStartTime)
            let displayEnd = CMTimeGetSeconds(buf.pausedCompositionEndTime)
            let displayRange = max(0.001, displayEnd - displayStart)

            let fraction = (CMTimeGetSeconds(time) - displayStart) / displayRange
            let clamped = max(0.0, min(fraction, 1.0))

            scrubberPosition = oldest + Int(clamped * Double(scrubRange))
            scrubberPosition = min(scrubberPosition, pausePoint)

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
        let totalFrames = buf.getTimestampCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        guard pausePoint > oldest else { return }

        let range = pausePoint - oldest
        let width = timelineContainer.bounds.width
        guard width > 0 else { return }

        let loc = gesture.location(in: timelineContainer)

        // We use the scrubberTouchArea's center as the canonical "handle position"
        // so the user can grab it even when it's at the edges.
        let currentHandleCenterX = (scrubberTouchAreaConstraint?.constant ?? 0) + 22.0

        switch gesture.state {
        case .began:
            if isLooping { stopLoop() }
            // Remember where inside the handle the user grabbed so it doesn't jump.
            scrubberGrabOffsetX = currentHandleCenterX - loc.x

        case .changed, .ended, .cancelled:
            // Apply offset and clamp to [0, width]
            var desiredCenterX = loc.x + scrubberGrabOffsetX
            desiredCenterX = max(0, min(desiredCenterX, width))

            let frac = desiredCenterX / width
            scrubberPosition = oldest + Int(frac * CGFloat(range))
            scrubberPosition = max(oldest, min(scrubberPosition, pausePoint))

            updateScrubberPlayheadPosition()
            updateTimeLabel()

            // Keep player in sync for playback.
            seekPlayer(toFrameIndex: scrubberPosition, completion: nil)

        default:
            break
        }
    }

    private func updateScrubberPlayheadPosition() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getTimestampCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        let width = timelineContainer.bounds.width
        guard width > 0 else { return }

        let frac = CGFloat(scrubberPosition - oldest) / CGFloat(range)
        let x = frac * width

        scrubberPlayheadConstraint?.constant = x

        // Center the 44pt touch area on x.
        // Do NOT clamp this to [0, width - 44]; let it hang off the ends so it's easy to grab.
        scrubberTouchAreaConstraint?.constant = x - 22

        layoutIfNeeded()
    }

    // MARK: - Oldest allowed index helper

    private func oldestAllowedIndex(totalFrames: Int, pausePoint: Int, fps: Int) -> Int {
        let maxScrubFrames = max(scrubDurationSeconds * fps, 1)
        return max(0, pausePoint - maxScrubFrames)
    }

    // MARK: - Clip mode

    private func enterClipMode() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getTimestampCount()
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

        // Reorder z-index: the playhead area goes down first, so its massive
        // 44pt invisible touch zone doesn't smother the handles at the edges.
        timelineContainer.bringSubviewToFront(playheadTouchArea)
        timelineContainer.bringSubviewToFront(clipPlayhead)
        
        // Trim handles go on top. They are only 20pts wide, so they must
        // win any gesture collisions at the immediate edges.
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
            self.cancelClipButton.isHidden = false
        }

        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()
    }

    private func exitClipMode() {
        scrubberPosition = clipPlayheadPosition
        exitClipModeClean()
        seekPlayer(toFrameIndex: scrubberPosition, completion: nil)
        updateScrubberPlayheadPosition()
        updateTimeLabel()
    }

    private func exitClipModeClean() {
        isClipMode = false
        cancelClipButton.isHidden = true

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        clipSaveButton.setImage(UIImage(systemName: "film.circle.fill", withConfiguration: cfg), for: .normal)
        clipSaveButton.tintColor = .white

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
        let totalFrames = buf.getTimestampCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        // The safe area for the video timeline is the width MINUS both grabbers
        let safeWidth = timelineContainer.bounds.width - (handleWidth * 2)
        guard safeWidth > 0 else { return }

        let leftFrac = CGFloat(clipStartIndex - oldest) / CGFloat(range)
        let rightFrac = CGFloat(clipEndIndex - oldest) / CGFloat(range)

        // Left handle constraint moves from 0 to safeWidth
        let leftX = leftFrac * safeWidth
        
        // Right handle constraint is trailing (negative), so it moves from 0 to -safeWidth
        // If rightFrac is 1.0 (end of video), trailing is 0 (flush right).
        // If rightFrac is 0.0 (start of video), trailing is -safeWidth.
        let rightX = (1.0 - rightFrac) * safeWidth

        leftHandleConstraint?.constant = leftX
        rightHandleConstraint?.constant = -rightX

        // Ensure the purple background stretches exactly between the handles
        clipBackgroundLeadingConstraint?.constant = 0
        clipBackgroundTrailingConstraint?.constant = 0

        layoutIfNeeded()
    }

    private func updatePlayheadPosition() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getTimestampCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest = oldestAllowedIndex(totalFrames: totalFrames, pausePoint: pausePoint, fps: fps)
        let range = max(1, pausePoint - oldest)

        // The playhead travels exclusively between the inner edges of the grabbers.
        // We subtract `3` (the playhead width) so the body of the playhead doesn't
        // spill underneath the right grabber when it hits 100%.
        let playheadWidth: CGFloat = 3
        let safeWidth = timelineContainer.bounds.width - (handleWidth * 2) - playheadWidth
        guard safeWidth > 0 else { return }

        let frac = CGFloat(clipPlayheadPosition - oldest) / CGFloat(range)
        
        // Offset by `handleWidth` so 0% starts exactly at the right edge of the left handle.
        let playheadX = (frac * safeWidth) + handleWidth
        
        playheadConstraint?.constant = playheadX
        playheadWidthConstraint?.constant = playheadWidth

        layoutIfNeeded()
    }

    private func updateTimeLabel() {
        guard let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getTimestampCount()
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
        let totalFrames = buf.getTimestampCount()
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

            // Keep it at least 1 second behind the right handle, and cap at oldest
            clipStartIndex = max(oldest, min(newStart, clipEndIndex - max(fps, 1)))
            clipPlayheadPosition = clipStartIndex

            updateClipHandlePositions()
            updatePlayheadPosition()
            updateTimeLabel()

            // Throttle player seeking
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
            
        default: break
        }
    }

    @objc private func handleRightTrimPan(_ gesture: UIPanGestureRecognizer) {
        guard isClipMode, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getTimestampCount()
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
            // Calculate where the handle is from the LEFT side to get the proper fraction
            // We calculate how far the handle's right edge is from the left container edge,
            // subtract the handle sizes, and divide by safeWidth.
            let w = timelineContainer.bounds.width
            let currentFromLeft = w + initialRightPosition + tr.x
            // Shift back by the space taken by both handles to find the normalized fraction
            let norm = max(0, min((currentFromLeft - (handleWidth * 2)) / safeWidth, 1))
            let newEnd = oldest + Int(norm * CGFloat(range))

            // Keep it at least 1 second ahead of the left handle, and cap it at the pause point
            clipEndIndex = max(clipStartIndex + max(fps, 1), min(newEnd, pausePoint))
            clipPlayheadPosition = clipEndIndex

            updateClipHandlePositions()
            updatePlayheadPosition()
            updateTimeLabel()

            // Throttle the player seeking so it doesn't freeze while dragging
            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)
            }
            
        case .ended, .cancelled:
            isDraggingHandle = false
            seekPlayer(toFrameIndex: clipPlayheadPosition, completion: nil)

            // Update player end time to match the new clip end so it loops cleanly
            if let item = player?.currentItem {
                item.forwardPlaybackEndTime = buf.compositionTime(forFrameIndex: clipEndIndex) ?? buf.pausedCompositionEndTime
            }

            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha = 1
                self.playheadTouchArea.alpha = 1
            }
            
        default: break
        }
    }

    @objc private func handlePlayheadPan(_ gesture: UIPanGestureRecognizer) {
        guard isClipMode, let buf = videoFileBuffer else { return }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames = buf.getTimestampCount()
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
        let totalFrames = buf.getTimestampCount()
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
            guard let self = self else { return }
            let overlay = self.createLoadingView(text: "Saving…")
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

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Allow the scrubber pan to work alongside the tap gesture,
        // but only when we aren't in clip mode (to prevent dragging conflicts).
        return !isClipMode
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
