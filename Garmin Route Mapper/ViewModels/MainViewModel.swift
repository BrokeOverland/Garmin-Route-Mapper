//
//  MainViewModel.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import AVFoundation
import SwiftUI
import Combine

/// Main ViewModel coordinating all components
@MainActor
class MainViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var videoItems: [VideoItem] = []
    @Published var selectedVideoItem: VideoItem?
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0.0
    @Published var currentProcessingVideo: String?
    @Published var isSmoothingEnabled = false
    @Published var smoothingWindow: Int = 5
    @Published var errorMessage: String?
    @Published var showError = false
    
    // MARK: - OCR Diagnostics
    @Published var currentOCRImage: NSImage?
    @Published var currentOCRRegion: OCRRegion?
    @Published var croppedOCRImage: NSImage?
    
    // MARK: - Managers
    
    private let videoManager = VideoManager()
    private let ocrManager = OCRManager()
    private let gpsProcessor = GPSProcessor()
    private let exportManager = ExportManager()
    let mapViewModel = MapViewModel()
    
    // MARK: - Computed Properties
    
    var videoPlayer: VideoManager { videoManager }
    var mapView: MapViewModel { mapViewModel }
    
    // MARK: - Video Management
    
    /// Adds video files via drag and drop
    func addVideos(urls: [URL]) {
        let newItems = urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map { VideoItem(url: $0) }
        
        videoItems.append(contentsOf: newItems)
        
        // Auto-select first video if none selected
        if selectedVideoItem == nil, let first = videoItems.first {
            selectedVideoItem = first
            loadSelectedVideo()
        }
    }
    
    /// Removes a video from the list
    func removeVideo(_ item: VideoItem) {
        videoItems.removeAll { $0.id == item.id }
        if selectedVideoItem?.id == item.id {
            selectedVideoItem = videoItems.first
            loadSelectedVideo()
        }
    }
    
    /// Selects a video and loads it for playback
    func selectVideo(_ item: VideoItem) {
        selectedVideoItem = item
        loadSelectedVideo()
    }
    
    /// Loads the selected video for playback
    private func loadSelectedVideo() {
        guard let item = selectedVideoItem else {
            videoManager.cleanup()
            mapViewModel.clearRoute()
            return
        }
        
        videoManager.loadVideo(url: item.url)
        
        // Update map with GPS data if available
        if item.hasGPSData {
            let processedPoints = gpsProcessor.processGPSPoints(
                item.gpsPoints,
                interpolate: true,
                smooth: isSmoothingEnabled,
                smoothingWindow: smoothingWindow
            )
            mapViewModel.updateRoute(from: processedPoints)
        } else {
            mapViewModel.clearRoute()
        }
    }
    
    // MARK: - GPS Extraction
    
    /// Processes all videos to extract GPS data
    func processAllVideos() async {
        guard !isProcessing else { return }
        
        isProcessing = true
        processingProgress = 0.0
        
        for index in 0..<videoItems.count {
            var item = videoItems[index]
            currentProcessingVideo = item.filename
            
            do {
                // Update status
                item.extractionStatus = .extracting
                videoItems[index] = item
                
                // Extract GPS from video
                try await extractGPSFromVideo(item: &item)
                
                // Process with interpolation and smoothing
                let processedPoints = gpsProcessor.processGPSPoints(
                    item.gpsPoints,
                    interpolate: true,
                    smooth: isSmoothingEnabled,
                    smoothingWindow: smoothingWindow
                )
                item.gpsPoints = processedPoints
                
                // Update status
                if item.hasGPSData {
                    item.extractionStatus = .completed
                } else {
                    item.extractionStatus = .failed
                    errorMessage = "No GPS data found in \(item.filename)"
                    showError = true
                }
                
                videoItems[index] = item
                
                // Update progress
                processingProgress = Double(index + 1) / Double(videoItems.count)
                
                // Update map if this is the selected video
                if item.id == selectedVideoItem?.id {
                    mapViewModel.updateRoute(from: processedPoints)
                }
                
            } catch {
                item.extractionStatus = .error
                item.gpsPoints = []
                videoItems[index] = item
                errorMessage = "Error processing \(item.filename): \(error.localizedDescription)"
                showError = true
            }
        }
        
        isProcessing = false
        currentProcessingVideo = nil
        processingProgress = 1.0
        
        // Clear diagnostics after processing completes (optional - comment out to keep last frame visible)
        // currentOCRImage = nil
        // currentOCRRegion = nil
        // croppedOCRImage = nil
    }
    
    /// Extracts GPS data from a single video
    private func extractGPSFromVideo(item: inout VideoItem) async throws {
        print("Starting frame extraction for: \(item.filename)")
        
        // Extract frames from video - frames are stored in videoManager.frameImages
        try await videoManager.extractFrames(url: item.url) { progress, _ in
            // Update progress during frame extraction (50% of total progress)
            Task { @MainActor in
                // Frame extraction is 50% of the work, OCR is the other 50%
                self.processingProgress = progress * 0.5
            }
        }
        
        print("Frame extraction complete. Extracted \(videoManager.frameImages.count) frames")
        
        // Use frames accumulated in videoManager.frameImages
        // Process every frame for GPS extraction
        let framesToProcess = videoManager.frameImages.enumerated().map { (index, image) in
            (index, image)
        }
        
        print("Starting OCR processing for \(framesToProcess.count) frames...")
        
        // Extract GPS using OCR with progress tracking
        var ocrProgress = 0.0
        var extractedPoints: [GPSPoint] = []
        
        // Process OCR in chunks to update progress
        let chunkSize = max(1, framesToProcess.count / 10) // Update progress ~10 times
        for chunkStart in stride(from: 0, to: framesToProcess.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, framesToProcess.count)
            let chunk = Array(framesToProcess[chunkStart..<chunkEnd])
            
            // Setup diagnostics callback to update UI
            let diagnosticsCallback: OCRDiagnosticsCallback = { [weak self] originalImage, region, croppedImage in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.currentOCRImage = originalImage
                    self.currentOCRRegion = region
                    self.croppedOCRImage = croppedImage
                }
            }
            
            let chunkPoints = await ocrManager.extractGPSFromFrames(chunk, diagnosticsCallback: diagnosticsCallback)
            extractedPoints.append(contentsOf: chunkPoints)
            
            // Update progress (OCR is 50-100% of total progress)
            ocrProgress = Double(chunkEnd) / Double(framesToProcess.count)
            await MainActor.run {
                self.processingProgress = 0.5 + (ocrProgress * 0.5)
            }
        }
        
        // Sort points by frame number
        extractedPoints.sort { $0.frameNumber < $1.frameNumber }
        
        print("OCR complete. Found \(extractedPoints.filter { $0.isValid }.count) valid GPS points")
        
        item.gpsPoints = extractedPoints
    }
    
    // MARK: - Export
    
    /// Exports all processed videos to GeoJSON and CSV
    func exportData(to fileURL: URL) throws {
        let processedItems = videoItems.filter { $0.hasGPSData }
        
        guard !processedItems.isEmpty else {
            throw ExportError.writeFailed
        }
        
        // Extract directory and base filename from the chosen URL
        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        
        // Export both files using the user's chosen base name
        try exportManager.exportAll(
            videoItems: processedItems,
            to: directory,
            geoJSONFilename: "\(baseName).geojson",
            csvFilename: "\(baseName).csv"
        )
    }
    
    // MARK: - Video Playback Sync
    
    /// Syncs map animation with video playback
    func syncMapWithVideo() {
        guard let item = selectedVideoItem, item.hasGPSData else { return }
        
        let currentTime = videoManager.currentTime
        let duration = videoManager.duration
        
        guard CMTimeCompare(duration, .zero) > 0 else { return }
        
        let timeSeconds = CMTimeGetSeconds(currentTime)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        mapViewModel.animateRoute(
            videoTime: timeSeconds,
            videoDuration: durationSeconds,
            gpsPoints: item.gpsPoints
        )
    }
    
    // MARK: - Smoothing
    
    /// Toggles route smoothing and reprocesses current video
    func toggleSmoothing() {
        isSmoothingEnabled.toggle()
        
        // Reprocess selected video if it has GPS data
        if let item = selectedVideoItem, item.hasGPSData,
           let index = videoItems.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            let processedPoints = gpsProcessor.processGPSPoints(
                updatedItem.gpsPoints,
                interpolate: true,
                smooth: isSmoothingEnabled,
                smoothingWindow: smoothingWindow
            )
            updatedItem.gpsPoints = processedPoints
            videoItems[index] = updatedItem
            selectedVideoItem = updatedItem
            mapViewModel.updateRoute(from: processedPoints)
        }
    }
}

