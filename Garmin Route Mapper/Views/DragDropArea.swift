//
//  DragDropArea.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drag and drop area for video files
struct DragDropArea: View {
    @Binding var isHighlighted: Bool
    let onDrop: ([URL]) -> Void
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isHighlighted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: isHighlighted ? 3 : 2, dash: [10])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(isHighlighted ? 0.5 : 0.3))
                )
            
            VStack(spacing: 16) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                
                Text("Drag & Drop MP4 Videos Here")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("or click to select files")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minHeight: 200)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isHighlighted) { providers in
            handleDrop(providers: providers)
        }
        .onTapGesture {
            selectFiles()
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            urls.append(url)
                            if urls.count == providers.count {
                                onDrop(urls)
                            }
                        }
                    } else if let url = item as? URL {
                        DispatchQueue.main.async {
                            urls.append(url)
                            if urls.count == providers.count {
                                onDrop(urls)
                            }
                        }
                    }
                }
            }
        }
        
        return true
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.message = "Select Garmin Travel Laps MP4 videos"
        
        if panel.runModal() == .OK {
            onDrop(panel.urls)
        }
    }
}

