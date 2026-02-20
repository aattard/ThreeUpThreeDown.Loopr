import Foundation
import AVFoundation
import Photos

enum VideoExportError: LocalizedError {
    case missingBuffer
    case permissionDenied
    case exportFailed
    case saveFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .missingBuffer: return "Video buffer or composition is missing."
        case .permissionDenied: return "Photos permission is required to save clips."
        case .exportFailed: return "Could not create the video clip."
        case .saveFailed(let msg): return "Failed to save to Photos: \(msg)"
        }
    }
}

final class VideoExportManager {
    
    /// Exports the specified frame range to a temporary file and saves it to the user's Photo Library.
    static func exportAndSaveClip(
        from buffer: VideoFileBuffer,
        startIndex: Int,
        endIndex: Int,
        isFrontCamera: Bool,
        rotationAngle: CGFloat,
        fps: Int,
        completion: @escaping (Result<Void, VideoExportError>) -> Void
    ) {
        // 1. Check Photos permission first
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status != .denied && status != .restricted else {
            completion(.failure(.permissionDenied))
            return
        }
        
        // 2. Export the video
        createClipVideo(from: buffer, startIndex: startIndex, endIndex: endIndex, isFrontCamera: isFrontCamera, rotationAngle: rotationAngle, fps: fps) { url in
            guard let url = url else {
                completion(.failure(.exportFailed))
                return
            }
            
            // 3. Save to Photo Library
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                // Always clean up the temporary file
                try? FileManager.default.removeItem(at: url)
                
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(.saveFailed(error?.localizedDescription ?? "Unknown error")))
                    }
                }
            }
        }
    }
    
    private static func createClipVideo(
        from buffer: VideoFileBuffer,
        startIndex: Int,
        endIndex: Int,
        isFrontCamera: Bool,
        rotationAngle: CGFloat,
        fps: Int,
        completion: @escaping (URL?) -> Void
    ) {
        guard let comp = buffer.pausedComposition else {
            completion(nil)
            return
        }

        let startTime = buffer.compositionTime(forFrameIndex: startIndex) ?? .zero
        let endTime = buffer.compositionTime(forFrameIndex: endIndex) ?? buffer.pausedCompositionEndTime
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("LooprClip-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil)
            return
        }
        
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        exporter.timeRange = timeRange
        exporter.shouldOptimizeForNetworkUse = true

        // Enforce orientation/mirroring
        if let videoTrack = comp.tracks(withMediaType: .video).first {
            let natural = videoTrack.naturalSize
            let transform = VideoPlaybackHelpers.exportTransformForRotationAngle(rotationAngle, naturalSize: natural, isFrontCamera: isFrontCamera)

            let vc = AVMutableVideoComposition()
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))

            // Render size: rotate swaps width/height.
            let renderSize: CGSize
            if Int(rotationAngle) == 90 || Int(rotationAngle) == 270 {
                renderSize = CGSize(width: natural.height, height: natural.width)
            } else {
                renderSize = natural
            }
            vc.renderSize = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))

            let instruction = AVMutableVideoCompositionInstruction()
            // Ensure the instruction time range fully covers the asset
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: .zero)

            instruction.layerInstructions = [layerInstruction]
            vc.instructions = [instruction]

            exporter.videoComposition = vc
        }

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    completion(url)
                } else {
                    print("Export failed: \(exporter.error?.localizedDescription ?? "Unknown")")
                    completion(nil)
                }
            }
        }
    }
}
