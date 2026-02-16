import UIKit
import AVFoundation
import Photos

class DelayedCameraView: UIView {

    private var captureSession: AVCaptureSession!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var isFrontCamera: Bool = false
    private var currentDevice: AVCaptureDevice?

    // NEW: Callback for when session stops
    var onSessionStopped: (() -> Void)?

    // NEW: Replace frameBuffer with VideoFileBuffer
    private var videoFileBuffer: VideoFileBuffer?
    private var frameMetadata: [(timestamp: CMTime, index: Int)] = []
    private let metadataLock = NSLock()

    private var delaySeconds: Int = 7
    private var isActive: Bool = false
    private var isShowingDelayed: Bool = false
    private var isPaused: Bool = false

    private var displayTimer: Timer?
    private var displayImageView: UIImageView!

    // Scrubbing properties
    private var scrubberPosition: Int = 0
    private var lastUpdateTime: TimeInterval = 0

    // NEW: Loop playback properties
    private var isLooping: Bool = false
    private var loopTimer: Timer?
    private var loopFrameIndex: Int = 0

    // Clip selection properties
    private var clipStartIndex: Int = 0
    private var clipEndIndex: Int = 0
    private var isClipMode: Bool = false
    private var clipPlayheadPosition: Int = 0  // Current position within clip

    // Pan gesture tracking
    private var initialLeftPosition: CGFloat = 0
    private var initialRightPosition: CGFloat = 0
    private var initialPlayheadPosition: CGFloat = 0
    private var initialClipStartIndex: Int = 0
    private var initialClipEndIndex: Int = 0
    private var initialClipPlayheadPosition: Int = 0

    // Current display state
    private var currentDisplayFrameIndex: Int = 0

    // Track if handle is being dragged
    private var isDraggingHandle: Bool = false

    private let countdownLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 120, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.layer.cornerRadius = 20
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // Stop button during countdown (matches home screen style)
    private let countdownStopButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        let image = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = .black
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.black.cgColor
        button.layer.cornerRadius = 60  // Matches 120×120 size
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let recordingIndicator: UIView = {
        let container = UIView()
        container.backgroundColor = UIColor.systemRed
        container.layer.cornerRadius = 18  // Half of height for pill shape
        container.translatesAutoresizingMaskIntoConstraints = false
        container.alpha = 0

        // Blinking dot
        let dot = UIView()
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.tag = 999  // For accessing later for blink animation

        // "LIVE" label
        let liveLabel = UILabel()
        liveLabel.text = "LIVE"
        liveLabel.textColor = .white
        liveLabel.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        liveLabel.tag = 998  // For accessing later

        // Delay label (shows "-7s")
        let delayLabel = UILabel()
        delayLabel.text = "-7s"
        delayLabel.textColor = .white.withAlphaComponent(0.9)
        delayLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        delayLabel.translatesAutoresizingMaskIntoConstraints = false
        delayLabel.tag = 997  // For updating with actual delay

        container.addSubview(dot)
        container.addSubview(liveLabel)
        container.addSubview(delayLabel)

        NSLayoutConstraint.activate([
            // Dot on the left
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            // "LIVE" label next to dot
            liveLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            liveLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            // Delay label after "LIVE"
            delayLabel.leadingAnchor.constraint(equalTo: liveLabel.trailingAnchor, constant: 3),
            delayLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            delayLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }()

    // NEW: Live pause button - SAME SIZE as countdown stop button (120x120)
    private let livePauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        let image = UIImage(systemName: "pause.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 60  // Matches 120×120 size
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0
        return button
    }()

    // Success feedback view (like countdown)
    private let successFeedbackView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.layer.cornerRadius = 20
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0

        let config = UIImage.SymbolConfiguration(pointSize: 120, weight: .bold)
        let imageView = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: config))
        imageView.tintColor = .white
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 150),
            imageView.heightAnchor.constraint(equalToConstant: 150)
        ])

        return view
    }()

    // YouTube-style controls
    private let controlsContainer: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        view.layer.cornerRadius = 40
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        return view
    }()

    private let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "play.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Integrated clip/scrub timeline
    private let timelineContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = false  // ADD THIS - allow touch area to extend beyond visible bounds
        return view
    }()

    // NEW: Scrubber background (purple bar like clip mode)
    private let scrubberBackground: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        view.layer.cornerRadius = 6
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // NEW: Scrubber playhead (white line)
    private let scrubberPlayhead: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    // NEW: Scrubber playhead knob (white circle at top)
    private let scrubberPlayheadKnob: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.layer.cornerRadius = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    // NEW: Scrubber touch area (44px wide for easy dragging)
    private let scrubberTouchArea: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = true
        return view
    }()

    private let leftDimView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 0.5)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        
        // Round ONLY left corners
        view.layer.cornerRadius = 6
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        
        return view
    }()

    private let rightDimView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 0.5)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        
        // Round ONLY right corners
        view.layer.cornerRadius = 6
        view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        
        return view
    }()

    // NEW: Clip region background (purple)
    private let clipRegionBackground: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        view.layer.cornerRadius = 6
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private let leftTrimHandle: UIView = {
        let view = UIView()
        view.backgroundColor = .systemYellow
        //view.backgroundColor = UIColor(red:0.000, green:0.451, blue:0.731, alpha:1.000)
        view.layer.cornerRadius = 3
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.isUserInteractionEnabled = true

        let chevron = UIImageView(image: UIImage(systemName: "chevron.compact.left"))
        chevron.tintColor = .black
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chevron)

        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 20)
        ])

        return view
    }()

    private let rightTrimHandle: UIView = {
        let view = UIView()
        view.backgroundColor = .systemYellow
        //view.backgroundColor = UIColor(red:0.000, green:0.451, blue:0.731, alpha:1.000)
        view.layer.cornerRadius = 3
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.isUserInteractionEnabled = true

        let chevron = UIImageView(image: UIImage(systemName: "chevron.compact.right"))
        chevron.tintColor = .black
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chevron)

        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 20)
        ])

        return view
    }()

    private let topBorder: UIView = {
        let view = UIView()
        view.backgroundColor = .systemYellow
        //view.backgroundColor = UIColor(red:0.000, green:0.451, blue:0.731, alpha:1.000)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private let bottomBorder: UIView = {
        let view = UIView()
        view.backgroundColor = .systemYellow
        //view.backgroundColor = UIColor(red:0.000, green:0.451, blue:0.731, alpha:1.000)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    // Clip playhead for scrubbing within the selected region
    private let clipPlayhead: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }()

    private let clipPlayheadKnob: UIView = {
        let view = UIView()
        view.backgroundColor = .white
        view.layer.cornerRadius = 8
        view.layer.borderWidth = 2
        view.layer.borderColor = UIColor.systemYellow.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    // Invisible touch area for easier dragging
    private let playheadTouchArea: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = true
        return view
    }()

    private var leftHandleConstraint: NSLayoutConstraint?
    private var rightHandleConstraint: NSLayoutConstraint?
    private var playheadConstraint: NSLayoutConstraint?
    private var playheadWidthConstraint: NSLayoutConstraint?
    private var clipBackgroundLeadingConstraint: NSLayoutConstraint?
    private var clipBackgroundTrailingConstraint: NSLayoutConstraint?
    private var scrubberPlayheadConstraint: NSLayoutConstraint?
    private var scrubberTouchAreaConstraint: NSLayoutConstraint?

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.text = "LIVE"
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // Clip/Save button (transforms between edit icon and save icon)
    private let clipSaveButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "film.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    // NEW: Top-right button container (pill-shaped)
    private let topRightButtonContainer: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        view.layer.cornerRadius = 32 // Half of height for pill shape
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        return view
    }()

    private let stopSessionButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .systemRed
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // NEW: Restart button (restarts countdown)
    private let restartButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: config)
        button.setImage(image, for: .normal)
        button.tintColor = .systemGreen
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Cancel button (in clip mode, top left)
    private let cancelClipButton: UIButton = {
        let button = UIButton(type: .system)
        
        // Pill background (like live recording indicator)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        button.layer.cornerRadius = 18  // Half of height for pill shape
        button.clipsToBounds = true
        
        // Text styling
        button.setTitle("Cancel", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        
        // Padding around text
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private var hideControlsTimer: Timer?

    private lazy var captureQueue: DispatchQueue = {
        return DispatchQueue(label: "com.loopr.capture", qos: .userInteractive, attributes: [])
    }()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Constants for handle width
    private let handleWidth: CGFloat = 20
    
    // Always scrub 60 seconds
    private let scrubDurationSeconds: Int = 60

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        displayImageView = UIImageView(frame: bounds)
        displayImageView.contentMode = .scaleAspectFill
        displayImageView.clipsToBounds = true
        displayImageView.backgroundColor = .clear
        displayImageView.alpha = 0
        displayImageView.isUserInteractionEnabled = false
        addSubview(displayImageView)

        addSubview(countdownLabel)
        addSubview(countdownStopButton)
        addSubview(livePauseButton)
        addSubview(successFeedbackView)
        addSubview(cancelClipButton)
        setupControls()

        NSLayoutConstraint.activate([
            countdownLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countdownLabel.widthAnchor.constraint(equalToConstant: 200),
            countdownLabel.heightAnchor.constraint(equalToConstant: 200),

            // Stop button during countdown - bottom center
            countdownStopButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownStopButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -40),
            countdownStopButton.widthAnchor.constraint(equalToConstant: 120),
            countdownStopButton.heightAnchor.constraint(equalToConstant: 120),

            // Live pause button - SAME SIZE AND POSITION as countdown stop button
            livePauseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            livePauseButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -40),
            livePauseButton.widthAnchor.constraint(equalToConstant: 120),
            livePauseButton.heightAnchor.constraint(equalToConstant: 120),

            // Success feedback - center
            successFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            successFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            successFeedbackView.widthAnchor.constraint(equalToConstant: 200),
            successFeedbackView.heightAnchor.constraint(equalToConstant: 200),

            // Cancel button (top left in clip mode)
            cancelClipButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            cancelClipButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10)
        ])

        countdownStopButton.addTarget(self, action: #selector(countdownStopTapped), for: .touchUpInside)
        livePauseButton.addTarget(self, action: #selector(livePauseTapped), for: .touchUpInside)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)

        print("🎬 DelayedCameraView initialized")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hideControlsTimer?.invalidate()
        loopTimer?.invalidate()
        videoFileBuffer?.cleanup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayImageView.frame = bounds
        previewLayer?.frame = bounds
        layer.layoutIfNeeded()

        // Update clip handles after layout if in clip mode
        if isClipMode {
            updateClipHandlePositions()
            updatePlayheadPosition()
        } else if isPaused {
            updateScrubberPlayheadPosition()
        }
    }

    private func setupControls() {
        addSubview(controlsContainer)
        addSubview(recordingIndicator)
        
        // NEW: Add top-right button container to main view
        addSubview(topRightButtonContainer)
        
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(timelineContainer)
        controlsContainer.addSubview(timeLabel)
        controlsContainer.addSubview(clipSaveButton)
        
        // MOVED: Add restart and stop buttons to top-right container instead
        topRightButtonContainer.addSubview(restartButton)
        topRightButtonContainer.addSubview(stopSessionButton)
        
        // Add scrubber background and playhead FIRST
        timelineContainer.addSubview(scrubberBackground)
        timelineContainer.addSubview(scrubberPlayhead)
        scrubberPlayhead.addSubview(scrubberPlayheadKnob)
        timelineContainer.addSubview(scrubberTouchArea)
        
        // Add clip background
        timelineContainer.addSubview(clipRegionBackground)
        
        // Add trim UI to timeline container
        timelineContainer.addSubview(leftDimView)
        timelineContainer.addSubview(rightDimView)
        timelineContainer.addSubview(topBorder)
        timelineContainer.addSubview(bottomBorder)
        timelineContainer.addSubview(playheadTouchArea)
        timelineContainer.addSubview(leftTrimHandle)
        timelineContainer.addSubview(rightTrimHandle)
        
        // Add playhead, knob, and touch area
        timelineContainer.addSubview(clipPlayhead)
        clipPlayhead.addSubview(clipPlayheadKnob)
        
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped), for: .touchUpInside)
        clipSaveButton.addTarget(self, action: #selector(clipSaveButtonTapped), for: .touchUpInside)
        restartButton.addTarget(self, action: #selector(restartButtonTapped), for: .touchUpInside)
        cancelClipButton.addTarget(self, action: #selector(cancelClipTapped), for: .touchUpInside)
        
        // Add pan gestures to trim handles
        let leftPan = UIPanGestureRecognizer(target: self, action: #selector(handleLeftTrimPan(_:)))
        leftTrimHandle.addGestureRecognizer(leftPan)
        
        let rightPan = UIPanGestureRecognizer(target: self, action: #selector(handleRightTrimPan(_:)))
        rightTrimHandle.addGestureRecognizer(rightPan)
        
        // Add pan gesture to playhead touch area
        let playheadPan = UIPanGestureRecognizer(target: self, action: #selector(handlePlayheadPan(_:)))
        playheadTouchArea.addGestureRecognizer(playheadPan)
        
        let scrubberPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubberPan(_:)))
        scrubberPan.delegate = self
        timelineContainer.addGestureRecognizer(scrubberPan)
        
        // Add tap gesture to timeline for jumping playhead
        let timelineTap = UITapGestureRecognizer(target: self, action: #selector(handleTimelineTap(_:)))
        timelineTap.cancelsTouchesInView = false
        timelineContainer.addGestureRecognizer(timelineTap)
        
        NSLayoutConstraint.activate([
            // Recording indicator - top center
            recordingIndicator.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            recordingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            recordingIndicator.heightAnchor.constraint(equalToConstant: 36),
            recordingIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            
            // NEW: Top-right button container
            topRightButtonContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            topRightButtonContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            topRightButtonContainer.heightAnchor.constraint(equalToConstant: 64),
            topRightButtonContainer.widthAnchor.constraint(equalToConstant: 108), // 44 + 10 spacing + 44 + 10 padding each side
            
            // Restart button (inside top-right container)
            restartButton.leadingAnchor.constraint(equalTo: topRightButtonContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: topRightButtonContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: 44),
            restartButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Stop button (inside top-right container)
            stopSessionButton.trailingAnchor.constraint(equalTo: topRightButtonContainer.trailingAnchor, constant: -10),
            stopSessionButton.centerYAnchor.constraint(equalTo: topRightButtonContainer.centerYAnchor),
            stopSessionButton.widthAnchor.constraint(equalToConstant: 44),
            stopSessionButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Container - floated up from bottom with side padding
            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            controlsContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            controlsContainer.heightAnchor.constraint(equalToConstant: 80),
            
            // Play/Pause button
            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 20),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Clip/Save button
            clipSaveButton.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -20),
            clipSaveButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            clipSaveButton.widthAnchor.constraint(equalToConstant: 44),
            clipSaveButton.heightAnchor.constraint(equalToConstant: 44),
            
            // Time label
            timeLabel.trailingAnchor.constraint(equalTo: clipSaveButton.leadingAnchor, constant: -5),
            timeLabel.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 50),
            
            // Timeline container (now extends further since restart/stop buttons are removed)
            timelineContainer.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 20),
            timelineContainer.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -20),
            timelineContainer.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timelineContainer.heightAnchor.constraint(equalToConstant: 44),

            // Scrubber background (purple bar)
            scrubberBackground.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            scrubberBackground.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            scrubberBackground.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberBackground.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            // Scrubber playhead line (3px wide white line)
            scrubberPlayhead.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberPlayhead.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            scrubberPlayhead.widthAnchor.constraint(equalToConstant: 3),

            // Scrubber playhead knob (white circle at top)
            scrubberPlayheadKnob.centerXAnchor.constraint(equalTo: scrubberPlayhead.centerXAnchor),
            scrubberPlayheadKnob.topAnchor.constraint(equalTo: scrubberPlayhead.topAnchor, constant: -6),
            scrubberPlayheadKnob.widthAnchor.constraint(equalToConstant: 16),
            scrubberPlayheadKnob.heightAnchor.constraint(equalToConstant: 16),

            // Scrubber touch area (44px wide for easy dragging)
            scrubberTouchArea.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberTouchArea.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            scrubberTouchArea.widthAnchor.constraint(equalToConstant: 44),

            // Clip region background (purple)
            clipRegionBackground.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            clipRegionBackground.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            // Dim views
            leftDimView.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            leftDimView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            leftDimView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            leftDimView.trailingAnchor.constraint(equalTo: leftTrimHandle.leadingAnchor),

            rightDimView.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            rightDimView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rightDimView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            rightDimView.leadingAnchor.constraint(equalTo: rightTrimHandle.trailingAnchor),

            // Borders
            topBorder.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor),
            topBorder.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 3),

            bottomBorder.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 3),

            // Trim handles
            leftTrimHandle.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            leftTrimHandle.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            leftTrimHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            rightTrimHandle.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rightTrimHandle.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            rightTrimHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            // Playhead line
            clipPlayhead.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            clipPlayhead.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            // Playhead knob
            clipPlayheadKnob.centerXAnchor.constraint(equalTo: clipPlayhead.centerXAnchor),
            clipPlayheadKnob.topAnchor.constraint(equalTo: clipPlayhead.topAnchor, constant: -6),
            clipPlayheadKnob.widthAnchor.constraint(equalToConstant: 16),
            clipPlayheadKnob.heightAnchor.constraint(equalToConstant: 16),

            // Touch area for easier dragging
            playheadTouchArea.centerXAnchor.constraint(equalTo: clipPlayhead.centerXAnchor),
            playheadTouchArea.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            playheadTouchArea.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            playheadTouchArea.widthAnchor.constraint(equalToConstant: 44)
        ])

        // Store handle constraints for dynamic positioning
        leftHandleConstraint = leftTrimHandle.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor, constant: 0)
        rightHandleConstraint = rightTrimHandle.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor, constant: 0)
        playheadConstraint = clipPlayhead.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor, constant: 0)
        playheadWidthConstraint = clipPlayhead.widthAnchor.constraint(equalToConstant: 3)

        clipBackgroundLeadingConstraint = clipRegionBackground.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor)
        clipBackgroundTrailingConstraint = clipRegionBackground.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor)

        leftHandleConstraint?.isActive = true
        rightHandleConstraint?.isActive = true
        playheadConstraint?.isActive = true
        playheadWidthConstraint?.isActive = true
        clipBackgroundLeadingConstraint?.isActive = true
        clipBackgroundTrailingConstraint?.isActive = true

        scrubberPlayheadConstraint = scrubberPlayhead.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor, constant: 0)
        scrubberPlayheadConstraint?.isActive = true
        // NEW: Add constraint for touch area centered on playhead
        scrubberTouchAreaConstraint = scrubberTouchArea.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor, constant: -22)
        scrubberTouchAreaConstraint?.isActive = true
    }

    @objc private func handleTap() {
        guard isShowingDelayed else { return }

        // LIVE mode: Show/hide pause button
        if !isPaused {
            if livePauseButton.alpha == 0 {
                showLivePauseButton()
            } else {
                hideLivePauseButton()
            }
        }
    }

    private func showLivePauseButton() {
        UIView.animate(withDuration: 0.3) {
            self.livePauseButton.alpha = 1
        }

        resetHideControlsTimer()
    }

    private func hideLivePauseButton() {
        UIView.animate(withDuration: 0.3) {
            self.livePauseButton.alpha = 0
        }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 1
            self.topRightButtonContainer.alpha = 1  // ADD THIS LINE
        }
    }

    private func hideControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha = 0
            self.topRightButtonContainer.alpha = 0  // ADD THIS LINE
        }
    }

    private func resetHideControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.isPaused {
                self.hideLivePauseButton()
            }
        }
    }

    private func startRecordingIndicator() {
        UIView.animate(withDuration: 0.3) {
            self.recordingIndicator.alpha = 1
        }

        if let dot = recordingIndicator.viewWithTag(999) {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.0
            blink.duration = 0.8
            blink.repeatCount = .infinity
            blink.autoreverses = true
            dot.layer.add(blink, forKey: "blinking")
        }
    }

    private func stopRecordingIndicator() {
        if let dot = recordingIndicator.viewWithTag(999) {
            dot.layer.removeAnimation(forKey: "blinking")
        }

        UIView.animate(withDuration: 0.3) {
            self.recordingIndicator.alpha = 0
        }
    }

    private func showSuccessFeedback() {
        successFeedbackView.alpha = 1

        UIView.animate(withDuration: 0.3, delay: 2.0, options: [], animations: {
            self.successFeedbackView.alpha = 0
        })
    }

    @objc private func livePauseTapped() {
        print("⏸️ Live pause tapped")
        pausePlayback()
    }

    @objc private func playPauseTapped() {
        if isLooping {
            stopLoop()
        } else {
            startLoop()
        }
    }

    @objc private func stopSessionTapped() {
        print("🛑 Stop button tapped from controls")
        stopSession()
    }

    @objc private func countdownStopTapped() {
        print("🛑 Stop button tapped during countdown")
        stopSession()
    }

    @objc private func restartButtonTapped() {
        print("🔄 Restart button tapped - restarting countdown")
        restartCountdown()
    }

    @objc private func clipSaveButtonTapped() {
        if isClipMode {
            // In clip mode: Save button
            print("💾 Save to Album tapped")
            saveClipToPhotos()
        } else {
            // In normal mode: Clip button
            print("✏️ Edit/Clip button tapped")
            guard isPaused else { return }
            if isLooping {
                stopLoop()
            }
            enterClipMode()
        }
    }

    private func saveClipToPhotos() {
        print("📸 Saving clip to Photos...")

        let loadingView = createLoadingView(text: "Saving to Album...")
        addSubview(loadingView)

        createClipVideo { [weak self] url in
            guard let self = self else { return }

            guard let url = url else {
                DispatchQueue.main.async {
                    loadingView.removeFromSuperview()
                    self.showError("Failed to create video clip")
                }
                return
            }

            // Save to Photos
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else {
                    DispatchQueue.main.async {
                        loadingView.removeFromSuperview()
                        self.showError("Photos access denied. Enable in Settings.")
                    }
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    DispatchQueue.main.async {
                        loadingView.removeFromSuperview()

                        if success {
                            print("✅ Clip saved to Photos")
                            self.showSuccessFeedback()
                            self.exitClipMode()
                        } else {
                            print("❌ Failed to save: \(error?.localizedDescription ?? "unknown")")
                            self.showError("Failed to save to Album")
                        }
                    }
                }
            }
        }
    }

    private func restartCountdown() {
        if isLooping {
            stopLoop()
        }

        if isClipMode {
            exitClipMode()
        }

        hideControls()
        isPaused = false
        isShowingDelayed = false

        metadataLock.lock()
        frameMetadata.removeAll()
        metadataLock.unlock()

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let maxDuration = 60 + delaySeconds + 10  // 60s scrub + delay + 10s buffer
        
        videoFileBuffer = VideoFileBuffer(
            maxDurationSeconds: maxDuration,
            delaySeconds: delaySeconds,
            fps: actualFPS,
            writeQueue: captureQueue
        )
        videoDataOutput?.setSampleBufferDelegate(self, queue: captureQueue)

        // Always use 1080p at 30fps for best quality
        let videoWidth = 1920
        let videoHeight = 1080
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoWidth * videoHeight * 11,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: actualFPS,
                AVVideoMaxKeyFrameIntervalKey: actualFPS
            ]
        ]
        try? videoFileBuffer?.startWriting(videoSettings: videoSettings, isInitialStart: true)

        UIView.animate(withDuration: 0.3) {
            self.previewLayer?.opacity = 1
            self.displayImageView.alpha = 0
        }

        startCountdown()
    }


    @objc private func handleScrubberPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            print("🎯 Scrubber pan BEGAN at location: \(gesture.location(in: timelineContainer))")
            if isLooping {
                stopLoop()
            }
        }
        
        let location = gesture.location(in: timelineContainer)
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else {
            print("⚠️ Not enough frames: \(totalFrames) < \(requiredFrames)")
            return
        }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size for scrub range
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        let scrubRange = pausePointIndex - oldestAllowedIndex
        
        let timelineWidth = timelineContainer.bounds.width
        guard scrubRange > 0, timelineWidth > 0 else {
            print("⚠️ Invalid range or width: scrubRange=\(scrubRange), width=\(timelineWidth)")
            return
        }
        
        let clampedX = max(0, min(location.x, timelineWidth))
        let normalizedPosition = clampedX / timelineWidth
        let frameIndex = oldestAllowedIndex + Int(normalizedPosition * CGFloat(scrubRange))
        
        let beforeClamp = frameIndex
        scrubberPosition = max(oldestAllowedIndex, min(frameIndex, pausePointIndex))
        
        let beforeMinClamp = scrubberPosition
        scrubberPosition = max(1, scrubberPosition)
        
        if gesture.state == .began || gesture.state == .ended {
            print("📍 Scrubber position update:")
            print("   location.x: \(location.x), clampedX: \(clampedX)")
            print("   timelineWidth: \(timelineWidth)")
            print("   normalizedPosition: \(normalizedPosition)")
            print("   oldestAllowed: \(oldestAllowedIndex), pausePoint: \(pausePointIndex)")
            //print("   scrubRange: \(scrubRange), cacheSize: \(cacheFrameCount)")
            print("   frameIndex (before clamp): \(beforeClamp)")
            print("   after range clamp: \(beforeMinClamp)")
            print("   FINAL scrubberPosition: \(scrubberPosition)")
        }
        
        loopFrameIndex = scrubberPosition
        updateScrubberPlayheadPosition()
        
        let secondsFromStart = Float(scrubberPosition - oldestAllowedIndex) / Float(actualFPS)
        DispatchQueue.main.async {
            self.timeLabel.text = String(format: "%05.2f", secondsFromStart)
        }
        
        // FIX: Use cache for instant display during scrubbing (no async delay)
        if let cachedImage = videoFileBuffer?.getRecentFrame(at: scrubberPosition) {
            displayFrame(cachedImage)
        } else {
            // Fallback to file extraction only if not in cache
            // But don't throttle on .began or .ended
            if gesture.state == .began || gesture.state == .ended {
                videoFileBuffer?.extractFrameFromFile(at: scrubberPosition) { [weak self] image in
                    guard let self = self, let image = image else { return }
                    // Only display if we're still at this position
                    if self.scrubberPosition == scrubberPosition {
                        self.displayFrame(image)
                    }
                }
            } else {
                // During .changed, throttle file extraction
                let currentTime = CACurrentMediaTime()
                if currentTime - lastUpdateTime >= 0.05 {
                    lastUpdateTime = currentTime
                    videoFileBuffer?.extractFrameFromFile(at: scrubberPosition) { [weak self] image in
                        guard let self = self, let image = image else { return }
                        // Only display if we're still at this position
                        if self.scrubberPosition == scrubberPosition {
                            self.displayFrame(image)
                        }
                    }
                }
            }
        }
    }

    private func updateScrubberPlayheadPosition() {
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size, not hardcoded
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        let scrubRange = pausePointIndex - oldestAllowedIndex
        
        guard scrubRange > 0 else { return }
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        // Clamp scrubberPosition to valid range
        let clampedPosition = max(oldestAllowedIndex, min(scrubberPosition, pausePointIndex))
        
        let normalizedPosition = CGFloat(clampedPosition - oldestAllowedIndex) / CGFloat(scrubRange)
        let playheadX = normalizedPosition * timelineWidth
        
        scrubberPlayheadConstraint?.constant = playheadX
        
        // Update touch area constraint to center it on the playhead
        let idealTouchAreaX = playheadX - 22  // Center 44px touch area on playhead
        let clampedTouchAreaX = max(0, min(idealTouchAreaX, timelineWidth - 44))
        scrubberTouchAreaConstraint?.constant = clampedTouchAreaX
        
        timelineContainer.layoutIfNeeded()
        
        //validatePlayheadSync()
    }

    private func startLoop() {
        print("▶️ Starting loop playback")
        isLooping = true

        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "pause.fill", withConfiguration: config)
        playPauseButton.setImage(image, for: .normal)

        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }

        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size instead of hardcoded 30*30
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        let startFrame: Int
        let endFrame: Int

        if isClipMode {
            startFrame = clipStartIndex
            endFrame = clipEndIndex
            loopFrameIndex = clipPlayheadPosition
        } else {
            startFrame = oldestAllowedIndex
            endFrame = pausePointIndex
            loopFrameIndex = max(1, scrubberPosition)
        }

        loopTimer = Timer.scheduledTimer(withTimeInterval: 1.0/Double(actualFPS), repeats: true) { [weak self] _ in
            guard let self = self, self.isLooping else { return }

            self.videoFileBuffer?.extractFrameFromFile(at: self.loopFrameIndex) { [weak self] image in
                guard let self = self, let image = image else { return }
                self.displayFrame(image)
            }

            if self.isClipMode {
                self.clipPlayheadPosition = self.loopFrameIndex
                self.updatePlayheadPosition()
                self.updateTimeLabel()
            } else {
                self.scrubberPosition = self.loopFrameIndex
                self.updateScrubberPlayheadPosition()
                
                let secondsFromStart = Float(self.loopFrameIndex - startFrame) / Float(actualFPS)
                DispatchQueue.main.async {
                    self.timeLabel.text = String(format: "%05.2f", secondsFromStart)
                }
            }

            self.loopFrameIndex += 1

            if self.loopFrameIndex >= endFrame {
                self.loopFrameIndex = startFrame
            }
        }

        RunLoop.main.add(loopTimer!, forMode: .common)
    }

    private func stopLoop() {
        print("⏸️ Stopping loop playback")
        isLooping = false
        loopTimer?.invalidate()
        loopTimer = nil

        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let image = UIImage(systemName: "play.circle.fill", withConfiguration: config)
        playPauseButton.setImage(image, for: .normal)
    }

    @objc private func orientationDidChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.forceOrientationUpdate()
        }
    }

    private func forceOrientationUpdate() {
        guard let connection = previewLayer?.connection else { return }
        let interfaceOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation

        if isFrontCamera {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 0
            case .landscapeRight:
                connection.videoRotationAngle = 180
            case .portrait:
                connection.videoRotationAngle = 90
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
            default:
                connection.videoRotationAngle = 0
            }
        } else {
            switch interfaceOrientation {
            case .landscapeLeft:
                connection.videoRotationAngle = 180
            case .landscapeRight:
                connection.videoRotationAngle = 0
            case .portrait:
                connection.videoRotationAngle = 90
            case .portraitUpsideDown:
                connection.videoRotationAngle = 270
            default:
                connection.videoRotationAngle = 0
            }
        }
    }

    func startSession(delaySeconds: Int, useFrontCamera: Bool) {
        print("🎥 Starting session - delay: \(delaySeconds)s, front: \(useFrontCamera)")
        self.delaySeconds = delaySeconds
        self.isActive = true
        self.isFrontCamera = useFrontCamera
        self.isPaused = false

        metadataLock.lock()
        frameMetadata.removeAll()
        metadataLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupCamera(useFrontCamera: useFrontCamera)
        }
    }

    private func setupCamera(useFrontCamera: Bool) {
        captureSession = AVCaptureSession()

        captureQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()
            // Use .high preset for best quality at 30fps
            self.captureSession.sessionPreset = .high
            print("📹 Using .high preset for 30fps")

            let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                print("❌ No camera found")
                self.captureSession.commitConfiguration()
                return
            }

            self.currentDevice = camera
            
            // Get the FPS setting (always 30fps now)
            let actualTargetFPS = Settings.shared.currentFPS(isFrontCamera: useFrontCamera)
            print("📹 Target FPS from settings: \(actualTargetFPS)")

            do {
                try camera.lockForConfiguration()

                // Try to set the target FPS
                var fpsSet = false
                let targetFrameRate = Double(actualTargetFPS)
                
                for range in camera.activeFormat.videoSupportedFrameRateRanges {
                    if targetFrameRate >= range.minFrameRate && targetFrameRate <= range.maxFrameRate {
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualTargetFPS))
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualTargetFPS))
                        print("✅ Set to \(actualTargetFPS)fps")
                        fpsSet = true
                        break
                    }
                }
                
                if !fpsSet {
                    print("⚠️ \(actualTargetFPS)fps not supported, falling back to 30fps")
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    // Update settings with actual FPS
                    Settings.shared.setFPS(30, isFrontCamera: useFrontCamera)
                    print("📹 Settings updated to 30fps for \(useFrontCamera ? "front" : "back") camera")
                }

                camera.unlockForConfiguration()
                
                // NOW create VideoFileBuffer with the ACTUAL FPS that will be used
                let actualFPS = Settings.shared.currentFPS(isFrontCamera: useFrontCamera)
                let maxDuration = 60 + delaySeconds + 10
                
                videoFileBuffer = VideoFileBuffer(
                    maxDurationSeconds: maxDuration,
                    delaySeconds: delaySeconds,
                    fps: actualFPS,
                    writeQueue: captureQueue
                )
                print("📹 VideoFileBuffer created with \(actualFPS)fps")

                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    print("✅ Input added")
                } else {
                    print("❌ Cannot add input")
                    self.captureSession.commitConfiguration()
                    return
                }

                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                // Keep all frames for smooth delayed playback at 30fps
                output.alwaysDiscardsLateVideoFrames = false
                output.setSampleBufferDelegate(self, queue: self.captureQueue)

                if self.captureSession.canAddOutput(output) {
                    self.captureSession.addOutput(output)
                    print("✅ Output added")
                } else {
                    print("❌ Cannot add output")
                    self.captureSession.commitConfiguration()
                    return
                }

                self.videoDataOutput = output
                self.captureSession.commitConfiguration()

                try camera.lockForConfiguration()
                let savedZoom = Settings.shared.currentZoomFactor(isFrontCamera: useFrontCamera)
                let maxZoom = camera.activeFormat.videoMaxZoomFactor
                let minZoom = camera.minAvailableVideoZoomFactor
                let customMinZoom: CGFloat = 1.0
                let customMaxZoom: CGFloat = 10.0
                let effectiveMin = max(minZoom, customMinZoom)
                let effectiveMax = min(maxZoom, customMaxZoom)
                let clampedZoom = min(max(savedZoom, effectiveMin), effectiveMax)
                camera.videoZoomFactor = clampedZoom
                camera.unlockForConfiguration()
                print("🔍 Applied zoom: \(clampedZoom)x")

                // Always use 1080p at 30fps for best quality
                let videoWidth = 1920
                let videoHeight = 1080
                
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: videoWidth,
                    AVVideoHeightKey: videoHeight,
                    AVVideoCompressionPropertiesKey: [
                        // Optimized bitrate for 1080p@30fps
                        AVVideoAverageBitRateKey: videoWidth * videoHeight * 11,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: actualFPS,
                        AVVideoMaxKeyFrameIntervalKey: actualFPS
                    ]
                ]
                
                print("📹 Video settings: 1080p @ \(actualFPS)fps")
                
                print("📹 Video settings configured for \(actualFPS)fps")

                try self.videoFileBuffer?.startWriting(videoSettings: videoSettings, isInitialStart: true)

                DispatchQueue.main.async {
                    let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.bounds
                    self.layer.insertSublayer(preview, at: 0)
                    self.previewLayer = preview

                    DispatchQueue.main.async {
                        self.forceOrientationUpdate()
                    }

                    self.bringSubviewToFront(self.displayImageView)
                    self.bringSubviewToFront(self.countdownLabel)
                    self.bringSubviewToFront(self.countdownStopButton)
                    self.bringSubviewToFront(self.livePauseButton)
                    self.bringSubviewToFront(self.successFeedbackView)
                    self.bringSubviewToFront(self.cancelClipButton)
                    self.bringSubviewToFront(self.recordingIndicator)
                    self.bringSubviewToFront(self.controlsContainer)
                    self.bringSubviewToFront(self.topRightButtonContainer)
                    print("✅ Preview layer added")

                    self.captureQueue.async {
                        if !self.captureSession.isRunning {
                            self.captureSession.startRunning()
                            print("✅ Camera session RUNNING")
                        }

                        DispatchQueue.main.async {
                            self.startCountdown()
                        }
                    }
                }

            } catch {
                print("❌ Camera setup error: \(error)")
                self.captureSession.commitConfiguration()
            }
        }
    }

    private func startCountdown() {
        var countdown = delaySeconds
        countdownLabel.text = "\(countdown)"
        countdownLabel.alpha = 1
        countdownStopButton.alpha = 1

        print("⏱️ Starting countdown from \(countdown)")

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isActive else {
                timer.invalidate()
                return
            }

            countdown -= 1
            if countdown > 0 {
                self.countdownLabel.text = "\(countdown)"
                print("⏱️ Countdown: \(countdown)")
            } else {
                /*
                timer.invalidate()
                self.countdownLabel.text = "🎬"
                print("⏱️ Countdown complete!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.switchToDelayedView()
                }
                */
                timer.invalidate()
                self.countdownLabel.text = ""
                
                // Add camera icon
                let config = UIImage.SymbolConfiguration(pointSize: 120, weight: .bold)
                let imageView = UIImageView(image: UIImage(systemName: "video.fill", withConfiguration: config))
                imageView.tintColor = .white
                imageView.contentMode = .center
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.tag = 1000 // Tag to remove it later
                
                self.countdownLabel.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.centerXAnchor.constraint(equalTo: self.countdownLabel.centerXAnchor),
                    imageView.centerYAnchor.constraint(equalTo: self.countdownLabel.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 100),
                    imageView.heightAnchor.constraint(equalToConstant: 100)
                ])
                
                print("⏱️ Countdown complete!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Remove the icon before switching
                    if let icon = self.countdownLabel.viewWithTag(1000) {
                        icon.removeFromSuperview()
                    }
                    self.switchToDelayedView()
                }
            }
        }
    }

    private func switchToDelayedView() {
        print("🔄 Switching to delayed view")
        isShowingDelayed = true

        if let delayLabel = recordingIndicator.viewWithTag(997) as? UILabel {
            delayLabel.text = "-\(delaySeconds)s"
        }

        startRecordingIndicator()

        UIView.animate(withDuration: 0.5) {
            self.previewLayer?.opacity = 0
            self.displayImageView.alpha = 1
            self.countdownLabel.alpha = 0
            self.countdownStopButton.alpha = 0
        }

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0/Double(actualFPS), repeats: true) { [weak self] _ in
            self?.updateDisplay()
        }

        RunLoop.main.add(displayTimer!, forMode: .common)
        print("✅ Display timer started at \(actualFPS)fps")
    }

    private func updateDisplay() {
        guard isActive, isShowingDelayed, !isPaused else { return }

        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        
        if totalFrames < requiredFrames {
            if totalFrames % actualFPS == 0 {  // Log every second
                print("⏳ Waiting for buffer: \(totalFrames)/\(requiredFrames) frames (\(Float(totalFrames)/Float(actualFPS))s/\(delaySeconds)s)")
            }
            return
        }
        
        guard requiredFrames > 0 else { return }

        let index = totalFrames - requiredFrames
        guard index >= 0 && index < totalFrames else { return }

        currentDisplayFrameIndex = index

        if let image = videoFileBuffer?.getRecentFrame(at: index) {
            displayFrame(image)
        } else {
            print("⚠️ Failed to get frame \(index) from cache (totalFrames: \(totalFrames))")
        }

        DispatchQueue.main.async {
            self.timeLabel.text = "LIVE"
        }
    }

    private func displayFrame(_ rawImage: UIImage) {
        guard let cgImage = rawImage.cgImage else {
            displayImageView.image = rawImage
            return
        }

        let rotationAngle = previewLayer?.connection?.videoRotationAngle ?? 0

        let displayImage: UIImage
        switch rotationAngle {
        case 0:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        case 90:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        case 180:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .down)
        case 270:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .left)
        default:
            displayImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.displayImageView.image = displayImage
            if self.isFrontCamera {
                self.displayImageView.transform = CGAffineTransform(scaleX: -1, y: 1)
            } else {
                self.displayImageView.transform = .identity
            }
            
            // FIX: Track what frame we're actually displaying
            if self.isClipMode {
                self.currentDisplayFrameIndex = self.clipPlayheadPosition
            } else if self.isPaused {
                self.currentDisplayFrameIndex = self.scrubberPosition
            }
        }
    }
    
    private func validatePlayheadSync() {
        let displayedFrame = currentDisplayFrameIndex
        let expectedFrame = isClipMode ? clipPlayheadPosition : scrubberPosition
        
        if displayedFrame != expectedFrame {
            print("⚠️ FRAME MISMATCH - Displayed: \(displayedFrame), Expected: \(expectedFrame), Mode: \(isClipMode ? "Clip" : "Scrub")")
        }
    }

    func pausePlayback() {
        guard isShowingDelayed, !isPaused else { return }
        
        print("⏸️ Paused - Stopping capture")
        
        isPaused = true
        displayTimer?.invalidate()
        displayTimer = nil
        
        stopRecordingIndicator()
        hideLivePauseButton()
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else {
            print("⚠️ Not enough frames to pause")
            return
        }
        
        let pausePointIndex = totalFrames - requiredFrames
        scrubberPosition = pausePointIndex
        loopFrameIndex = pausePointIndex
        
        // PHASE 1: Use actual cache size for scrub range
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        
        print("📊 Pause Debug:")
        print("   FPS: \(actualFPS)")
        print("   Delay: \(delaySeconds)s = \(requiredFrames) frames")
        print("   Total frames captured: \(totalFrames)")
        print("   Pause point: \(pausePointIndex)")
        print("   Scrub back: 60s = \(scrubBackFrames) frames")
        print("   Desired oldest: \(desiredOldestIndex)")
        print("   Cache size: \(cacheSize) frames (~\(Float(cacheSize)/Float(actualFPS))s)")
        print("   Oldest in cache: \(oldestInCache)")
        print("   Oldest allowed: \(oldestAllowedIndex)")
        print("   Available range: \(oldestAllowedIndex) to \(pausePointIndex)")
        print("   Available frames: \(pausePointIndex - oldestAllowedIndex) (~\(Float(pausePointIndex - oldestAllowedIndex)/Float(actualFPS))s)")
        print("   LIMITED BY: \(oldestAllowedIndex == oldestInCache ? "CACHE SIZE" : "DESIRED RANGE")")
        
        videoFileBuffer?.pauseRecording { [weak self] fileURL in
            guard let self = self else { return }
            
            if fileURL != nil {
                print("✅ File ready for scrubbing")
            } else {
                print("⚠️ Pause completed but file may not be ready")
            }
            
            DispatchQueue.main.async {
                self.showControls()
                self.updateScrubberPlayheadPosition()
                
                let secondsFromStart = Float(self.scrubberPosition - oldestAllowedIndex) / Float(actualFPS)
                self.timeLabel.text = String(format: "%05.2f", secondsFromStart)
            }
        }
        
        self.showControls()
    }

    func stopSession() {
        print("🛑 Stopping session")
        isActive = false
        isShowingDelayed = false
        isPaused = false
        stopRecordingIndicator()
        stopLoop()
        
        displayTimer?.invalidate()
        displayTimer = nil
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession?.isRunning == true {
                self.captureSession?.stopRunning()
                print("✅ Capture session stopped")
            }
            
            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.captureSession = nil
                self.videoDataOutput = nil
                self.previewLayer = nil
                self.controlsContainer.alpha = 0
                self.topRightButtonContainer.alpha = 0  // ADD THIS LINE
                self.countdownStopButton.alpha = 0
                self.livePauseButton.alpha = 0
                self.onSessionStopped?()
            }
            
            self.videoFileBuffer?.stopWriting {
                print("✅ Video file buffer stopped")
            }
        }
        
        metadataLock.lock()
        frameMetadata.removeAll()
        metadataLock.unlock()
        
        displayImageView.image = nil
    }

    // MARK: - Clip Selection Methods
    private func enterClipMode() {
        print("✂️ Entering clip mode")
        isClipMode = true

        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else {
            print("⚠️ Not enough frames to enter clip mode")
            return
        }

        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size instead of hardcoded 30*30
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)

        // FIX: Ensure we have a valid range before entering clip mode
        guard pausePointIndex > oldestAllowedIndex else {
            print("⚠️ Invalid frame range for clip mode: oldest=\(oldestAllowedIndex) pause=\(pausePointIndex)")
            return
        }

        print("✂️ Clip range: \(oldestAllowedIndex) to \(pausePointIndex) (\(scrubBackFrames) frames, ~\(Float(scrubBackFrames)/Float(actualFPS))s)")

        // NEW: Default to FULL RANGE (start to end)
        clipStartIndex = oldestAllowedIndex
        clipEndIndex = pausePointIndex

        // FIX: Set playhead to the current scrubber position instead of start
        clipPlayheadPosition = scrubberPosition
        loopFrameIndex = clipPlayheadPosition

        // Transform button to save icon
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let saveImage = UIImage(systemName: "arrow.down.to.line.circle.fill", withConfiguration: config)
        clipSaveButton.setImage(saveImage, for: .normal)
        clipSaveButton.tintColor = .white

        UIView.animate(withDuration: 0.3) {
            // Hide scrubber completely
            self.scrubberBackground.alpha = 0
            self.scrubberPlayhead.alpha = 0

            // Show purple clip background
            self.clipRegionBackground.isHidden = false

            // Show clip UI
            self.leftDimView.isHidden = false
            self.rightDimView.isHidden = false
            self.topBorder.isHidden = false
            self.bottomBorder.isHidden = false
            self.leftTrimHandle.isHidden = false
            self.rightTrimHandle.isHidden = false
            self.clipPlayhead.isHidden = false
            self.playheadTouchArea.isHidden = false

            // Show cancel button (top left)
            self.cancelClipButton.isHidden = false

            // Recording indicator stays hidden
        }

        timelineContainer.layoutIfNeeded()
        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()

        // FIX: Display the frame at the current playhead position immediately
        displayFrameAtPlayhead()
    }

    @objc private func cancelClipTapped() {
        print("❌ Canceling clip mode")

        if isLooping {
            stopLoop()
        }

        exitClipMode()
    }

    private func exitClipMode() {
        print("❌ Exiting clip mode")
        
        // FIX: Sync scrubber position with current clip playhead before exiting
        scrubberPosition = clipPlayheadPosition
        
        isClipMode = false

        // Transform button back to edit icon
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let editImage = UIImage(systemName: "film.circle.fill", withConfiguration: config)
        clipSaveButton.setImage(editImage, for: .normal)
        clipSaveButton.tintColor = .white

        UIView.animate(withDuration: 0.3) {
            // Hide clip UI
            self.leftDimView.isHidden = true
            self.rightDimView.isHidden = true
            self.topBorder.isHidden = true
            self.bottomBorder.isHidden = true
            self.leftTrimHandle.isHidden = true
            self.rightTrimHandle.isHidden = true
            self.clipPlayhead.isHidden = true
            self.playheadTouchArea.isHidden = true
            self.clipRegionBackground.isHidden = true

            // Show scrubber
            self.scrubberBackground.alpha = 1
            self.scrubberPlayhead.alpha = 1

            // Hide cancel button
            self.cancelClipButton.isHidden = true
        }
        
        // FIX: Update scrubber to show current position
        updateScrubberPlayheadPosition()
        
        // FIX: Calculate correct time label for scrubber mode
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        if totalFrames >= requiredFrames {
            let pausePointIndex = totalFrames - requiredFrames  // ADD THIS LINE
            let scrubBackFrames = scrubDurationSeconds * actualFPS
            let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

            // Can't go older than what's in cache
            let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
            let oldestInCache = max(1, totalFrames - cacheSize)
            let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
            
            let secondsFromStart = Float(scrubberPosition - oldestAllowedIndex) / Float(actualFPS)
            DispatchQueue.main.async {
                self.timeLabel.text = String(format: "%05.2f", secondsFromStart)
            }
        }
        
        // FIX: Display the frame at the scrubber position
        videoFileBuffer?.extractFrameFromFile(at: scrubberPosition) { [weak self] image in
            guard let self = self, let image = image else { return }
            self.displayFrame(image)
        }
    }

    private func updateClipHandlePositions() {
        guard isClipMode else { return }
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size for the range
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        
        let totalClipRange = pausePointIndex - oldestAllowedIndex
        guard totalClipRange > 0 else { return }
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        // Calculate normalized positions (0.0 to 1.0) within the scrub range
        let leftNormalized = CGFloat(clipStartIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        let rightNormalized = CGFloat(clipEndIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        
        // Convert to pixel positions
        let leftPosition = leftNormalized * timelineWidth
        let rightPosition = rightNormalized * timelineWidth
        
        // Update constraints
        leftHandleConstraint?.constant = leftPosition
        rightHandleConstraint?.constant = -(timelineWidth - rightPosition)
        
        timelineContainer.layoutIfNeeded()
    }

    private func updatePlayheadPosition() {
        // FIX: Only update playhead position when in clip mode
        guard isClipMode else { return }
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        // Calculate handle positions within the timeline
        let totalClipRange = pausePointIndex - oldestAllowedIndex
        guard totalClipRange > 0 else { return }
        
        let leftNormalized = CGFloat(clipStartIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        let rightNormalized = CGFloat(clipEndIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        
        let leftPosition = leftNormalized * timelineWidth
        let rightPosition = rightNormalized * timelineWidth
        
        let leftHandleRightEdge = leftPosition + handleWidth
        let rightHandleLeftEdge = rightPosition - handleWidth
        let clipRegionWidth = rightHandleLeftEdge - leftHandleRightEdge
        
        // Guard against division by zero
        guard clipEndIndex > clipStartIndex else {
            print("⚠️ Invalid clip range: start=\(clipStartIndex) end=\(clipEndIndex)")
            return
        }
        
        // Calculate playhead position within the clip region
        let normalizedPlayheadPosition = CGFloat(clipPlayheadPosition - clipStartIndex) / CGFloat(clipEndIndex - clipStartIndex)
        let playheadPosition = leftHandleRightEdge + (normalizedPlayheadPosition * clipRegionWidth)
        
        // Verify the position is valid before setting constraint
        guard playheadPosition.isFinite else {
            print("⚠️ Invalid playhead position calculated: \(playheadPosition)")
            return
        }
        
        playheadConstraint?.constant = playheadPosition
        
        // Clamp touch area within timeline bounds
        let touchAreaWidth: CGFloat = 44
        let idealTouchX = playheadPosition - (touchAreaWidth / 2)
        let clampedTouchX = max(0, min(idealTouchX, timelineWidth - touchAreaWidth))
        playheadTouchArea.frame.origin.x = clampedTouchX
        
        timelineContainer.layoutIfNeeded()
        
        //validatePlayheadSync()
    }

    private func updateTimeLabel() {
        // FIX: Only update time label for clip mode
        guard isClipMode else { return }
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let timeInClip = Float(clipPlayheadPosition - clipStartIndex) / Float(actualFPS)
        DispatchQueue.main.async {
            self.timeLabel.text = String(format: "%05.2f", timeInClip)
        }
    }

    private func displayFrameAtPlayhead() {
        guard isClipMode else { return }
        
        // Extract and display the frame at the current playhead position
        videoFileBuffer?.extractFrameFromFile(at: clipPlayheadPosition) { [weak self] image in
            guard let self = self else { return }
            
            if let image = image {
                self.displayFrame(image)
            } else {
                // FIX: If file extraction fails, try getting from cache
                if let cachedImage = self.videoFileBuffer?.getRecentFrame(at: self.clipPlayheadPosition) {
                    self.displayFrame(cachedImage)
                } else {
                    print("⚠️ Could not display frame at index \(self.clipPlayheadPosition)")
                }
            }
        }
    }

    @objc private func handleLeftTrimPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: timelineContainer)
        
        if gesture.state == .began {
            if isLooping {
                stopLoop()
            }
            isDraggingHandle = true
            initialLeftPosition = leftHandleConstraint?.constant ?? 0
            initialClipStartIndex = clipStartIndex
            
            self.clipPlayhead.alpha = 0
            self.playheadTouchArea.alpha = 0
        }
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        let scrubRange = pausePointIndex - oldestAllowedIndex
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        let newLeftPosition = initialLeftPosition + translation.x
        let normalizedPosition = max(0, min(newLeftPosition / timelineWidth, 1.0))
        let newStartFrame = oldestAllowedIndex + Int(normalizedPosition * CGFloat(scrubRange))
        
        let minStartFrame = oldestAllowedIndex
        let maxStartFrame = clipEndIndex - actualFPS
        
        clipStartIndex = max(minStartFrame, min(newStartFrame, maxStartFrame))
        clipPlayheadPosition = clipStartIndex
        
        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()
        
        // FIX: Use cache during dragging with throttling
        if gesture.state == .changed {
            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                let targetPosition = clipPlayheadPosition
                if let cachedImage = videoFileBuffer?.getRecentFrame(at: targetPosition) {
                    displayFrame(cachedImage)
                } else {
                    videoFileBuffer?.extractFrameFromFile(at: targetPosition) { [weak self] image in
                        guard let self = self, let image = image else { return }
                        if self.clipPlayheadPosition == targetPosition {
                            self.displayFrame(image)
                        }
                    }
                }
            }
        } else if gesture.state == .ended || gesture.state == .cancelled {
            isDraggingHandle = false
            
            // FIX: Final frame display without throttling
            let targetPosition = clipPlayheadPosition
            if let cachedImage = videoFileBuffer?.getRecentFrame(at: targetPosition) {
                displayFrame(cachedImage)
            } else {
                videoFileBuffer?.extractFrameFromFile(at: targetPosition) { [weak self] image in
                    guard let self = self, let image = image else { return }
                    if self.clipPlayheadPosition == targetPosition {
                        self.displayFrame(image)
                    }
                }
            }
            
            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha = 1
                self.playheadTouchArea.alpha = 1
            }
        }
    }

    @objc private func handleRightTrimPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: timelineContainer)
        
        if gesture.state == .began {
            if isLooping {
                stopLoop()
            }
            isDraggingHandle = true
            initialRightPosition = rightHandleConstraint?.constant ?? 0
            initialClipEndIndex = clipEndIndex
        }
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        let scrubRange = pausePointIndex - oldestAllowedIndex
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        let currentXFromLeft = timelineWidth + initialRightPosition + translation.x
        let normalizedPosition = max(0, min(currentXFromLeft / timelineWidth, 1.0))
        let newEndFrame = oldestAllowedIndex + Int(normalizedPosition * CGFloat(scrubRange))
        
        let minEndFrame = clipStartIndex + 30
        let maxEndFrame = pausePointIndex
        
        clipEndIndex = max(minEndFrame, min(newEndFrame, maxEndFrame))
        clipPlayheadPosition = clipEndIndex
        
        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()
        
        // FIX: Use cache during dragging with throttling
        if gesture.state == .changed {
            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                let targetPosition = clipPlayheadPosition
                if let cachedImage = videoFileBuffer?.getRecentFrame(at: targetPosition) {
                    displayFrame(cachedImage)
                } else {
                    videoFileBuffer?.extractFrameFromFile(at: targetPosition) { [weak self] image in
                        guard let self = self, let image = image else { return }
                        if self.clipPlayheadPosition == targetPosition {
                            self.displayFrame(image)
                        }
                    }
                }
            }
        } else if gesture.state == .ended || gesture.state == .cancelled {
            isDraggingHandle = false
            
            // FIX: Final frame display without throttling
            let targetPosition = clipPlayheadPosition
            if let cachedImage = videoFileBuffer?.getRecentFrame(at: targetPosition) {
                displayFrame(cachedImage)
            } else {
                videoFileBuffer?.extractFrameFromFile(at: targetPosition) { [weak self] image in
                    guard let self = self, let image = image else { return }
                    if self.clipPlayheadPosition == targetPosition {
                        self.displayFrame(image)
                    }
                }
            }
            
            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha = 1
                self.playheadTouchArea.alpha = 1
            }
        }
    }

    @objc private func handlePlayheadPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: timelineContainer)
        
        if gesture.state == .began {
            initialPlayheadPosition = playheadConstraint?.constant ?? 0
            initialClipPlayheadPosition = clipPlayheadPosition
        }
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        // Calculate handle positions
        let totalClipRange = pausePointIndex - oldestAllowedIndex
        guard totalClipRange > 0 else { return }
        
        let leftNormalized = CGFloat(clipStartIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        let rightNormalized = CGFloat(clipEndIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        
        let leftPosition = leftNormalized * timelineWidth
        let rightPosition = rightNormalized * timelineWidth
        
        let leftHandleRightEdge = leftPosition + handleWidth
        let rightHandleLeftEdge = rightPosition - handleWidth
        let clipRegionWidth = rightHandleLeftEdge - leftHandleRightEdge
        
        let newPlayheadX = initialPlayheadPosition + translation.x
        let clampedX = max(leftHandleRightEdge, min(newPlayheadX, rightHandleLeftEdge))
        
        let normalizedPosition = (clampedX - leftHandleRightEdge) / clipRegionWidth
        clipPlayheadPosition = clipStartIndex + Int(normalizedPosition * CGFloat(clipEndIndex - clipStartIndex))
        clipPlayheadPosition = max(clipStartIndex, min(clipPlayheadPosition, clipEndIndex))
        
        updatePlayheadPosition()
        updateTimeLabel()
        
        // FIX: Use cache for instant display, with position check
        let targetPosition = clipPlayheadPosition
        if let cachedImage = videoFileBuffer?.getRecentFrame(at: targetPosition) {
            displayFrame(cachedImage)
        } else {
            // Fallback to file extraction
            videoFileBuffer?.extractFrameFromFile(at: targetPosition) { [weak self] image in
                guard let self = self, let image = image else { return }
                // Only display if we're still at this position
                if self.clipPlayheadPosition == targetPosition {
                    self.displayFrame(image)
                }
            }
        }
    }

    @objc private func handleTimelineTap(_ gesture: UITapGestureRecognizer) {
        guard isClipMode else { return }
        
        let location = gesture.location(in: timelineContainer)
        
        metadataLock.lock()
        let totalFrames = frameMetadata.count
        metadataLock.unlock()
        
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames >= requiredFrames else { return }
        
        let pausePointIndex = totalFrames - requiredFrames
        
        // PHASE 1: Use actual cache size
        let scrubBackFrames = scrubDurationSeconds * actualFPS
        let desiredOldestIndex = max(1, pausePointIndex - scrubBackFrames)

        // Can't go older than what's in cache
        let cacheSize = videoFileBuffer?.getRecentFrameCount() ?? 0
        let oldestInCache = max(1, totalFrames - cacheSize)
        let oldestAllowedIndex = max(desiredOldestIndex, oldestInCache)
        
        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }
        
        // Calculate handle positions
        let totalClipRange = pausePointIndex - oldestAllowedIndex
        guard totalClipRange > 0 else { return }
        
        let leftNormalized = CGFloat(clipStartIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        let rightNormalized = CGFloat(clipEndIndex - oldestAllowedIndex) / CGFloat(totalClipRange)
        
        let leftPosition = leftNormalized * timelineWidth
        let rightPosition = rightNormalized * timelineWidth
        
        let leftHandleRightEdge = leftPosition + handleWidth
        let rightHandleLeftEdge = rightPosition - handleWidth
        
        guard location.x >= leftHandleRightEdge && location.x <= rightHandleLeftEdge else { return }
        
        let clipRegionWidth = rightHandleLeftEdge - leftHandleRightEdge
        let normalizedPosition = (location.x - leftHandleRightEdge) / clipRegionWidth
        clipPlayheadPosition = clipStartIndex + Int(normalizedPosition * CGFloat(clipEndIndex - clipStartIndex))
        clipPlayheadPosition = max(clipStartIndex, min(clipPlayheadPosition, clipEndIndex))
        
        updatePlayheadPosition()
        updateTimeLabel()
        displayFrameAtPlayhead()
        
        print("🎯 Playhead jumped to frame \(clipPlayheadPosition)")
    }

    private func createLoadingView(text: String) -> UIView {
        let container = UIView(frame: bounds)
        container.backgroundColor = UIColor.black.withAlphaComponent(0.7)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(spinner)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])

        return container
    }

    private func createClipVideo(completion: @escaping (URL?) -> Void) {
        guard let videoFileBuffer = videoFileBuffer else {
            completion(nil)
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swing_clip_\(Date().timeIntervalSince1970).mp4")

        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            print("❌ Failed to create AVAssetWriter")
            completion(nil)
            return
        }

        // Get the current rotation angle from the preview layer
        let rotationAngle = previewLayer?.connection?.videoRotationAngle ?? 0
        print("🔄 Creating clip with rotation angle: \(rotationAngle), isFrontCamera: \(isFrontCamera)")
        
        // Get the actual FPS being used
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        print("📹 Creating clip at \(actualFPS) fps")
        
        // Determine video dimensions based on rotation
        let isRotated = rotationAngle == 90 || rotationAngle == 270
        let videoWidth = isRotated ? 1080 : 1920
        let videoHeight = isRotated ? 1920 : 1080

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoWidth * videoHeight * 11,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: actualFPS,
                AVVideoMaxKeyFrameIntervalKey: actualFPS
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else {
            print("❌ Cannot add writer input")
            completion(nil)
            return
        }

        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let clipFrameCount = clipEndIndex - clipStartIndex
        print("📹 Creating clip: \(clipFrameCount) frames (\(Float(clipFrameCount)/Float(actualFPS))s)")

        var frameIndex = 0
        let queue = DispatchQueue(label: "com.loopr.clipExport")

        writerInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self = self else {
                writer.cancelWriting()
                completion(nil)
                return
            }

            while writerInput.isReadyForMoreMediaData && frameIndex < clipFrameCount {
                let currentFrameIndex = self.clipStartIndex + frameIndex
                let presentationTime = CMTime(value: Int64(frameIndex), timescale: CMTimeScale(actualFPS))

                let semaphore = DispatchSemaphore(value: 0)
                var pixelBuffer: CVPixelBuffer?

                videoFileBuffer.extractFrameFromFile(at: currentFrameIndex) { image in
                    if let image = image {
                        // Apply rotation to the image before converting to pixel buffer
                        let rotatedImage = self.rotateImage(image, by: rotationAngle, isFrontCamera: self.isFrontCamera)
                        if let buffer = self.pixelBuffer(from: rotatedImage, size: CGSize(width: videoWidth, height: videoHeight)) {
                            pixelBuffer = buffer
                        }
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                if let buffer = pixelBuffer {
                    adaptor.append(buffer, withPresentationTime: presentationTime)
                    frameIndex += 1

                    if frameIndex % actualFPS == 0 {
                        print("📹 Progress: \(frameIndex)/\(clipFrameCount) frames")
                    }
                } else {
                    print("⚠️ Failed to extract frame at index \(currentFrameIndex)")
                    frameIndex += 1
                }
            }

            if frameIndex >= clipFrameCount {
                writerInput.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        print("✅ Clip created successfully: \(outputURL.lastPathComponent)")
                        completion(outputURL)
                    } else {
                        print("❌ Writer failed: \(String(describing: writer.error))")
                        completion(nil)
                    }
                }
            }
        }
    }

    private func rotateImage(_ image: UIImage, by angle: CGFloat, isFrontCamera: Bool) -> UIImage {
        let radians = angle * .pi / 180
        
        // 1. Calculate the bounding box for the rotated image
        let imgRect = CGRect(origin: .zero, size: image.size)
        let rotatedRect = imgRect.applying(CGAffineTransform(rotationAngle: radians))
        let targetSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))

        // 2. Start a new image context
        UIGraphicsBeginImageContextWithOptions(targetSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        // 3. Move origin to center
        context.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
        
        // 4. Apply Rotation
        // FIX: Back camera needs counter-clockwise (+) and Front needs clockwise (-)
        if isFrontCamera {
            context.rotate(by: -radians)
        } else {
            context.rotate(by: radians)
        }
        
        // 5. Apply Mirroring for Front Camera ONLY
        if isFrontCamera {
            context.scaleBy(x: -1.0, y: 1.0)
            print("🪞 Mirroring applied for front camera")
        }

        // 6. Draw the image centered
        // image.draw(in:) is used here as it correctly handles the internal coordinate system
        let drawRect = CGRect(x: -image.size.width / 2,
                              y: -image.size.height / 2,
                              width: image.size.width,
                              height: image.size.height)
        
        image.draw(in: drawRect)

        // 7. Retrieve the final image
        let finalImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return finalImage ?? image
    }

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let ctx = context, let cgImage = image.cgImage else {
            return nil
        }

        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        if let viewController = self.window?.rootViewController {
            viewController.present(alert, animated: true)
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // If we're in scrubber mode (paused but not clip mode) and the touch is near the timeline
        if isPaused && !isClipMode {
            let timelinePoint = convert(point, to: timelineContainer)
            
            // Expand timeline hit area by 22px horizontally to catch playhead knob touches
            let expandedTimelineBounds = timelineContainer.bounds.insetBy(dx: -22, dy: -10)
            
            if expandedTimelineBounds.contains(timelinePoint) {
                // Return the timeline so it receives the touch
                return timelineContainer
            }
        }
        
        return super.hitTest(point, with: event)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension DelayedCameraView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isActive, !isPaused else { return }

        videoFileBuffer?.appendFrame(sampleBuffer: sampleBuffer) { [weak self] success in
            guard let self = self, success else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            self.metadataLock.lock()
            let frameIndex = self.frameMetadata.count
            self.frameMetadata.append((timestamp: timestamp, index: frameIndex))

            let count = self.frameMetadata.count
            self.metadataLock.unlock()

            if count == 1 {
                print("🎬 First frame captured to file!")
            } else {
                let actualFPS = Settings.shared.currentFPS(isFrontCamera: self.isFrontCamera)
                if count % (actualFPS * 10) == 0 {  // Log every 10 seconds
                    print("📹 Metadata: \(count) frames (~\(count/actualFPS)s)")
                }
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate
extension DelayedCameraView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let location = touch.location(in: timelineContainer)
        
        if isClipMode {
            // Define a "hit zone" for the handles (including a bit of padding for easier grabbing)
            let handlePadding: CGFloat = 15
            let leftHitZone = leftTrimHandle.frame.insetBy(dx: -handlePadding, dy: -handlePadding)
            let rightHitZone = rightTrimHandle.frame.insetBy(dx: -handlePadding, dy: -handlePadding)
            
            // If the touch is within the bounds of either handle...
            if leftHitZone.contains(location) || rightHitZone.contains(location) {
                // ...and this is the playhead's gesture, return false so the playhead doesn't steal the touch.
                if gestureRecognizer.view == playheadTouchArea {
                    return false
                }
                // Allow the handle's own gesture to proceed
                return true
            }
            
            // Otherwise, allow the playhead to be dragged anywhere else on the timeline
            return gestureRecognizer.view == playheadTouchArea
        }
        
        // Scrubber mode logic
        return true
    }
}
