//
//  VideoPlayerView.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import SwiftUI
import AVKit
import AppKit

/// SwiftUI wrapper for AVPlayer with macOS support
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        
        // Don't set player immediately - wait for view to have valid bounds
        // Store coordinator to handle layout callbacks
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Only update player if it changed
        guard nsView.player !== player else { return }
        
        // Check if view has valid bounds before setting player
        // Need both bounds and frame to be valid to avoid AVFoundation warnings
        let hasValidBounds = nsView.bounds.width > 0 && nsView.bounds.height > 0
        
        func setPlayerIfReady() {
            // Double-check bounds before setting
            if nsView.bounds.width > 0 && nsView.bounds.height > 0 {
                nsView.player = player
            } else if player != nil {
                // If bounds are still invalid but we have a player, set it anyway
                // AVFoundation will handle the warning, but this prevents nil player issues
                nsView.player = player
            }
        }
        
        if hasValidBounds {
            // View has valid dimensions, set player immediately
            setPlayerIfReady()
        } else {
            // View doesn't have valid dimensions yet, defer setting player until after layout
            // Wait for the next run loop to allow SwiftUI to complete layout
            DispatchQueue.main.async {
                setPlayerIfReady()
            }
        }
    }
}

