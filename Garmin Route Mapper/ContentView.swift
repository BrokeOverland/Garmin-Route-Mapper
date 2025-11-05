//
//  ContentView.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var isDragDropHighlighted = false
    @State private var showExportDialog = false
    @State private var syncTask: Task<Void, Never>?
    
    var body: some View {
        HSplitView {
            // Left side: Video list and controls
            VStack(spacing: 0) {
                // Drag and drop area
                if viewModel.videoItems.isEmpty {
                    DragDropArea(isHighlighted: $isDragDropHighlighted) { urls in
                        viewModel.addVideos(urls: urls)
                    }
                    .padding()
                } else {
                    // Video list
                    VStack(alignment: .leading, spacing: 0) {
                        // Header with controls
                        HStack {
                            Button(action: {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = true
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                panel.allowedContentTypes = [.mpeg4Movie]
                                
                                if panel.runModal() == .OK {
                                    viewModel.addVideos(urls: panel.urls)
                                }
                            }) {
                                Label("Add Videos", systemImage: "plus.circle")
                            }
                            
                            Spacer()
                            
                            if !viewModel.videoItems.isEmpty {
                                Button(action: {
                                    Task {
                                        await viewModel.processAllVideos()
                                    }
                                }) {
                                    Label("Extract GPS", systemImage: "location.circle")
                                }
                                .disabled(viewModel.isProcessing)
                                
                                Button(action: {
                                    showExportDialog = true
                                }) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                                .disabled(viewModel.videoItems.filter { $0.hasGPSData }.isEmpty)
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        
                        Divider()
                        
                        // Video list
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(viewModel.videoItems) { item in
                                    VideoListItemView(
                                        item: item,
                                        isSelected: viewModel.selectedVideoItem?.id == item.id,
                                        onSelect: {
                                            viewModel.selectVideo(item)
                                        },
                                        onRemove: {
                                            viewModel.removeVideo(item)
                                        }
                                    )
                                }
                            }
                            .padding()
                        }
                        
                        // Processing progress
                        if viewModel.isProcessing {
                            VStack(alignment: .leading, spacing: 8) {
                                Divider()
                                
                                HStack {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .frame(width: 16, height: 16)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let current = viewModel.currentProcessingVideo {
                                            Text("Processing: \(current)")
                                                .font(.caption)
                                                .lineLimit(1)
                                        }
                                        
                                        ProgressView(value: viewModel.processingProgress)
                                            .progressViewStyle(.linear)
                                        
                                        Text("\(Int(viewModel.processingProgress * 100))%")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                            }
                        }
                        
                        // OCR Diagnostics Window
                        if viewModel.isProcessing || !viewModel.ocrFrameData.isEmpty {
                            Divider()
                            
                            OCRDiagnosticsView(viewModel: viewModel)
                                .frame(height: 250)
                                .padding()
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 350)
            
            // Right side: Video player and map
            if viewModel.selectedVideoItem != nil {
                VSplitView {
                    // Video player
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(viewModel.selectedVideoItem?.filename ?? "")
                                .font(.headline)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            if viewModel.selectedVideoItem?.hasGPSData == true {
                                Label("GPS Data", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else {
                                Label("No GPS", systemImage: "xmark.circle")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        
                        VideoPlayerView(player: viewModel.videoPlayer.player)
                            .frame(minHeight: 300)
                        
                        // Video controls
                        HStack {
                            Button(action: {
                                if viewModel.videoPlayer.isPlaying {
                                    viewModel.videoPlayer.pause()
                                } else {
                                    viewModel.videoPlayer.play()
                                }
                            }) {
                                Image(systemName: viewModel.videoPlayer.isPlaying ? "pause.fill" : "play.fill")
                            }
                            
                            Text(timeString(from: viewModel.videoPlayer.currentTime))
                                .font(.caption)
                                .monospacedDigit()
                            
                            Text("/")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(timeString(from: viewModel.videoPlayer.duration))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            // Smoothing toggle
                            Toggle("Smooth Route", isOn: $viewModel.isSmoothingEnabled)
                                .onChange(of: viewModel.isSmoothingEnabled) {
                                    viewModel.toggleSmoothing()
                                }
                            
                            Stepper("Window: \(viewModel.smoothingWindow)", value: $viewModel.smoothingWindow, in: 3...15, step: 2)
                                .disabled(!viewModel.isSmoothingEnabled)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                    .frame(minHeight: 400)
                    
                    // Map view
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Route Map")
                                .font(.headline)
                            
                            Spacer()
                            
                            if let count = viewModel.selectedVideoItem?.gpsPoints.filter({ $0.isValid }).count {
                                Text("\(count) GPS points")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        
                        MapView(
                            region: Binding(
                                get: { viewModel.mapViewModel.region },
                                set: { viewModel.mapViewModel.region = $0 }
                            ),
                            routeCoordinates: viewModel.mapViewModel.routeCoordinates,
                            currentPosition: viewModel.mapViewModel.currentPosition
                        )
                        .frame(minHeight: 300)
                    }
                    .frame(minHeight: 300)
                }
            } else {
                // Empty state
                VStack(spacing: 20) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    
                    Text("No Video Selected")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    Text("Add videos and select one to view")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            // Sync map with video playback
            syncTask = Task { @MainActor in
                while !Task.isCancelled {
                    viewModel.syncMapWithVideo()
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                }
            }
        }
        .onDisappear {
            syncTask?.cancel()
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
        }
        .onChange(of: showExportDialog) { _, newValue in
            if newValue {
                exportData()
            }
        }
    }
    
    private func timeString(from time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else {
            return "00:00"
        }
        
        let totalSeconds = Int(CMTimeGetSeconds(time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "routes"
        panel.title = "Export GPS Data"
        panel.message = "Choose a location and name for the GeoJSON file"
        panel.prompt = "Export"
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let originalURL = panel.url {
            // For NSSavePanel in App Sandbox, we need to start accessing the security-scoped resource
            // The URL from NSSavePanel is security-scoped and grants access to create files in that directory
            guard originalURL.startAccessingSecurityScopedResource() else {
                viewModel.errorMessage = "Export failed: Could not access selected location. Please try selecting the folder again."
                viewModel.showError = true
                showExportDialog = false
                return
            }
            
            // Also access the directory to ensure we can write multiple files
            let directory = originalURL.deletingLastPathComponent()
            let directoryAccessGranted = directory.startAccessingSecurityScopedResource()
            
            // Defer cleanup to ensure security-scoped access is maintained during export
            defer {
                originalURL.stopAccessingSecurityScopedResource()
                if directoryAccessGranted {
                    directory.stopAccessingSecurityScopedResource()
                }
            }
            
            // Build the file URL after starting security-scoped access
            var url = originalURL
            if url.pathExtension.isEmpty || url.pathExtension != "geojson" {
                url = url.deletingPathExtension().appendingPathExtension("geojson")
            }
            
            // Perform export with security-scoped access active
            do {
                try viewModel.exportData(to: url)
                
                // Show success alert
                DispatchQueue.main.async {
                    let csvPath = url.deletingPathExtension().appendingPathExtension("csv").path
                    viewModel.errorMessage = "Export completed successfully:\nGeoJSON: \(url.path)\nCSV: \(csvPath)"
                    viewModel.showError = true
                }
            } catch {
                viewModel.errorMessage = "Export failed: \(error.localizedDescription)"
                viewModel.showError = true
            }
        }
        
        showExportDialog = false
    }
}

// MARK: - Supporting Views

struct VideoListItemView: View {
    let item: VideoItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.headline)
                    .lineLimit(1)
                
                HStack {
                    StatusBadge(status: item.extractionStatus)
                    
                    if item.hasGPSData {
                        Text("\(item.gpsPoints.filter { $0.isValid }.count) points")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .onTapGesture {
            onSelect()
        }
    }
}

struct StatusBadge: View {
    let status: ExtractionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForStatus(status))
                .frame(width: 8, height: 8)
            
            Text(status.rawValue)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(colorForStatus(status).opacity(0.2))
        .cornerRadius(4)
    }
    
    private func colorForStatus(_ status: ExtractionStatus) -> Color {
        switch status {
        case .pending:
            return .gray
        case .extracting:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .error:
            return .orange
        }
    }
}

// MARK: - OCR Diagnostics View

struct OCRDiagnosticsView: View {
    @ObservedObject var viewModel: MainViewModel
    
    @State private var editedLatitude: String = ""
    @State private var editedLongitude: String = ""
    @State private var isEditing = false
    @State private var frameNumberInput: String = ""
    
    var currentFrameData: MainViewModel.OCRFrameData? {
        guard viewModel.currentOCRFrameIndex >= 0 && viewModel.currentOCRFrameIndex < viewModel.ocrFrameData.count else {
            return nil
        }
        return viewModel.ocrFrameData[viewModel.currentOCRFrameIndex]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OCR Diagnostics")
                    .font(.headline)
                
                Spacer()
                
                // Frame navigation controls
                if !viewModel.ocrFrameData.isEmpty {
                    HStack(spacing: 8) {
                        Button(action: {
                            viewModel.previousOCRFrame()
                            updateEditFields(resetEditing: true)
                        }) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!viewModel.canGoToPreviousFrame)
                        .buttonStyle(.borderless)
                        
                        Text("Frame")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextField("", text: $frameNumberInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .font(.caption)
                            .onSubmit {
                                if let frameNum = Int(frameNumberInput) {
                                    viewModel.jumpToFrame(frameNumber: frameNum)
                                    updateEditFields(resetEditing: true)
                                }
                            }
                            .onChange(of: viewModel.currentOCRFrameIndex) { _, _ in
                                frameNumberInput = String(viewModel.currentOCRFrameIndex + 1)
                            }
                        
                        Text("of \(viewModel.totalOCRFrames)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            viewModel.nextOCRFrame()
                            updateEditFields(resetEditing: true)
                        }) {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!viewModel.canGoToNextFrame)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.bottom, 4)
            
            HStack(spacing: 16) {
                // Original image with region overlay
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original Frame")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let frameData = currentFrameData {
                        ZStack {
                            Image(nsImage: frameData.originalImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(Color.black)
                            
                            // Overlay region rectangle
                            GeometryReader { geometry in
                                let imageSize = frameData.originalImage.size
                                let viewSize = geometry.size
                                let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
                                let scaledImageWidth = imageSize.width * scale
                                let scaledImageHeight = imageSize.height * scale
                                let offsetX = (viewSize.width - scaledImageWidth) / 2
                                let offsetY = (viewSize.height - scaledImageHeight) / 2
                                
                                Rectangle()
                                    .stroke(Color.red, lineWidth: 2)
                                    .frame(
                                        width: CGFloat(frameData.region.width) * scaledImageWidth,
                                        height: CGFloat(frameData.region.height) * scaledImageHeight
                                    )
                                    .position(
                                        x: offsetX + CGFloat(frameData.region.x) * scaledImageWidth + CGFloat(frameData.region.width) * scaledImageWidth / 2,
                                        y: offsetY + CGFloat(frameData.region.y) * scaledImageHeight + CGFloat(frameData.region.height) * scaledImageHeight / 2
                                    )
                            }
                        }
                        .frame(width: 250, height: 140)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 140)
                            .overlay(
                                Text("No image")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                
                Divider()
                
                // Cropped region
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cropped Region")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let frameData = currentFrameData {
                        Image(nsImage: frameData.croppedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 250, maxHeight: 140)
                            .background(Color.black)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 140)
                            .overlay(
                                Text("No cropped image")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                
                Divider()
                
                // GPS Data and Editing
                VStack(alignment: .leading, spacing: 8) {
                    Text("GPS Data")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let gpsPoint = viewModel.currentOCRFrameGPS {
                        if gpsPoint.isValid {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Latitude: \(String(format: "%.6f", gpsPoint.latitude ?? 0))")
                                    .font(.caption2)
                                Text("Longitude: \(String(format: "%.6f", gpsPoint.longitude ?? 0))")
                                    .font(.caption2)
                                Text("Frame: \(gpsPoint.frameNumber)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("No valid GPS data")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("No GPS data")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Edit controls
                    if currentFrameData != nil {
                        Button(action: {
                            if isEditing {
                                // Cancel editing - reset to current values
                                isEditing = false
                                updateEditFields(resetEditing: false)
                            } else {
                                // Start editing - populate fields with current values
                                updateEditFields(resetEditing: false)
                                isEditing = true
                            }
                        }) {
                            Text(isEditing ? "Cancel" : "Edit")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        
                        if isEditing {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Lat:")
                                        .font(.caption2)
                                        .frame(width: 40, alignment: .leading)
                                    TextField("Latitude", text: $editedLatitude)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption2)
                                }
                                
                                HStack {
                                    Text("Lon:")
                                        .font(.caption2)
                                        .frame(width: 40, alignment: .leading)
                                    TextField("Longitude", text: $editedLongitude)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption2)
                                }
                                
                                Button("Save") {
                                    let lat = Double(editedLatitude)
                                    let lon = Double(editedLongitude)
                                    viewModel.updateCurrentFrameGPS(latitude: lat, longitude: lon)
                                    isEditing = false
                                    updateEditFields(resetEditing: false)
                                }
                                .buttonStyle(.borderless)
                                .disabled(editedLatitude.isEmpty || editedLongitude.isEmpty)
                            }
                        }
                    }
                }
                
                Spacer()
            }
            
            // Flagged frames list
            if !viewModel.flaggedFrames.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Flagged Frames (\(viewModel.flaggedFrames.count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.flaggedFrames) { flaggedFrame in
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                        .font(.caption2)
                                    
                                    Text("Frame \(flaggedFrame.frameNumber)")
                                        .font(.caption2)
                                    
                                    Spacer()
                                    
                                    Text(flaggedFrame.reason.rawValue)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    viewModel.currentOCRFrameIndex >= 0 &&
                                    viewModel.currentOCRFrameIndex < viewModel.ocrFrameData.count &&
                                    viewModel.ocrFrameData[viewModel.currentOCRFrameIndex].frameNumber == flaggedFrame.frameNumber
                                    ? Color.accentColor.opacity(0.2) : Color.clear
                                )
                                .cornerRadius(4)
                                .onTapGesture {
                                    // Jump to the flagged frame by finding its index
                                    if let index = viewModel.ocrFrameData.firstIndex(where: { $0.frameNumber == flaggedFrame.frameNumber }) {
                                        viewModel.jumpToFrameIndex(index)
                                        updateEditFields(resetEditing: true)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            updateEditFields(resetEditing: true)
            frameNumberInput = viewModel.ocrFrameData.isEmpty ? "" : String(viewModel.currentOCRFrameIndex + 1)
        }
        .onChange(of: viewModel.currentOCRFrameIndex) { _, _ in
            updateEditFields(resetEditing: true)
            frameNumberInput = String(viewModel.currentOCRFrameIndex + 1)
        }
    }
    
    private func updateEditFields(resetEditing: Bool = true) {
        if let gpsPoint = viewModel.currentOCRFrameGPS {
            if let lat = gpsPoint.latitude {
                editedLatitude = String(format: "%.6f", lat)
            } else {
                editedLatitude = ""
            }
            if let lon = gpsPoint.longitude {
                editedLongitude = String(format: "%.6f", lon)
            } else {
                editedLongitude = ""
            }
        } else {
            editedLatitude = ""
            editedLongitude = ""
        }
        if resetEditing {
            isEditing = false
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
