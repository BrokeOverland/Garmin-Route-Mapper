//
//  OCRManager.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

@preconcurrency import Vision
import AppKit
import CoreGraphics

/// Diagnostic callback type for displaying OCR processing info
typealias OCRDiagnosticsCallback = (NSImage, OCRRegion, NSImage) -> Void

/// Defines a region of interest for OCR processing (normalized coordinates 0.0 to 1.0)
struct OCRRegion {
    /// X position (0.0 = left, 1.0 = right)
    let x: Double
    /// Y position (0.0 = top, 1.0 = bottom)
    let y: Double
    /// Width (0.0 to 1.0)
    let width: Double
    /// Height (0.0 to 1.0)
    let height: Double
    
    /// Bottom-left corner region (common for GPS coordinates in Garmin videos)
    static let bottomLeft = OCRRegion(x: 0.0, y: 0.6, width: 0.4, height: 0.4)
    
    /// Bottom-right corner region
    static let bottomRight = OCRRegion(x: 0.6, y: 0.6, width: 0.4, height: 0.4)
    
    /// Top-left corner region
    static let topLeft = OCRRegion(x: 0.0, y: 0.0, width: 0.4, height: 0.4)
    
    /// Top-right corner region
    static let topRight = OCRRegion(x: 0.6, y: 0.0, width: 0.4, height: 0.4)
    
    /// Full frame (no cropping)
    static let fullFrame = OCRRegion(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    
    /// Custom region for specific GPS display location
    /// Based on 1920x1080 image: origin (653, 1030), size 390x50
    static let customGPSRegion: OCRRegion = OCRRegion(
        x: 653.0 / 1920.0,      // 0.3401041666666667
        y: 1030.0 / 1080.0,     // 0.9537037037037037 (from top)
        width: 390.0 / 1920.0,  // 0.203125
        height: 50.0 / 1080.0   // 0.0462962962962963
    )
}

/// Manages OCR text recognition to extract GPS coordinates from video frames
class OCRManager {
    // Static queue with explicit QoS for Vision framework calls
    // Reusing a queue is more efficient than creating new ones
    // Marked as nonisolated to allow access from nonisolated contexts
    // DispatchQueue is Sendable, so safe to use from any isolation context
    nonisolated private static let visionQueue = DispatchQueue(
        label: "com.garmin.ocr.vision",
        qos: .userInitiated,
        attributes: []
    )
    
    /// Region of interest for OCR processing
    /// Default is customGPSRegion for 1920x1080 videos with GPS at (653, 1030) size 390x50
    /// Marked as nonisolated(unsafe) since it's accessed from nonisolated methods
    /// Safe because OCRRegion is immutable (all properties are let) and thread-safe
    nonisolated(unsafe) var regionOfInterest: OCRRegion = .customGPSRegion
    
    /// Extracts GPS coordinates from a video frame image
    /// Searches for decimal degree format (e.g., "37.7749°N, 122.4194°W" or "37.7749, -122.4194")
    nonisolated func extractGPSFromImage(_ image: NSImage, frameNumber: Int, diagnosticsCallback: OCRDiagnosticsCallback? = nil) async -> GPSPoint {
        guard let originalCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return GPSPoint(frameNumber: frameNumber, latitude: nil, longitude: nil)
        }
        
        // Crop image to region of interest using top-left coordinates (matching OCRRegion)
        let (croppedCGImage, croppedNSImage) = cropImageTopLeft(originalCGImage, imageSize: image.size, to: regionOfInterest)
        let cgImage = croppedCGImage ?? originalCGImage
        let diagnosticNSImage = croppedNSImage ?? image
        
        // Call diagnostics callback if provided
        if let callback = diagnosticsCallback {
            callback(image, regionOfInterest, diagnosticNSImage)
        }
        
        let request = VNRecognizeTextRequest { _, _ in
            // Handled synchronously via request.results
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = ["°", "N", "S", "E", "W"] // Common GPS symbols
        // Use ISO 639 two-letter language code (e.g., "en") instead of locale-specific codes (e.g., "en-US")
        request.recognitionLanguages = ["en"]
        
        // Since we've already cropped to the region of interest, analyze the entire cropped image
        // Set regionOfInterest to full frame (normalized coordinates: x=0, y=0, width=1, height=1)
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        
        do {
            // Run Vision framework call on a queue with explicit QoS
            // Note: Vision framework internally creates worker threads that may not have QoS specified,
            // which can cause priority inversion warnings. This is a known limitation of the Vision framework.
            // Using a serial queue with explicit QoS helps minimize but may not completely eliminate the warning.
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.visionQueue.async {
                    do {
                        try handler.perform([request])
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            // request.results is already [VNRecognizedTextObservation]? for VNRecognizeTextRequest
            guard let observations = request.results, !observations.isEmpty else {
                return GPSPoint(frameNumber: frameNumber, latitude: nil, longitude: nil)
            }
            
            for observation in observations {
                let candidates = observation.topCandidates(10)
                for candidate in candidates {
                    let text = candidate.string
                    if let (lat, lon) = parseGPSCoordinates(from: text) {
                        return GPSPoint(
                            frameNumber: frameNumber,
                            latitude: lat,
                            longitude: lon,
                            extractionMethod: .ocr
                        )
                    }
                }
            }
        } catch {
            print("OCR Error: \(error.localizedDescription)")
        }
        
        return GPSPoint(frameNumber: frameNumber, latitude: nil, longitude: nil)
    }
    
    /// Batch extracts GPS coordinates from multiple frames
    nonisolated func extractGPSFromFrames(_ frames: [(Int, NSImage)], diagnosticsCallback: OCRDiagnosticsCallback? = nil) async -> [GPSPoint] {
        var points: [GPSPoint] = []
        
        // Process frames concurrently in batches to speed up OCR
        // Use explicit QoS to avoid priority inversion warnings
        await withTaskGroup(of: GPSPoint.self) { group in
            for (frameNumber, image) in frames {
                group.addTask(priority: .userInitiated) {
                    await self.extractGPSFromImage(image, frameNumber: frameNumber, diagnosticsCallback: diagnosticsCallback)
                }
            }
            
            for await point in group {
                points.append(point)
            }
        }
        
        // Sort points by frame number to maintain order
        points.sort { $0.frameNumber < $1.frameNumber }
        
        return points
    }
    
    /// Parses GPS coordinates from text string
    /// Supports formats like:
    /// - "37.7749, -122.4194"
    /// - "37.7749°N, 122.4194°W"
    /// - "37.7749 N, 122.4194 W"
    /// - "Lat: 37.7749 Lon: -122.4194"
    /// Uses simplified patterns to handle OCR errors more gracefully
    nonisolated private func parseGPSCoordinates(from text: String) -> (Double, Double)? {
        // Normalize text: replace common OCR errors and normalize whitespace
        let normalizedText = text
            .replacingOccurrences(of: "  ", with: " ") // Multiple spaces to single
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Pattern 1: Simple decimal degrees with optional signs
        // More flexible: allows numbers with or without decimals, handles spaces
        // Matches: "37.7749, -122.4194" or "37, -122" or "37.77, 122.41"
        let simplePattern = #"(-?\d+(?:\.\d+)?)\s*[,\s]\s*(-?\d+(?:\.\d+)?)"#
        
        if let regex = try? NSRegularExpression(pattern: simplePattern, options: []),
           let match = regex.firstMatch(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText)) {
            
            let latStr = String(normalizedText[Range(match.range(at: 1), in: normalizedText)!])
            let lonStr = String(normalizedText[Range(match.range(at: 2), in: normalizedText)!])
            
            if let lat = Double(latStr), let lon = Double(lonStr) {
                if isValidCoordinate(latitude: lat, longitude: lon) {
                    return (lat, lon)
                }
            }
        }
        
        // Pattern 2: Decimal degrees with N/S/E/W indicators (more flexible)
        // Matches: "37.7749°N, 122.4194°W" or "37.77 N, 122.41 W" or "37N, 122W"
        let directionalPattern = #"(\d+(?:\.\d+)?)\s*°?\s*([NS])?\s*[,\s]\s*(\d+(?:\.\d+)?)\s*°?\s*([EW])?"#
        
        if let regex = try? NSRegularExpression(pattern: directionalPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText)) {
            
            let latStr = String(normalizedText[Range(match.range(at: 1), in: normalizedText)!])
            let lonStr = String(normalizedText[Range(match.range(at: 3), in: normalizedText)!])
            
            var latDir = ""
            var lonDir = ""
            
            if match.range(at: 2).location != NSNotFound {
                latDir = String(normalizedText[Range(match.range(at: 2), in: normalizedText)!]).uppercased()
            }
            if match.range(at: 4).location != NSNotFound {
                lonDir = String(normalizedText[Range(match.range(at: 4), in: normalizedText)!]).uppercased()
            }
            
            if let lat = Double(latStr), let lon = Double(lonStr) {
                var finalLat = lat
                var finalLon = lon
                
                // Apply direction indicators if present
                if latDir == "S" {
                    finalLat = -lat
                }
                if lonDir == "W" {
                    finalLon = -lon
                }
                
                if isValidCoordinate(latitude: finalLat, longitude: finalLon) {
                    return (finalLat, finalLon)
                }
            }
        }
        
        // Pattern 3: "Lat:" / "Lon:" prefix format (simplified)
        // Matches: "Lat: 37.7749 Lon: -122.4194" or "Latitude 37.77 Longitude -122.41"
        let latLonPattern = #"(?:lat|latitude)[:\s]+(-?\d+(?:\.\d+)?).*?(?:lon|lng|longitude)[:\s]+(-?\d+(?:\.\d+)?)"#
        
        if let regex = try? NSRegularExpression(pattern: latLonPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText)) {
            
            let latStr = String(normalizedText[Range(match.range(at: 1), in: normalizedText)!])
            let lonStr = String(normalizedText[Range(match.range(at: 2), in: normalizedText)!])
            
            if let lat = Double(latStr), let lon = Double(lonStr) {
                if isValidCoordinate(latitude: lat, longitude: lon) {
                    return (lat, lon)
                }
            }
        }
        
        return nil
    }
    
    /// Validates that coordinates are within valid ranges
    nonisolated private func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        return latitude >= -90 && latitude <= 90 &&
               longitude >= -180 && longitude <= 180 &&
               abs(latitude) > 0.0001 && abs(longitude) > 0.0001 // Filter out near-zero values
    }
    
    /// Crops a CGImage to the specified region of interest
    /// Uses top-left coordinates and creates a new image by drawing the region
    /// Returns: (croppedCGImage for OCR, croppedNSImage for display)
    nonisolated private func cropImageTopLeft(_ image: CGImage, imageSize: NSSize, to region: OCRRegion) -> (CGImage?, NSImage?) {
        // Use imageSize (from NSImage) for coordinate calculations to match the overlay rectangle
        // The overlay uses image.size which is the NSImage size, so we must match that
        let imageWidth = Int(imageSize.width)
        let imageHeight = Int(imageSize.height)
        
        // Calculate crop rectangle in pixels (using top-left origin, matching OCRRegion and overlay)
        // This matches exactly how the overlay rectangle is drawn in ContentView
        let x = Int(region.x * Double(imageWidth))
        let width = Int(region.width * Double(imageWidth))
        let height = Int(region.height * Double(imageHeight))
        
        // Ensure coordinates are within image bounds (using actual CGImage dimensions)
        let cgImageWidth = image.width
        let cgImageHeight = image.height
        
        // Position the crop region at the bottom of the frame
        // Calculate in top-left coordinates first: we want the bottom portion
        // topY should position the crop at the bottom: imageHeight - height
        let topY = cgImageHeight - height
        
        // Clamp coordinates to actual CGImage bounds
        let clampedX = max(0, min(x, cgImageWidth - 1))
        let clampedWidth = max(1, min(width, cgImageWidth - clampedX))
        // Ensure topY is valid (if height > imageHeight, just use 0)
        let clampedTopY = max(0, min(topY, cgImageHeight - 1))
        let clampedHeight = max(1, min(height, cgImageHeight - clampedTopY))
        
        // Create crop rectangle for CGImage
        // Using top-left coordinates directly (clampedTopY positions from top)
        let cgCropRect = CGRect(x: clampedX, y: clampedTopY, width: clampedWidth, height: clampedHeight)
        
        // Extract the cropped CGImage directly - no flipping needed
        guard let croppedCGImage = image.cropping(to: cgCropRect) else {
            return (nil, nil)
        }
        
        // Create NSImage from cropped CGImage for display
        let croppedNSImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: croppedCGImage.width, height: croppedCGImage.height))
        
        // Return the cropped CGImage directly for OCR
        return (croppedCGImage, croppedNSImage)
    }
    
}

