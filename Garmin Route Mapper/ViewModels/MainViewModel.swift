//
//  MainViewModel.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import AVFoundation
import SwiftUI
import Combine
import AppKit

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
    
    // OCR Frame Data for navigation
    struct OCRFrameData {
        let frameNumber: Int
        let originalImage: NSImage
        let region: OCRRegion
        let croppedImage: NSImage
        var gpsPoint: GPSPoint? // Mutable to allow editing
    }
    
    @Published var ocrFrameData: [OCRFrameData] = []
    @Published var currentOCRFrameIndex: Int = 0
    
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
        
        // Create a snapshot of items to process to avoid index issues if array is modified
        let itemsToProcess = videoItems
        let totalCount = itemsToProcess.count
        
        for (index, originalItem) in itemsToProcess.enumerated() {
            // Find the item in the current videoItems array by ID (in case items were reordered/removed)
            guard let currentIndex = videoItems.firstIndex(where: { $0.id == originalItem.id }) else {
                // Item was removed, skip it
                continue
            }
            
            var item = videoItems[currentIndex]
            currentProcessingVideo = item.filename
            
            do {
                // Update status
                item.extractionStatus = .extracting
                videoItems[currentIndex] = item
                
                // Extract GPS from video
                try await extractGPSFromVideo(item: &item)
                
                // Re-verify index is still valid after async operation
                guard let updatedIndex = videoItems.firstIndex(where: { $0.id == originalItem.id }) else {
                    // Item was removed during processing, skip it
                    continue
                }
                
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
                
                videoItems[updatedIndex] = item
                
                // Update progress
                processingProgress = Double(index + 1) / Double(totalCount)
                
                // Update map if this is the selected video
                if item.id == selectedVideoItem?.id {
                    mapViewModel.updateRoute(from: processedPoints)
                }
                
            } catch {
                // Re-verify index is still valid after async operation
                guard let errorIndex = videoItems.firstIndex(where: { $0.id == originalItem.id }) else {
                    // Item was removed during processing, skip it
                    continue
                }
                
                item.extractionStatus = .error
                item.gpsPoints = []
                videoItems[errorIndex] = item
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
        
        // Early return if no frames to process
        guard !framesToProcess.isEmpty else {
            print("No frames to process for OCR")
            item.gpsPoints = []
            return
        }
        
        print("Starting OCR processing for \(framesToProcess.count) frames...")
        
        // Clear previous OCR frame data
        await MainActor.run {
            self.ocrFrameData = []
            self.currentOCRFrameIndex = 0
        }
        
        // Extract GPS using OCR with progress tracking
        var ocrProgress = 0.0
        var extractedPoints: [GPSPoint] = []
        
        // Process OCR in chunks to update progress
        let chunkSize = max(1, framesToProcess.count / 10) // Update progress ~10 times
        for chunkStart in stride(from: 0, to: framesToProcess.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, framesToProcess.count)
            
            // Safety check: ensure indices are valid
            guard chunkStart >= 0 && chunkEnd <= framesToProcess.count && chunkStart < chunkEnd else {
                print("Invalid chunk range: start=\(chunkStart), end=\(chunkEnd), count=\(framesToProcess.count)")
                continue
            }
            
            let chunk = Array(framesToProcess[chunkStart..<chunkEnd])
            
            // Process frames and collect frame data
            for (frameIndex, image) in chunk {
                let framePoint = await ocrManager.extractGPSFromImage(
                    image,
                    frameNumber: frameIndex,
                    diagnosticsCallback: { [weak self] originalImage, region, croppedImage in
                        Task { @MainActor in
                            guard let self = self else { return }
                            // Store frame data
                            let frameData = OCRFrameData(
                                frameNumber: frameIndex,
                                originalImage: originalImage,
                                region: region,
                                croppedImage: croppedImage,
                                gpsPoint: nil as GPSPoint? // Will be set after OCR processing
                            )
                            self.ocrFrameData.append(frameData)
                            
                            // Update current display if this is the first frame or we're at the end
                            if self.ocrFrameData.count == 1 || frameIndex == chunk.last?.0 {
                                self.currentOCRFrameIndex = self.ocrFrameData.count - 1
                                self.updateCurrentOCRDisplay()
                            }
                        }
                    }
                )
                extractedPoints.append(framePoint)
                
                // Update the stored frame data with the GPS point
                await MainActor.run {
                    if let dataIndex = self.ocrFrameData.firstIndex(where: { $0.frameNumber == frameIndex }) {
                        var updatedData = self.ocrFrameData[dataIndex]
                        updatedData.gpsPoint = framePoint
                        self.ocrFrameData[dataIndex] = updatedData
                    }
                }
            }
            
            // Update progress (OCR is 50-100% of total progress)
            ocrProgress = Double(chunkEnd) / Double(framesToProcess.count)
            await MainActor.run {
                self.processingProgress = 0.5 + (ocrProgress * 0.5)
            }
        }
        
        // Sort points by frame number
        extractedPoints.sort { $0.frameNumber < $1.frameNumber }
        
        // Sort OCR frame data by frame number
        await MainActor.run {
            self.ocrFrameData.sort { $0.frameNumber < $1.frameNumber }
            
            // Set current frame to first frame if available
            if !self.ocrFrameData.isEmpty {
                self.currentOCRFrameIndex = 0
                self.updateCurrentOCRDisplay()
            }
        }
        
        print("OCR complete. Found \(extractedPoints.filter { $0.isValid }.count) valid GPS points")
        
        item.gpsPoints = extractedPoints
    }
    
    // MARK: - Export
    
    /// Exports all processed videos to GeoJSON and CSV
    func exportData(to fileURL: URL) throws {
        let processedItems = videoItems.filter { $0.hasGPSData }
        
        guard !processedItems.isEmpty else {
            throw ExportError.writeFailed(message: "No GPS data available to export")
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
    
    // MARK: - OCR Frame Navigation
    
    /// Navigates to the previous OCR frame
    func previousOCRFrame() {
        guard !ocrFrameData.isEmpty else { return }
        currentOCRFrameIndex = max(0, currentOCRFrameIndex - 1)
        updateCurrentOCRDisplay()
    }
    
    /// Navigates to the next OCR frame
    func nextOCRFrame() {
        guard !ocrFrameData.isEmpty else { return }
        currentOCRFrameIndex = min(ocrFrameData.count - 1, currentOCRFrameIndex + 1)
        updateCurrentOCRDisplay()
    }
    
    /// Jumps to a specific frame by frame number (1-based index)
    func jumpToFrame(frameNumber: Int) {
        guard !ocrFrameData.isEmpty else { return }
        let targetIndex = max(0, min(ocrFrameData.count - 1, frameNumber - 1))
        currentOCRFrameIndex = targetIndex
        updateCurrentOCRDisplay()
    }
    
    /// Jumps to a specific frame by index (0-based)
    func jumpToFrameIndex(_ index: Int) {
        guard !ocrFrameData.isEmpty else { return }
        let targetIndex = max(0, min(ocrFrameData.count - 1, index))
        currentOCRFrameIndex = targetIndex
        updateCurrentOCRDisplay()
    }
    
    /// Updates the current OCR display from the frame data array
    private func updateCurrentOCRDisplay() {
        guard currentOCRFrameIndex >= 0 && currentOCRFrameIndex < ocrFrameData.count else {
            currentOCRImage = nil
            currentOCRRegion = nil
            croppedOCRImage = nil
            return
        }
        
        let frameData = ocrFrameData[currentOCRFrameIndex]
        currentOCRImage = frameData.originalImage
        currentOCRRegion = frameData.region
        croppedOCRImage = frameData.croppedImage
    }
    
    /// Updates GPS data for the current OCR frame
    func updateCurrentFrameGPS(latitude: Double?, longitude: Double?) {
        guard currentOCRFrameIndex >= 0 && currentOCRFrameIndex < ocrFrameData.count else { return }
        
        // Create new GPS point
        let frameNumber = ocrFrameData[currentOCRFrameIndex].frameNumber
        let newGPSPoint = GPSPoint(
            frameNumber: frameNumber,
            latitude: latitude,
            longitude: longitude,
            extractionMethod: .ocr
        )
        
        // Update frame data
        var updatedFrameData = ocrFrameData[currentOCRFrameIndex]
        updatedFrameData.gpsPoint = newGPSPoint
        ocrFrameData[currentOCRFrameIndex] = updatedFrameData
        
        // Update the corresponding GPS point in the selected video item
        if let item = selectedVideoItem,
           let itemIndex = videoItems.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = videoItems[itemIndex]
            
            // Find and update the GPS point with matching frame number
            if let gpsIndex = updatedItem.gpsPoints.firstIndex(where: { $0.frameNumber == frameNumber }) {
                updatedItem.gpsPoints[gpsIndex] = newGPSPoint
            } else {
                // If frame doesn't exist, add it
                updatedItem.gpsPoints.append(newGPSPoint)
                updatedItem.gpsPoints.sort { $0.frameNumber < $1.frameNumber }
            }
            
            videoItems[itemIndex] = updatedItem
            selectedVideoItem = updatedItem
            
            // Reprocess with interpolation and smoothing
            let processedPoints = gpsProcessor.processGPSPoints(
                updatedItem.gpsPoints,
                interpolate: true,
                smooth: isSmoothingEnabled,
                smoothingWindow: smoothingWindow
            )
            updatedItem.gpsPoints = processedPoints
            videoItems[itemIndex] = updatedItem
            selectedVideoItem = updatedItem
            mapViewModel.updateRoute(from: processedPoints)
        }
    }
    
    /// Gets the current OCR frame's GPS data
    var currentOCRFrameGPS: GPSPoint? {
        guard currentOCRFrameIndex >= 0 && currentOCRFrameIndex < ocrFrameData.count else {
            return nil
        }
        return ocrFrameData[currentOCRFrameIndex].gpsPoint
    }
    
    /// Gets the total number of OCR frames
    var totalOCRFrames: Int {
        return ocrFrameData.count
    }
    
    /// Checks if there's a previous frame
    var canGoToPreviousFrame: Bool {
        return currentOCRFrameIndex > 0 && !ocrFrameData.isEmpty
    }
    
    /// Checks if there's a next frame
    var canGoToNextFrame: Bool {
        return currentOCRFrameIndex < ocrFrameData.count - 1 && !ocrFrameData.isEmpty
    }
}

