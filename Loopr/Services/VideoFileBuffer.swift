import Foundation
import AVFoundation
import UIKit

// ---------------------------------------------------------------------------
// VideoFileBuffer
//
// Architecture (rewritten):
//
//  Recording:
//   • Two alternating files (buffer_main.mp4 / buffer_alt.mp4), each capped
//     at half the rolling window (150 s by default).  On rotation the old
//     file is *kept* until the next rotation so a pause can always compose
//     both halves into a full 300-s asset.
//
//  Live-delay display:
//   • recentFramesCache — a UIImage ring buffer covering only
//     (delaySeconds + 3) * fps frames.  Filled on every appended frame.
//     Used exclusively by DelayedCameraView.captureOutput for the live feed.
//
//  Pause / scrub / playback:
//   • At pause time we build an AVMutableComposition that stitches the
//     previous segment (if any) + current segment together, then hand an
//     AVPlayer-ready asset back to the caller.
//   • Scrubbing calls player.seek(to:toleranceBefore:toleranceAfter:).
//     No AVAssetImageGenerator, no generateCGImagesAsynchronously, no
//     manual cancel races.
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

    /// One recorded segment: a file URL + the wall-clock time span it covers.
    struct Segment {
        let fileURL: URL
        let startTime: CMTime   // raw camera time of first frame in this file
        let endTime: CMTime     // raw camera time of last appended frame
    }

    // MARK: - Private state — writer

    private var currentWriter: AVAssetWriter?
    private var currentWriterInput: AVAssetWriterInput?
    private var isWritingToMainFile = true

    private var currentFileURL: URL
    private var alternateFileURL: URL
    private let fileManager = FileManager.default

    // Raw camera timestamp of the first frame written to the current file.
    private var fileStartTime: CMTime?
    // Raw camera timestamp of the most-recently appended frame.
    private var lastAppendedTime: CMTime = .zero

    private var frameCount: Int = 0          // frames in current file
    private var globalFrameCount: Int = 0    // total frames ever appended

    private var isPaused = false

    // MARK: - Private state — segments

    /// Up to two segments kept alive for the rolling window.
    /// [0] = older half, [1] = newer half (current).
    private var segments: [Segment] = []

    // MARK: - Private state — pause / playback

    /// AVMutableComposition built once at pause time.
    /// Covers up to `maxDurationSeconds` of footage from the two segments.
    private(set) var pausedComposition: AVMutableComposition?

    /// The raw-camera CMTime corresponding to t=0 in the composition.
    private(set) var pausedCompositionStartTime: CMTime = .zero
    
    /// The composition CMTime corresponding to the pause point —
    /// i.e. the last frame that was actually displayed to the user.
    /// Playback and looping must not go beyond this time.
    private(set) var pausedCompositionEndTime: CMTime = .zero

    /// Total number of frames in the composition (for the scrub window).
    private(set) var pausedFrameCount: Int = 0

    // MARK: - Private state — timestamps

    /// Raw camera presentation timestamps, one per global frame.
    /// Used to convert a frame index to a composition seek time.
    private var frameTimestamps: [CMTime] = []
    private let timestampLock = NSLock()
    private let maxTimestampCount: Int

    // MARK: - Private state — live-delay cache

    private var recentFramesCache: [UIImage] = []
    private var cacheStartIndex: Int = 0
    private let cacheLock = NSLock()
    private let maxCacheSize: Int

    // MARK: - Configuration

    private let maxDurationSeconds: Int
    /// Half the window — each file holds this many seconds before rotation.
    private let halfWindowSeconds: Int
    private let delaySeconds: Int
    let fps: Int
    private let writeQueue: DispatchQueue

    /// Shared CIContext from the caller — avoids per-frame GPU context alloc.
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
        self.currentFileURL   = tmp.appendingPathComponent("buffer_main.mp4")
        self.alternateFileURL = tmp.appendingPathComponent("buffer_alt.mp4")

        print("📁 VideoFileBuffer init — window: \(maxDurationSeconds)s, " +
              "halfWindow: \(halfWindowSeconds)s, fps: \(fps), " +
              "cacheSize: \(maxCacheSize)")
    }

    // MARK: - Writer setup

    func startWriting(videoSettings: [String: Any], isInitialStart: Bool = false) throws {
        let fileURL = isWritingToMainFile ? currentFileURL : alternateFileURL
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
            timestampLock.unlock()

            cacheLock.lock()
            recentFramesCache.removeAll()
            cacheStartIndex   = 0
            globalFrameCount  = 0
            cacheLock.unlock()

            segments.removeAll()
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

        // ── First frame of this file ──────────────────────────────────────
        if fileStartTime == nil {
            fileStartTime = presentationTime
        }

        // ── Half-window rotation ──────────────────────────────────────────
        let elapsed = CMTimeGetSeconds(presentationTime - (fileStartTime ?? .zero))
        if elapsed >= Double(halfWindowSeconds) {
            rotateToAlternateFile(
                videoSettings: writerInput.outputSettings as? [String: Any],
                segmentEndTime: presentationTime)
            completion(false)
            return
        }

        guard writerInput.isReadyForMoreMediaData else {
            completion(false)
            return
        }

        // ── Normalise timestamp to file-local time ────────────────────────
        let normalizedTime = CMTimeSubtract(presentationTime, fileStartTime ?? .zero)
        var timing = CMSampleTimingInfo(
            duration:               CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp:  normalizedTime,
            decodeTimeStamp:        .invalid)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let formatDesc  = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            completion(false)
            return
        }

        var newSB: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator:        kCFAllocatorDefault,
            imageBuffer:      pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming:     &timing,
            sampleBufferOut:  &newSB)

        guard status == noErr, let normalizedSB = newSB else {
            completion(false)
            return
        }

        let ok = writerInput.append(normalizedSB)
        if ok {
            frameCount       += 1
            globalFrameCount += 1
            lastAppendedTime  = presentationTime

            timestampLock.lock()
            frameTimestamps.append(presentationTime)
            if frameTimestamps.count > maxTimestampCount {
                frameTimestamps.removeFirst()
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

        // Scale down to 800 px on the long edge for memory efficiency.
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

    private func rotateToAlternateFile(videoSettings: [String: Any]?,
                                       segmentEndTime: CMTime) {
        let oldURL       = isWritingToMainFile ? currentFileURL : alternateFileURL
        let oldStartTime = fileStartTime ?? .zero

        // Save a completed-segment record.
        // We keep only the two most recent segments (rolling window).
        let completedSegment = Segment(fileURL:   oldURL,
                                       startTime: oldStartTime,
                                       endTime:   segmentEndTime)
        if segments.count >= 2 {
            // The oldest segment's file is about to be overwritten — safe to drop.
            segments.removeFirst()
        }
        segments.append(completedSegment)

        // Prune timestamps so only the two-segment window survives.
        pruneTimestampsToWindow(windowStart: segments.first?.startTime ?? oldStartTime)

        currentWriterInput?.markAsFinished()
        let oldWriter      = currentWriter
        let oldWriterInput = currentWriterInput   // keep alive until finishWriting returns
        currentWriter      = nil
        currentWriterInput = nil

        isWritingToMainFile.toggle()

        if let settings = videoSettings {
            do {
                try startWriting(videoSettings: settings, isInitialStart: false)
            } catch {
                print("❌ Failed to start rotated writer: \(error)")
            }
        }

        oldWriter?.finishWriting { [weak self] in
            _ = oldWriterInput  // retain until here
            if oldWriter?.status == .completed {
                print("✅ Segment finalized: \(oldURL.lastPathComponent)")
            } else {
                print("⚠️ Segment finalize error: \(oldWriter?.error?.localizedDescription ?? "?")")
            }
            self?.cleanupExpiredSegmentFiles()
        }
    }

    /// Remove any temp files that no longer correspond to a live segment.
    private func cleanupExpiredSegmentFiles() {
        let activeURLs = Set(segments.map { $0.fileURL })
        for candidate in [currentFileURL, alternateFileURL] {
            if !activeURLs.contains(candidate) {
                // Only remove if this file isn't the *current* write target.
                let isCurrent = (isWritingToMainFile && candidate == currentFileURL) ||
                                (!isWritingToMainFile && candidate == alternateFileURL)
                if !isCurrent {
                    try? fileManager.removeItem(at: candidate)
                }
            }
        }
    }

    /// Trim frameTimestamps so they only cover `windowStart` onwards.
    private func pruneTimestampsToWindow(windowStart: CMTime) {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        // Binary search for the first timestamp >= windowStart.
        var lo = 0, hi = frameTimestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if CMTimeCompare(frameTimestamps[mid], windowStart) < 0 { lo = mid + 1 }
            else { hi = mid }
        }
        if lo > 0 { frameTimestamps.removeFirst(lo) }
    }

    // MARK: - Pause

    /// Finalise the current write, build the playback composition, and call
    /// back with the ready-to-use AVPlayerItem (on the main queue).
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
        guard frameCount >= minimumFrames else {
            print("⚠️ pauseRecording: only \(frameCount) frames, need \(minimumFrames)")
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }

        isPaused = true
        let segEndTime   = lastAppendedTime
        let segStartTime = fileStartTime ?? .zero
        let currentURL   = isWritingToMainFile ? currentFileURL : alternateFileURL

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
            if self.segments.count >= 2 { self.segments.removeFirst() }
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

                // ── NEW: calculate the composition time of the pause point ──
                // segEndTime is the raw camera time of the last appended frame.
                // The pause point is (segEndTime - delaySeconds worth of frames)
                // mapped into composition time.
                if let comp = comp {
                    let pausePointRaw = CMTimeSubtract(
                        segEndTime,
                        CMTime(seconds: Double(self.delaySeconds), preferredTimescale: 600))
                    let pausePointCompositionTime = CMTimeSubtract(pausePointRaw, compStartTime)
                    // Clamp to valid composition range.
                    self.pausedCompositionEndTime = CMTimeMinimum(
                        CMTimeMaximum(pausePointCompositionTime, .zero),
                        comp.duration)
                    print("⏸ Composition end time (pause point): " +
                          "\(CMTimeGetSeconds(self.pausedCompositionEndTime))s of " +
                          "\(CMTimeGetSeconds(comp.duration))s total")
                }

                let item = comp.map { AVPlayerItem(asset: $0) }
                DispatchQueue.main.async { completion(item, comp) }
            }
        }
    }
    
    // MARK: - Composition building

    /// Stitch up to two segments into one AVMutableComposition covering at
    /// most `maxDurationSeconds` of the most-recent footage.
    ///
    /// Returns (composition, rawCameraTimeOfCompositionStart, frameCount).
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

            let segRawDuration  = CMTimeSubtract(seg.endTime, seg.startTime)
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
                insertCursor = CMTimeAdd(insertCursor, CMTimeSubtract(fileDuration, clipStartInFile))
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

    /// Convert a global frame index to a CMTime suitable for
    /// `player.seek(to:)` against the paused composition.
    func compositionTime(forFrameIndex index: Int) -> CMTime? {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        guard index >= 0 && index < frameTimestamps.count else { return nil }
        let raw = frameTimestamps[index]
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

    func getCurrentFileURL() -> URL? {
        isWritingToMainFile ? currentFileURL : alternateFileURL
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
        timestampLock.unlock()

        cacheLock.lock()
        recentFramesCache.removeAll()
        cacheStartIndex  = 0
        globalFrameCount = 0
        cacheLock.unlock()

        segments.removeAll()

        for url in [currentFileURL, alternateFileURL] {
            try? fileManager.removeItem(at: url)
        }

        currentWriter      = nil
        currentWriterInput = nil
        frameCount         = 0
        fileStartTime      = nil
        isPaused           = false
        pausedComposition  = nil
        pausedCompositionStartTime = .zero
        pausedFrameCount   = 0
    }

    deinit { cleanup() }
}
