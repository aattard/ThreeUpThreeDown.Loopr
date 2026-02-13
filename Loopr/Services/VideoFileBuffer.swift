import Foundation
import AVFoundation
import UIKit

class VideoFileBuffer {
    
    // MARK: - Properties
    private var currentWriter: AVAssetWriter?
    private var currentWriterInput: AVAssetWriterInput?
    private var currentFileURL: URL?
    private var alternateFileURL: URL?
    private var previousFileURL: URL?
    private var pausedFileURL: URL?

    private var isWritingToMainFile = true
    private var frameCount: Int = 0
    private var globalFrameCount: Int = 0
    private var startTime: CMTime?
    private var fileStartTime: CMTime?  // NEW: Track when this file started
    private var lastAppendedTime: CMTime = .zero
    private var isPaused: Bool = false
    
    private let maxDurationSeconds: Int
    private let fps: Int = 30
    private let fileManager = FileManager.default
    private let writeQueue: DispatchQueue
    
    // Frame metadata tracking for scrubbing - NEVER clear on rotation
    private var frameTimestamps: [CMTime] = []
    private let timestampLock = NSLock()
    
    // Ring buffer for frame cache - NEVER clear on rotation
    private var recentFramesCache: [UIImage] = []
    private var cacheStartIndex: Int = 0
    private let cacheLock = NSLock()
    private let maxCacheSize: Int
    
    // MARK: - Initialization
    init(maxDurationSeconds: Int, writeQueue: DispatchQueue) {
        self.maxDurationSeconds = maxDurationSeconds
        self.writeQueue = writeQueue
        
        // Keep full duration in cache
        self.maxCacheSize = maxDurationSeconds * 30
        
        let tempDir = fileManager.temporaryDirectory
        self.currentFileURL = tempDir.appendingPathComponent("buffer_main.mp4")
        self.alternateFileURL = tempDir.appendingPathComponent("buffer_alt.mp4")
        
        print("📁 Buffer files: \(currentFileURL!.path)")
        print("💾 Cache size: \(maxCacheSize) frames (~\(maxDurationSeconds)s)")
    }
    
    // MARK: - Writer Setup
    func startWriting(videoSettings: [String: Any], isInitialStart: Bool = false) throws {
        let fileURL = isWritingToMainFile ? currentFileURL! : alternateFileURL!
        
        try? fileManager.removeItem(at: fileURL)
        
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = true
        writerInput.transform = .identity
        
        if writer.canAdd(writerInput) {
            writer.add(writerInput)
        } else {
            throw NSError(domain: "VideoFileBuffer", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
        }
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        self.currentWriter = writer
        self.currentWriterInput = writerInput
        self.frameCount = 0
        self.startTime = nil
        self.fileStartTime = nil  // Reset for new file
        self.isPaused = false
        self.pausedFileURL = nil
        
        if isInitialStart {
            timestampLock.lock()
            frameTimestamps.removeAll()
            timestampLock.unlock()
            
            cacheLock.lock()
            recentFramesCache.removeAll()
            cacheStartIndex = 0
            globalFrameCount = 0
            cacheLock.unlock()
            
            print("✅ Started writing to: \(fileURL.lastPathComponent) (INITIAL - globalFrame: 0)")
        } else {
            print("✅ Rotated to: \(fileURL.lastPathComponent) (globalFrame: \(globalFrameCount), cache preserved)")
        }
    }
    
    // MARK: - Frame Appending
    func appendFrame(sampleBuffer: CMSampleBuffer, completion: @escaping (Bool) -> Void) {
        guard let writerInput = currentWriterInput else {
            completion(false)
            return
        }
        
        guard let writer = currentWriter else {
            completion(false)
            return
        }
        
        guard writer.status == .writing else {
            print("❌ appendFrame: Writer status is \(writer.status.rawValue), not writing")
            completion(false)
            return
        }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Track when this file started (for elapsed time calculation)
        if startTime == nil {
            startTime = presentationTime
            fileStartTime = presentationTime
            print("✅ Set startTime for new file: \(CMTimeGetSeconds(presentationTime))s")
        }
        
        let elapsedTime = CMTimeGetSeconds(presentationTime - (startTime ?? .zero))
        
        // Check if we need to rotate files
        if elapsedTime >= Double(maxDurationSeconds) {
            print("🔄 Frame \(globalFrameCount) at \(String(format: "%.2f", elapsedTime))s triggered rotation (max: \(maxDurationSeconds)s)")
            
            // NEW: Just drop this frame and let rotation happen cleanly
            // The next frame will be the first frame of the new file
            rotateToAlternateFile(videoSettings: writerInput.outputSettings as? [String: Any])
            
            completion(false)
            return
        }
        
        if writerInput.isReadyForMoreMediaData {
            // CRITICAL FIX: Normalize timestamp relative to this file's start
            let normalizedTime = CMTimeSubtract(presentationTime, fileStartTime ?? .zero)
            
            // Create new sample buffer with normalized timestamp
            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: normalizedTime,
                decodeTimeStamp: .invalid
            )
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                print("❌ Failed to get pixel buffer or format description at globalFrame \(globalFrameCount)")
                completion(false)
                return
            }
            
            var newSampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &newSampleBuffer
            )
            
            guard status == noErr, let normalizedSampleBuffer = newSampleBuffer else {
                print("❌ Failed to create normalized sample buffer, status: \(status) at globalFrame \(globalFrameCount)")
                completion(false)
                return
            }
            
            let success = writerInput.append(normalizedSampleBuffer)
            
            if success {
                frameCount += 1
                globalFrameCount += 1
                lastAppendedTime = presentationTime
                
                timestampLock.lock()
                frameTimestamps.append(presentationTime)
                
                if frameTimestamps.count > maxCacheSize {
                    frameTimestamps.removeFirst()
                }
                timestampLock.unlock()
                
                cacheFrameForDisplay(sampleBuffer: sampleBuffer)
                
                if globalFrameCount % 300 == 0 {
                    print("📹 Frames written: \(globalFrameCount) (~\(globalFrameCount/30)s) [elapsed: \(Int(elapsedTime))s, normalized: \(String(format: "%.1f", CMTimeGetSeconds(normalizedTime)))s]")
                    
                    timestampLock.lock()
                    let timestampCount = frameTimestamps.count
                    timestampLock.unlock()
                    
                    cacheLock.lock()
                    let cacheCount = recentFramesCache.count
                    cacheLock.unlock()
                    
                    print("💾 Buffer status - Cache: \(cacheCount)/\(maxCacheSize) frames, Timestamps: \(timestampCount)/\(maxCacheSize)")
                }
            } else {
                // More detailed error logging
                print("❌ writerInput.append() returned false at globalFrame \(globalFrameCount)")
                print("   Writer status: \(writer.status.rawValue)")
                print("   Writer error: \(writer.error?.localizedDescription ?? "none")")
                print("   Normalized time: \(CMTimeGetSeconds(normalizedTime))s")
                print("   Presentation time: \(CMTimeGetSeconds(presentationTime))s")
                print("   File start time: \(CMTimeGetSeconds(fileStartTime ?? .zero))s")
            }
            
            // CRITICAL FIX: Always call completion, even on failure
            completion(success)
            
        } else {
            // Log when writer isn't ready (after frame 1500)
            if globalFrameCount >= 1500 {
                print("⚠️ Writer not ready for data at globalFrame \(globalFrameCount), status: \(writer.status.rawValue)")
            }
            completion(false)
        }
    }
    
    // Cache frames in memory for live playback
    private func cacheFrameForDisplay(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        // Downscale for memory efficiency
        let originalImage = UIImage(cgImage: cgImage)
        let maxDimension: CGFloat = 800
        let scale = min(maxDimension / originalImage.size.width, maxDimension / originalImage.size.height, 1.0)
        let newSize = CGSize(width: originalImage.size.width * scale, height: originalImage.size.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        originalImage.draw(in: CGRect(origin: .zero, size: newSize))
        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let finalImage = scaledImage else { return }
        
        cacheLock.lock()
        recentFramesCache.append(finalImage)
        
        // Maintain ring buffer
        if recentFramesCache.count > maxCacheSize {
            recentFramesCache.removeFirst()
            cacheStartIndex += 1
        }
        cacheLock.unlock()
    }
    
    // Get frame from memory cache with ring buffer indexing
    func getRecentFrame(at globalIndex: Int) -> UIImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Convert global index to cache index
        let cacheIndex = globalIndex - cacheStartIndex
        
        guard cacheIndex >= 0 && cacheIndex < recentFramesCache.count else {
            return nil
        }
        
        return recentFramesCache[cacheIndex]
    }
    
    func getRecentFrameCount() -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return recentFramesCache.count
    }
    
    // MARK: - File Rotation
    private func rotateToAlternateFile(videoSettings: [String: Any]?) {
        print("🔄 ═══════════════════════════════════════════════")
        print("🔄 ROTATION START at globalFrame \(globalFrameCount) (~\(globalFrameCount/30)s)")
        print("🔄 Old file: \(isWritingToMainFile ? currentFileURL?.lastPathComponent ?? "none" : alternateFileURL?.lastPathComponent ?? "none")")
        
        // Save current file as previous for potential scrubbing
        previousFileURL = isWritingToMainFile ? currentFileURL : alternateFileURL
        
        currentWriterInput?.markAsFinished()
        
        let oldWriter = currentWriter
        let oldWriterInput = currentWriterInput
        
        // Clear current writer references immediately
        self.currentWriter = nil
        self.currentWriterInput = nil
        
        // Switch to alternate file
        isWritingToMainFile.toggle()
        
        print("🔄 New file: \(isWritingToMainFile ? currentFileURL?.lastPathComponent ?? "none" : alternateFileURL?.lastPathComponent ?? "none")")
        
        // Start new writer synchronously (we're already on writeQueue)
        if let settings = videoSettings {
            do {
                try startWriting(videoSettings: settings, isInitialStart: false)
                print("✅ New writer ready at globalFrame \(globalFrameCount)")
            } catch {
                print("❌ Failed to start new writer: \(error)")
            }
        }
        
        print("🔄 ═══════════════════════════════════════════════")
        
        // Finish old writer in background
        oldWriter?.finishWriting { [weak self] in
            guard let self = self else { return }
            if oldWriter?.status == .completed {
                print("✅ Finished writing previous file: \(self.previousFileURL?.lastPathComponent ?? "")")
            } else {
                print("⚠️ Previous file write failed: \(oldWriter?.error?.localizedDescription ?? "unknown")")
            }
        }
    }
    
    // MARK: - Pause/Resume Support
    func pauseRecording(completion: @escaping (URL?) -> Void) {
        guard !isPaused, let writer = currentWriter else {
            completion(pausedFileURL)
            return
        }
        
        isPaused = true
        pausedFileURL = getCurrentFileURL()
        
        print("⏸️ Pausing recording, finishing writer...")
        currentWriterInput?.markAsFinished()
        
        writer.finishWriting { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            if writer.status == .completed {
                print("✅ Writer finished for pause, file ready: \(self.pausedFileURL?.lastPathComponent ?? "")")
                completion(self.pausedFileURL)
            } else {
                print("❌ Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                completion(nil)
            }
        }
    }
    
    // MARK: - Frame Extraction for Scrubbing (WHEN PAUSED)
    func extractFrameFromFile(at frameIndex: Int, completion: @escaping (UIImage?) -> Void) {
        guard let fileURL = pausedFileURL else {
            print("❌ No paused file available for scrubbing")
            completion(nil)
            return
        }
        
        // First try cache for recent frames
        if let cachedImage = getRecentFrame(at: frameIndex) {
            completion(cachedImage)
            return
        }
        
        // Fall back to file extraction for older frames
        writeQueue.async {
            // Get timestamp for frame
            self.timestampLock.lock()
            guard frameIndex < self.frameTimestamps.count else {
                self.timestampLock.unlock()
                completion(nil)
                return
            }
            let timestamp = self.frameTimestamps[frameIndex]
            self.timestampLock.unlock()
            
            // Extract frame using AVAssetImageGenerator
            let asset = AVAsset(url: fileURL)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            imageGenerator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            imageGenerator.appliesPreferredTrackTransform = true
            
            do {
                let cgImage = try imageGenerator.copyCGImage(at: timestamp, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    completion(image)
                }
            } catch {
                print("❌ Frame extraction error at index \(frameIndex): \(error)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    
    // MARK: - Current State Access
    func getCurrentFrameCount() -> Int {
        return globalFrameCount
    }
    
    func getFrameTimestamps() -> [CMTime] {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return frameTimestamps
    }
    
    func getCurrentFileURL() -> URL? {
        return isWritingToMainFile ? currentFileURL : alternateFileURL
    }
    
    func getPausedFileURL() -> URL? {
        return pausedFileURL
    }
    
    // MARK: - Cleanup
    func stopWriting(completion: @escaping () -> Void) {
        guard let writer = currentWriter else {
            cleanup()
            completion()
            return
        }
        
        // Only finish if not already finished
        if writer.status == .writing {
            currentWriterInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                print("✅ Stopped writing to file")
                self?.cleanup()
                completion()
            }
        } else {
            cleanup()
            completion()
        }
    }
    
    func cleanup() {
        timestampLock.lock()
        frameTimestamps.removeAll()
        timestampLock.unlock()
        
        cacheLock.lock()
        recentFramesCache.removeAll()
        cacheStartIndex = 0
        globalFrameCount = 0
        cacheLock.unlock()
        
        if let url = currentFileURL {
            try? fileManager.removeItem(at: url)
        }
        if let url = alternateFileURL {
            try? fileManager.removeItem(at: url)
        }
        
        currentWriter = nil
        currentWriterInput = nil
        frameCount = 0
        startTime = nil
        isPaused = false
        pausedFileURL = nil
    }
    
    deinit {
        cleanup()
    }
}

