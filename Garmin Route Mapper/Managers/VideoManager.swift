//
//  VideoManager.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import AVFoundation
import AppKit
import Combine

/// Manages video playback and frame extraction
@MainActor
class VideoManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var currentTime: CMTime = .zero
    @Published var duration: CMTime = .zero
    @Published var isPlaying = false
    @Published var frameImages: [NSImage] = []
    @Published var frameExtractionProgress: Double = 0.0
    
    private var timeObserver: Any?
    nonisolated(unsafe) private var cancellables = Set<AnyCancellable>()
    
    /// Loads a video from URL and sets up playback
    func loadVideo(url: URL) {
        // Clean up previous player
        cleanup()
        
        // Validate URL is accessible (warn if file doesn't exist, but continue for remote URLs)
        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            // File doesn't exist - warn but continue (may be a remote URL)
            print("Warning: Video file may not be accessible: \(url)")
        }
        
        // Create AVAsset with proper configuration to avoid QuickTime factory warnings
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        
        // Validate asset has playable tracks before creating player item
        Task {
            do {
                // Check if asset is readable
                let isReadable = try await asset.load(.isReadable)
                guard isReadable else {
                    await MainActor.run {
                        print("Error: Video file is not readable: \(url.lastPathComponent)")
                    }
                    return
                }
                
                // Load tracks to ensure video track exists
                let allTracks = try await asset.load(.tracks)
                let videoTracks = allTracks.filter { $0.mediaType == .video }
                guard !videoTracks.isEmpty else {
                    await MainActor.run {
                        print("Error: No video tracks found in file: \(url.lastPathComponent)")
                    }
                    return
                }
                
                // Now create player item after validation
                await MainActor.run {
                    let playerItem = AVPlayerItem(asset: asset)
                    let newPlayer = AVPlayer(playerItem: playerItem)
                    self.player = newPlayer
                    
                    // Observe duration
                    Task {
                        do {
                            let duration = try await asset.load(.duration)
                            await MainActor.run {
                                self.duration = duration
                            }
                        } catch {
                            // If duration load fails, try loading from playerItem
                            let duration = try? await playerItem.asset.load(.duration)
                            if let duration = duration {
                                await MainActor.run {
                                    self.duration = duration
                                }
                            }
                        }
                    }
                    
                    // Observe time changes (only after player is set)
                    self.setupTimeObserver(playerItem: playerItem)
                    
                    // Observe playback status
                    playerItem.publisher(for: \.status)
                        .sink { [weak self] status in
                            Task { @MainActor in
                                guard let self = self else { return }
                                if status == .readyToPlay {
                                    // Video is ready - ensure player is properly configured
                                    if self.player != nil {
                                        // Player is ready for playback
                                    }
                                } else if status == .failed {
                                    // Handle playback failure
                                    if let error = playerItem.error {
                                        print("Playback error: \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                        .store(in: &self.cancellables)
                }
            } catch {
                await MainActor.run {
                    print("Error loading video asset: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Seeks to a specific time in the video
    func seek(to time: CMTime) {
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    /// Plays the video
    func play() {
        player?.play()
        isPlaying = true
    }
    
    /// Pauses the video
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    /// Extracts frames from the video for OCR processing
    nonisolated func extractFrames(
        url: URL,
        frameInterval: CMTime = CMTime(value: 1, timescale: 30), // 30 FPS
        progressHandler: @escaping (Double, NSImage) -> Void
    ) async throws {
        // Create asset with proper configuration
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        
        // Check if asset is readable
        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw VideoError.invalidDuration
        }
        
        // Load tracks to ensure video track exists
        let allTracks = try await asset.load(.tracks)
        let videoTracks = allTracks.filter { $0.mediaType == .video }
        guard !videoTracks.isEmpty else {
            throw VideoError.frameExtractionFailed
        }
        
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.appliesPreferredTrackTransform = true
        
        guard let duration = try? await asset.load(.duration) else {
            throw VideoError.invalidDuration
        }
        
        let durationSeconds = CMTimeGetSeconds(duration)
        let frameRate = 1.0 / CMTimeGetSeconds(frameInterval)
        let totalFrames = Int(durationSeconds * frameRate)
        
        // Clear frames on main actor
        await MainActor.run {
            self.frameImages = []
            self.frameExtractionProgress = 0.0
        }
        
        var allExtractedFrames: [NSImage] = []
        allExtractedFrames.reserveCapacity(totalFrames)
        
        // Process frames sequentially (batch processing can cause memory issues)
        for frameIndex in 0..<totalFrames {
            let time = CMTimeMultiplyByFloat64(frameInterval, multiplier: Float64(frameIndex))
            
            let extractedImage: NSImage?
            do {
                let cgImage = try await imageGenerator.image(at: time).image
                extractedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            } catch {
                // Continue with next frame if this one fails
                print("Failed to extract frame \(frameIndex): \(error.localizedDescription)")
                extractedImage = nil
            }
            
            // Append the extracted image (or placeholder)
            allExtractedFrames.append(extractedImage ?? NSImage())
            
            let progress = Double(frameIndex + 1) / Double(totalFrames)
            
            // Update UI on main actor periodically (every 10 frames or last frame)
            if frameIndex % 10 == 0 || frameIndex == totalFrames - 1 {
                await MainActor.run {
                    self.frameExtractionProgress = progress
                }
                if let image = extractedImage {
                    progressHandler(progress, image)
                }
            }
        }
        
        // Update final state on main actor (capture frames array to avoid concurrency warning)
        let finalFrames = allExtractedFrames
        await MainActor.run {
            self.frameImages = finalFrames
            self.frameExtractionProgress = 1.0
        }
    }
    
    /// Sets up time observer to track playback position
    private func setupTimeObserver(playerItem: AVPlayerItem) {
        // Remove existing observer first
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        // Only set up observer if player is valid
        guard let player = player else { return }
        
        let interval = CMTime(value: 1, timescale: 30) // Update 30 times per second
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            // Closure runs on main queue, so we can safely access MainActor-isolated properties
            Task { @MainActor in
                self.currentTime = time
            }
        }
    }
    
    /// Cleans up resources
    func cleanup() {
        // Remove time observer
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        // Cancel all Combine subscriptions
        cancellables.removeAll()
        
        // Pause and clear player
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        
        // Clear frame images
        frameImages = []
        frameExtractionProgress = 0.0
        currentTime = .zero
        duration = .zero
        isPlaying = false
    }
    
    deinit {
        // Minimal cleanup: cancel all subscriptions
        // Note: AVPlayer and time observer cleanup will happen when player is deallocated
        // The main cleanup() should be called explicitly before deallocation when possible
        // We can safely remove cancellables here since Set.removeAll() is thread-safe for deallocation
        cancellables = []
    }
}

enum VideoError: Error, LocalizedError {
    case invalidDuration
    case frameExtractionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "Could not determine video duration"
        case .frameExtractionFailed:
            return "Failed to extract frames from video"
        }
    }
}

