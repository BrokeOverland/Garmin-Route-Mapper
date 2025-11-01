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
                        if viewModel.isProcessing || viewModel.currentOCRImage != nil {
                            Divider()
                            
                            OCRDiagnosticsView(
                                originalImage: viewModel.currentOCRImage,
                                croppedImage: viewModel.croppedOCRImage,
                                region: viewModel.currentOCRRegion
                            )
                            .frame(height: 200)
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
        
        if panel.runModal() == .OK, var url = panel.url {
            // Ensure .geojson extension
            if url.pathExtension.isEmpty || url.pathExtension != "geojson" {
                url = url.deletingPathExtension().appendingPathExtension("geojson")
            }
            
            do {
                try viewModel.exportData(to: url)
                
                // Show success alert
                DispatchQueue.main.async {
                    viewModel.errorMessage = "Export completed successfully:\nGeoJSON: \(url.path)\nCSV: \(url.deletingPathExtension().appendingPathExtension("csv").path)"
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
    let originalImage: NSImage?
    let croppedImage: NSImage?
    let region: OCRRegion?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OCR Diagnostics")
                .font(.headline)
                .padding(.bottom, 4)
            
            HStack(spacing: 16) {
                // Original image with region overlay
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original Frame")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let image = originalImage, let region = region {
                        ZStack {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(Color.black)
                            
                            // Overlay region rectangle
                            GeometryReader { geometry in
                                let imageSize = image.size
                                let viewSize = geometry.size
                                let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
                                let scaledImageWidth = imageSize.width * scale
                                let scaledImageHeight = imageSize.height * scale
                                let offsetX = (viewSize.width - scaledImageWidth) / 2
                                let offsetY = (viewSize.height - scaledImageHeight) / 2
                                
                                Rectangle()
                                    .stroke(Color.red, lineWidth: 2)
                                    .frame(
                                        width: CGFloat(region.width) * scaledImageWidth,
                                        height: CGFloat(region.height) * scaledImageHeight
                                    )
                                    .position(
                                        x: offsetX + CGFloat(region.x) * scaledImageWidth + CGFloat(region.width) * scaledImageWidth / 2,
                                        y: offsetY + CGFloat(region.y) * scaledImageHeight + CGFloat(region.height) * scaledImageHeight / 2
                                    )
                            }
                        }
                        .frame(width: 300, height: 150)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 300, height: 150)
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
                    
                    if let croppedImage = croppedImage {
                        Image(nsImage: croppedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 300, maxHeight: 150)
                            .background(Color.black)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 300, height: 150)
                            .overlay(
                                Text("No cropped image")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                
                Spacer()
                
                // Region info
                if let region = region {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Region Info")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("X: \(String(format: "%.3f", region.x))")
                                .font(.caption2)
                            Text("Y: \(String(format: "%.3f", region.y))")
                                .font(.caption2)
                            Text("Width: \(String(format: "%.3f", region.width))")
                                .font(.caption2)
                            Text("Height: \(String(format: "%.3f", region.height))")
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
