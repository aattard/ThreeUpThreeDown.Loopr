import Foundation
import AVFoundation
import UIKit

// ---------------------------------------------------------------------------
// VideoFileBuffer
//
// Architecture (rewritten):
//
//  Recording:
//   • Three alternating files (buffer_main.mp4 / buffer_alt.mp4 / buffer_prev.mp4),
//     each capped at half the rolling window (150 s by default).  On rotation the
//     previous two files are kept so a pause can always compose up to 450 s of
//     footage, trimmed to the 300 s window.
//
//  Live-delay display:
//   • recentFramesCache — a UIImage ring buffer covering only
//     (delaySeconds + 3) * fps frames.  Filled on every appended frame.
//     Used exclusively by DelayedCameraView.captureOutput for the live feed.
//
//  Pause / scrub / playback:
//   • At pause time we build an AVMutableComposition that stitches up to three
//     segments together, then hand an AVPlayer-ready asset back to the caller.
//   • Scrubbing calls player.seek(to:toleranceBefore:toleranceAfter:).
//   • Playback is plain AVPlayer.play() / pause() / seek().
//
//  Frame index ↔ CMTime mapping:
//   • frameTimestamps[i] stores the raw camera presentation timestamp of
//     global frame i.  At pause time pausedCompositionStartTime records
//     the composition's origin so callers can convert:
//       compositionTime = frameTimestamps[i] - pausedCompositionStartTime
// ---------------------------------------------------------------------------

class VideoFileBuffer {

    // MARK: - Types

    struct Segment {
        let fileURL: URL
        let startTime: CMTime
        let endTime: CMTime
    }

    // MARK: - Private state — writer

    private var currentWriter: AVAssetWriter?
    private var currentWriterInput: AVAssetWriterInput?

    /// 0 = buffer_main, 1 = buffer_alt, 2 = buffer_prev — cycles 0→1→2→0
    private var currentFileIndex: Int = 0

    private var fileURLs: [URL] = []
    private let fileManager = FileManager.default

    private var fileStartTime: CMTime?
    private var lastAppendedTime: CMTime = .zero

    private var frameCount: Int = 0
    private var globalFrameCount: Int = 0

    private var isPaused = false

    // MARK: - Private state — segments

    /// Up to three segments kept alive for the rolling window.
    private var segments: [Segment] = []

    // MARK: - Private state — pause / playback

    private(set) var pausedComposition: AVMutableComposition?
    private(set) var pausedCompositionStartTime: CMTime = .zero
    private(set) var pausedCompositionDisplayStartTime: CMTime = .zero
    private(set) var pausedCompositionEndTime: CMTime = .zero
    private(set) var pausedFrameCount: Int = 0

    // MARK: - Private state — timestamps

    private var frameTimestamps: [CMTime] = []
    private let timestampLock = NSLock()
    private let maxTimestampCount: Int
    private var prunedFrameCount: Int = 0

    // MARK: - Private state — motion scores
    // One Float per frame, kept in lockstep with frameTimestamps.
    // Values are raw mean-absolute-difference scores (0–1 range before normalisation).
    private var motionScores: [Float] = []
    private var prevFramePixelBuffer: CVPixelBuffer?

    /// The rotation angle (in degrees) of the recording session.
    /// Set by the caller before recording begins so computeMotionScore can orient
    /// the thumbnail correctly. Back camera raw pixel buffers arrive in landscape
    /// orientation from the sensor — without rotating before diffing, motion scores
    /// are artificially small because the athlete occupies fewer pixels in the frame.
    var recordingRotationAngle: CGFloat = 0

    // MARK: - Private state — live-delay cache

    private var recentFramesCache: [UIImage] = []
    private var cacheStartIndex: Int = 0
    private let cacheLock = NSLock()
    private let maxCacheSize: Int

    // MARK: - Configuration

    private let maxDurationSeconds: Int
    private let halfWindowSeconds: Int
    private let delaySeconds: Int
    let fps: Int
    private let writeQueue: DispatchQueue
    private let ciContext: CIContext

    // MARK: - Init

    init(maxDurationSeconds: Int,
         delaySeconds: Int,
         fps: Int,
         writeQueue: DispatchQueue,
         ciContext: CIContext) {

        self.maxDurationSeconds = maxDurationSeconds
        self.halfWindowSeconds  = max(30, maxDurationSeconds / 2)
        self.fps                = fps
        self.delaySeconds       = delaySeconds
        self.writeQueue         = writeQueue
        self.ciContext          = ciContext
        self.maxCacheSize       = (delaySeconds + 3) * fps
        self.maxTimestampCount  = maxDurationSeconds * fps

        let tmp = FileManager.default.temporaryDirectory
        self.fileURLs = [
            tmp.appendingPathComponent("buffer_main.mp4"),
            tmp.appendingPathComponent("buffer_alt.mp4"),
            tmp.appendingPathComponent("buffer_prev.mp4")
        ]

        print("📁 VideoFileBuffer init — window: \(maxDurationSeconds)s, " +
              "halfWindow: \(halfWindowSeconds)s, fps: \(fps), " +
              "cacheSize: \(maxCacheSize)")
    }

    // MARK: - Active file URL

    private var activeFileURL: URL {
        fileURLs[currentFileIndex]
    }

    func getCurrentFileURL() -> URL? {
        activeFileURL
    }

    // MARK: - Writer setup

    func startWriting(videoSettings: [String: Any], isInitialStart: Bool = false) throws {
        let fileURL = activeFileURL
        try? fileManager.removeItem(at: fileURL)

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let input  = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        input.transform = .identity

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoFileBuffer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        currentWriter      = writer
        currentWriterInput = input
        frameCount         = 0
        fileStartTime      = nil
        isPaused           = false
        pausedComposition  = nil

        if isInitialStart {
            timestampLock.lock()
            frameTimestamps.removeAll()
            motionScores.removeAll()
            prevFramePixelBuffer = nil
            timestampLock.unlock()

            cacheLock.lock()
            recentFramesCache.removeAll()
            cacheStartIndex  = 0
            globalFrameCount = 0
            prunedFrameCount = 0
            cacheLock.unlock()

            segments.removeAll()
            currentFileIndex = 0
            print("✅ Started writing (INITIAL) → \(fileURL.lastPathComponent)")
        } else {
            print("✅ Rotated → \(fileURL.lastPathComponent)  " +
                  "(globalFrame: \(globalFrameCount))")
        }
    }

    // MARK: - Frame appending

    func appendFrame(sampleBuffer: CMSampleBuffer,
                     completion: @escaping (Bool) -> Void) {
        guard let writerInput = currentWriterInput,
              let writer      = currentWriter,
              writer.status  == .writing else {
            completion(false)
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if fileStartTime == nil {
            fileStartTime = presentationTime
        }

        let elapsed = CMTimeGetSeconds(presentationTime - (fileStartTime ?? .zero))
        if elapsed >= Double(halfWindowSeconds) {
            rotateToNextFile(
                videoSettings: writerInput.outputSettings as? [String: Any],
                segmentEndTime: presentationTime)
            completion(false)
            return
        }

        guard writerInput.isReadyForMoreMediaData else {
            completion(false)
            return
        }

        let normalizedTime = CMTimeSubtract(presentationTime, fileStartTime ?? .zero)
        var timing = CMSampleTimingInfo(
            duration:              CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: normalizedTime,
            decodeTimeStamp:       .invalid)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDesc  = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            completion(false)
            return
        }

        var newSB: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator:         kCFAllocatorDefault,
            imageBuffer:       pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming:      &timing,
            sampleBufferOut:   &newSB)

        guard status == noErr, let normalizedSB = newSB else {
            completion(false)
            return
        }

        let ok = writerInput.append(normalizedSB)
        if ok {
            frameCount       += 1
            globalFrameCount += 1
            lastAppendedTime  = presentationTime

            // Compute motion score before updating prevFramePixelBuffer
            let score = computeMotionScore(current: pixelBuffer, previous: prevFramePixelBuffer)
            // Retain a reference to this frame for the next diff
            prevFramePixelBuffer = pixelBuffer

            timestampLock.lock()
            frameTimestamps.append(presentationTime)
            motionScores.append(score)
            if frameTimestamps.count > maxTimestampCount {
                frameTimestamps.removeFirst()
                motionScores.removeFirst()
                prunedFrameCount += 1
            }
            timestampLock.unlock()

            cacheFrameForDisplay(sampleBuffer: sampleBuffer)
        }
        completion(ok)
    }

    // MARK: - Live-delay cache

    private func cacheFrameForDisplay(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let original = UIImage(cgImage: cgImage)

        let maxDim: CGFloat = 800
        let scale = min(maxDim / original.size.width,
                        maxDim / original.size.height, 1.0)
        let newSize = CGSize(width:  original.size.width  * scale,
                             height: original.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        original.draw(in: CGRect(origin: .zero, size: newSize))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let img = scaled else { return }

        cacheLock.lock()
        recentFramesCache.append(img)
        if recentFramesCache.count > maxCacheSize {
            recentFramesCache.removeFirst()
            cacheStartIndex += 1
        }
        cacheLock.unlock()
    }

    func getRecentFrame(at globalIndex: Int) -> UIImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let oldest = max(0, globalFrameCount - maxCacheSize)
        guard globalIndex >= oldest && globalIndex < globalFrameCount else { return nil }
        let idx = globalIndex - oldest
        guard idx >= 0 && idx < recentFramesCache.count else { return nil }
        return recentFramesCache[idx]
    }

    func getRecentFrameCount() -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return recentFramesCache.count
    }

    // MARK: - File rotation

    private func rotateToNextFile(videoSettings: [String: Any]?,
                                  segmentEndTime: CMTime) {
        let oldURL       = activeFileURL
        let oldStartTime = fileStartTime ?? .zero

        let completedSegment = Segment(fileURL:   oldURL,
                                       startTime: oldStartTime,
                                       endTime:   segmentEndTime)
        // Keep up to 3 segments for a full 300 s window
        if segments.count >= 3 {
            segments.removeFirst()
        }
        segments.append(completedSegment)

        pruneTimestampsToWindow(windowStart: segments.first?.startTime ?? oldStartTime)

        currentWriterInput?.markAsFinished()
        let oldWriter      = currentWriter
        let oldWriterInput = currentWriterInput
        currentWriter      = nil
        currentWriterInput = nil

        // Advance to next file slot (0→1→2→0)
        currentFileIndex = (currentFileIndex + 1) % 3

        if let settings = videoSettings {
            do {
                try startWriting(videoSettings: settings, isInitialStart: false)
            } catch {
                print("❌ Failed to start rotated writer: \(error)")
            }
        }

        oldWriter?.finishWriting { [weak self] in
            _ = oldWriterInput
            if oldWriter?.status == .completed {
                print("✅ Segment finalized: \(oldURL.lastPathComponent)")
            } else {
                print("⚠️ Segment finalize error: \(oldWriter?.error?.localizedDescription ?? "?")")
            }
            self?.cleanupExpiredSegmentFiles()
        }
    }

    private func cleanupExpiredSegmentFiles() {
        let activeURLs = Set(segments.map { $0.fileURL })
        for candidate in fileURLs {
            if !activeURLs.contains(candidate) {
                // Don't delete the file currently being written to
                guard candidate != activeFileURL else { continue }
                try? fileManager.removeItem(at: candidate)
            }
        }
    }

    private func pruneTimestampsToWindow(windowStart: CMTime) {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        var lo = 0, hi = frameTimestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if CMTimeCompare(frameTimestamps[mid], windowStart) < 0 { lo = mid + 1 }
            else { hi = mid }
        }
        if lo > 0 {
            frameTimestamps.removeFirst(lo)
            // Keep motionScores in lockstep — same count, same indices
            if lo <= motionScores.count {
                motionScores.removeFirst(lo)
            } else {
                motionScores.removeAll()
            }
            prunedFrameCount += lo
        }
    }

    // MARK: - Pause

    func pauseRecording(completion: @escaping (AVPlayerItem?, AVMutableComposition?) -> Void) {
        guard !isPaused, let writer = currentWriter else {
            if let comp = pausedComposition {
                let item = AVPlayerItem(asset: comp)
                DispatchQueue.main.async { completion(item, comp) }
            } else {
                DispatchQueue.main.async { completion(nil, nil) }
            }
            return
        }

        let minimumFrames = fps * 1
        guard globalFrameCount >= minimumFrames else {
            print("⚠️ pauseRecording: only \(globalFrameCount) frames, need \(minimumFrames)")
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }

        isPaused = true
        let segEndTime   = lastAppendedTime
        let segStartTime = fileStartTime ?? .zero
        let currentURL   = activeFileURL

        currentWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            guard writer.status == .completed else {
                print("❌ Writer failed at pause: \(writer.error?.localizedDescription ?? "?")")
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            let currentSegment = Segment(fileURL:   currentURL,
                                         startTime: segStartTime,
                                         endTime:   segEndTime)
            // Keep up to 3 segments
            if self.segments.count >= 3 { self.segments.removeFirst() }
            self.segments.append(currentSegment)

            print("📼 Segments at pause: \(self.segments.count)")
            for (i, s) in self.segments.enumerated() {
                let dur = CMTimeGetSeconds(s.endTime) - CMTimeGetSeconds(s.startTime)
                print("  [\(i)] \(s.fileURL.lastPathComponent) — \(String(format: "%.2f", dur))s")
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let (comp, compStartTime, frameCount) = self.buildComposition()
                self.pausedComposition          = comp
                self.pausedCompositionStartTime = compStartTime
                self.pausedFrameCount           = frameCount

                if let comp = comp {
                    let pausePointRaw = CMTimeSubtract(
                        segEndTime,
                        CMTime(seconds: Double(self.delaySeconds), preferredTimescale: 600))
                    let pausePointCompositionTime = CMTimeSubtract(pausePointRaw, compStartTime)
                    self.pausedCompositionEndTime = CMTimeMinimum(
                        CMTimeMaximum(pausePointCompositionTime, .zero),
                        comp.duration)

                    // ── NEW: start of displayed content = end - scrub window ──
                    let displayStartTime = CMTimeSubtract(
                        self.pausedCompositionEndTime,
                        CMTime(seconds: Double(self.maxDurationSeconds), preferredTimescale: 600))
                    self.pausedCompositionDisplayStartTime = CMTimeMaximum(displayStartTime, .zero)

                    print("⏸ Display window: \(CMTimeGetSeconds(self.pausedCompositionDisplayStartTime))s " +
                          "→ \(CMTimeGetSeconds(self.pausedCompositionEndTime))s")
                }

                let item = comp.map { AVPlayerItem(asset: $0) }
                DispatchQueue.main.async { completion(item, comp) }
            }
        }
    }

    // MARK: - Composition building

    private func buildComposition() -> (AVMutableComposition?, CMTime, Int) {
        guard !segments.isEmpty else { return (nil, .zero, 0) }

        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return (nil, .zero, 0)
        }

        let maxWindow    = CMTime(seconds: Double(maxDurationSeconds), preferredTimescale: 600)
        var insertCursor = CMTime.zero
        let allEnd       = segments.last!.endTime
        let windowStart  = CMTimeSubtract(allEnd, maxWindow)

        var compositionOriginRawTime = CMTime.zero
        var firstSegment = true

        for seg in segments {
            let asset = AVURLAsset(url: seg.fileURL,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

            let semaphore  = DispatchSemaphore(value: 0)
            var assetTrack: AVAssetTrack?

            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                DispatchQueue.global(qos: .userInitiated).async {
                    var error: NSError?
                    let status = asset.statusOfValue(forKey: "tracks", error: &error)
                    if status == .loaded {
                        assetTrack = asset.tracks(withMediaType: .video).first
                    } else {
                        print("⚠️ Tracks failed to load for \(seg.fileURL.lastPathComponent): " +
                              "\(error?.localizedDescription ?? "?")")
                    }
                    semaphore.signal()
                }
            }
            semaphore.wait()

            guard let videoTrack = assetTrack else {
                print("⚠️ Skipping \(seg.fileURL.lastPathComponent) — no video track")
                continue
            }

            let fileDuration     = videoTrack.timeRange.duration
            let fileDurationSecs = CMTimeGetSeconds(fileDuration)
            guard fileDurationSecs > 0.1 else {
                print("⚠️ Skipping \(seg.fileURL.lastPathComponent) — too short: \(fileDurationSecs)s")
                continue
            }

            let segRawDuration = CMTimeSubtract(seg.endTime, seg.startTime)
            let clipStartInFile: CMTime
            if CMTimeCompare(seg.startTime, windowStart) < 0 {
                let rawOffset  = CMTimeSubtract(windowStart, seg.startTime)
                let rawDurSecs = CMTimeGetSeconds(segRawDuration)
                let scale      = rawDurSecs > 0 ? (fileDurationSecs / rawDurSecs) : 1.0
                clipStartInFile = CMTimeMinimum(
                    CMTimeMultiplyByFloat64(rawOffset, multiplier: scale), fileDuration)
            } else {
                clipStartInFile = .zero
            }

            guard CMTimeCompare(clipStartInFile, fileDuration) < 0 else {
                print("⚠️ Skipping \(seg.fileURL.lastPathComponent) — clipStart past end")
                continue
            }

            let insertRange = CMTimeRange(start: clipStartInFile, end: fileDuration)
            do {
                try track.insertTimeRange(insertRange, of: videoTrack, at: insertCursor)
                if firstSegment {
                    let rawDurSecs = CMTimeGetSeconds(segRawDuration)
                    let scale      = rawDurSecs > 0 ? (rawDurSecs / fileDurationSecs) : 1.0
                    compositionOriginRawTime = CMTimeAdd(seg.startTime,
                        CMTimeMultiplyByFloat64(clipStartInFile, multiplier: scale))
                    firstSegment = false
                }
                insertCursor = CMTimeAdd(insertCursor,
                    CMTimeSubtract(fileDuration, clipStartInFile))
                print("✅ Inserted \(seg.fileURL.lastPathComponent): " +
                      "\(String(format: "%.2f", CMTimeGetSeconds(clipStartInFile)))s → " +
                      "\(String(format: "%.2f", fileDurationSecs))s")
            } catch {
                print("❌ Insert error \(seg.fileURL.lastPathComponent): \(error)")
            }
        }

        guard !firstSegment else {
            print("❌ buildComposition: no usable segments")
            return (nil, .zero, 0)
        }

        timestampLock.lock()
        let tsCount = frameTimestamps.filter {
            CMTimeCompare($0, compositionOriginRawTime) >= 0
        }.count
        timestampLock.unlock()

        print("✅ buildComposition — \(String(format: "%.2f", CMTimeGetSeconds(comp.duration)))s, " +
              "\(tsCount) timestamps")
        return (comp, compositionOriginRawTime, tsCount)
    }

    // MARK: - Frame index → composition CMTime

    func compositionTime(forFrameIndex index: Int) -> CMTime? {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        let arrayIndex = index - prunedFrameCount
        guard arrayIndex >= 0 && arrayIndex < frameTimestamps.count else { return nil }
        let raw = frameTimestamps[arrayIndex]
        let t   = CMTimeSubtract(raw, pausedCompositionStartTime)
        guard CMTimeGetSeconds(t) >= 0 else { return nil }
        return t
    }

    // MARK: - Frame count accessors

    func getCurrentFrameCount() -> Int { globalFrameCount }

    func getFrameTimestamps() -> [CMTime] {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return frameTimestamps
    }

    func getTimestampCount() -> Int {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return frameTimestamps.count
    }

    // MARK: - Cleanup

    func stopWriting(completion: @escaping () -> Void) {
        guard let writer = currentWriter else { cleanup(); completion(); return }
        if writer.status == .writing {
            currentWriterInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                self?.cleanup()
                completion()
            }
        } else {
            cleanup()
            completion()
        }
    }

    func cleanup() {
        pausedComposition = nil

        timestampLock.lock()
        frameTimestamps.removeAll()
        motionScores.removeAll()
        prevFramePixelBuffer = nil
        timestampLock.unlock()

        cacheLock.lock()
        recentFramesCache.removeAll()
        cacheStartIndex  = 0
        globalFrameCount = 0
        prunedFrameCount = 0
        cacheLock.unlock()

        segments.removeAll()

        for url in fileURLs {
            try? fileManager.removeItem(at: url)
        }

        currentWriter      = nil
        currentWriterInput = nil
        frameCount         = 0
        fileStartTime      = nil
        isPaused           = false
        pausedComposition  = nil
        pausedCompositionStartTime = .zero
        pausedCompositionEndTime   = .zero
        pausedFrameCount           = 0
        currentFileIndex           = 0
    }

    // MARK: - Motion score computation

    /// Computes a normalised mean-absolute-difference score between two pixel buffers.
    /// Works on luma only at a tiny thumbnail resolution (64×36) so it is very fast
    /// (~0.5 ms on a modern A-series chip) and safe to call on the capture queue every frame.
    ///
    /// Returns 0 if there is no previous frame (first frame), or if locking either buffer fails.
    ///
    /// IMPORTANT — pixel format handling:
    /// The back camera delivers YCbCr (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) buffers.
    /// The front camera delivers BGRA buffers (because Apple's mirror pipeline converts them).
    /// We use CIContext.render(into:) to a fresh BGRA CVPixelBuffer so the luma byte arithmetic
    /// below works identically regardless of which camera is active.
    private func computeMotionScore(current: CVPixelBuffer, previous: CVPixelBuffer?) -> Float {
        guard let previous else { return 0.0 }

        // ── Diagnostic: log pixel format on first frame only ─────────────────────
        // kCVPixelFormatType_32BGRA                        = 1111970369 ('BGRA')
        // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  =  875704438 ('420v')
        // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange   =  875704422 ('420f')
        if motionScores.isEmpty {
            let fmt = CVPixelBufferGetPixelFormatType(current)
            let fmtStr = String(format: "0x%08X (%u)", fmt, fmt)
            print("🎥 computeMotionScore — pixel format: \(fmtStr) | " +
                  "size: \(CVPixelBufferGetWidth(current))×\(CVPixelBufferGetHeight(current))")
        }

        // ── Thumbnail dimensions ──────────────────────────────────────────────────
        let thumbWidth  = 64
        let thumbHeight = 36

        // ── Helper: render a pixel buffer into a fresh BGRA thumbnail ────────────
        // Using CIContext.render(into:) guarantees BGRA output regardless of whether
        // the source is YCbCr (back camera) or BGRA (front camera).
        func makeBGRAThumbnail(from pb: CVPixelBuffer) -> CVPixelBuffer? {
            let src = CIImage(cvPixelBuffer: pb)
            let scaleX = CGFloat(thumbWidth)  / CGFloat(CVPixelBufferGetWidth(pb))
            let scaleY = CGFloat(thumbHeight) / CGFloat(CVPixelBufferGetHeight(pb))
            let scaled = src.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            var outBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                thumbWidth, thumbHeight,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &outBuffer)
            guard status == kCVReturnSuccess, let out = outBuffer else { return nil }

            ciContext.render(scaled, to: out,
                             bounds: CGRect(x: 0, y: 0,
                                            width: thumbWidth, height: thumbHeight),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            return out
        }

        guard let bufCurrent  = makeBGRAThumbnail(from: current),
              let bufPrevious = makeBGRAThumbnail(from: previous) else { return 0.0 }

        // ── Lock both buffers and diff their luma bytes ───────────────────────────
        CVPixelBufferLockBaseAddress(bufCurrent,  .readOnly)
        CVPixelBufferLockBaseAddress(bufPrevious, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(bufCurrent,  .readOnly)
            CVPixelBufferUnlockBaseAddress(bufPrevious, .readOnly)
        }

        guard let ptrCurrent  = CVPixelBufferGetBaseAddress(bufCurrent),
              let ptrPrevious = CVPixelBufferGetBaseAddress(bufPrevious) else { return 0.0 }

        let pixelCount = thumbWidth * thumbHeight
        var totalDiff: Float = 0.0

        let pCurrent  = ptrCurrent.assumingMemoryBound(to: UInt8.self)
        let pPrevious = ptrPrevious.assumingMemoryBound(to: UInt8.self)

        // BGRA layout: byte 0=B, 1=G, 2=R, 3=A — BT.601 luma weights
        for i in 0 ..< pixelCount {
            let base = i * 4
            let lumaCurrent  = 0.114 * Float(pCurrent[base])
                             + 0.587 * Float(pCurrent[base + 1])
                             + 0.299 * Float(pCurrent[base + 2])
            let lumaPrevious = 0.114 * Float(pPrevious[base])
                             + 0.587 * Float(pPrevious[base + 1])
                             + 0.299 * Float(pPrevious[base + 2])
            totalDiff += abs(lumaCurrent - lumaPrevious)
        }

        // Raw mean-absolute-difference, normalised to 0–1 range.
        // We intentionally do NOT apply a sensitivity multiplier here — the
        // waveform renderer uses percentile-based normalisation (p50 noise floor,
        // p99 ceiling) which self-calibrates to whatever range the scores land in.
        // A multiplier caused back camera scores to saturate at 1.0 on almost every
        // frame (back camera frames have higher contrast than front camera), which
        // collapsed p50==p99 and produced a flat line.
        let raw = totalDiff / (Float(pixelCount) * 255.0)

        // ── Diagnostic: log first 5 non-zero scores to confirm detection ─────────
        if raw > 0 && motionScores.filter({ $0 > 0 }).count < 5 {
            print("🎥 Motion score sample raw: \(String(format: "%.7f", raw))")
        }

        return raw
    }

        // MARK: - Motion score accessor

    /// Returns a copy of the motion scores array, aligned 1:1 with frameTimestamps.
    /// Safe to call from any thread.
    func getMotionScores() -> [Float] {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return motionScores
    }

    deinit { cleanup() }
}
