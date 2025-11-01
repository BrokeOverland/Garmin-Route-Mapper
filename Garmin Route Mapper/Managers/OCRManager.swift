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
    static let customGPSRegion = OCRRegion(
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
    nonisolated private func parseGPSCoordinates(from text: String) -> (Double, Double)? {
        // Pattern 1: Simple decimal degrees with optional signs
        // e.g., "37.7749, -122.4194" or "37.7749, 122.4194"
        let simplePattern = #"(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)"#
        
        if let match = text.range(of: simplePattern, options: .regularExpression) {
            let matchedText = String(text[match])
            let components = matchedText.replacingOccurrences(of: " ", with: "").split(separator: ",")
            
            if components.count == 2,
               let lat = Double(components[0]),
               let lon = Double(components[1]) {
                if isValidCoordinate(latitude: lat, longitude: lon) {
                    return (lat, lon)
                }
            }
        }
        
        // Pattern 2: Decimal degrees with N/S/E/W indicators
        // e.g., "37.7749°N, 122.4194°W" or "37.7749 N, 122.4194 W"
        let directionalPattern = #"(\d+\.?\d*)\s*°?\s*([NS])\s*,\s*(\d+\.?\d*)\s*°?\s*([EW])"#
        
        if let regex = try? NSRegularExpression(pattern: directionalPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            
            let latStr = String(text[Range(match.range(at: 1), in: text)!])
            let latDir = String(text[Range(match.range(at: 2), in: text)!]).uppercased()
            let lonStr = String(text[Range(match.range(at: 3), in: text)!])
            let lonDir = String(text[Range(match.range(at: 4), in: text)!]).uppercased()
            
            if let lat = Double(latStr), let lon = Double(lonStr) {
                let finalLat = latDir == "S" ? -lat : lat
                let finalLon = lonDir == "W" ? -lon : lon
                
                if isValidCoordinate(latitude: finalLat, longitude: finalLon) {
                    return (finalLat, finalLon)
                }
            }
        }
        
        // Pattern 3: "Lat:" / "Lon:" prefix format
        let latLonPattern = #"(?i)(?:lat|latitude)[:\s]+(-?\d+\.?\d*).*?(?:lon|lng|longitude)[:\s]+(-?\d+\.?\d*)"#
        
        if let regex = try? NSRegularExpression(pattern: latLonPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            
            let latStr = String(text[Range(match.range(at: 1), in: text)!])
            let lonStr = String(text[Range(match.range(at: 2), in: text)!])
            
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
    /// Uses top-left coordinates and correctly converts to CGImage bottom-left coordinates
    /// Returns: (croppedCGImage for OCR, croppedNSImage for display)
    nonisolated private func cropImageTopLeft(_ image: CGImage, imageSize: NSSize, to region: OCRRegion) -> (CGImage?, NSImage?) {
        let imageWidth = image.width
        let imageHeight = image.height
        
        // Calculate crop rectangle in pixels (using top-left origin, matching OCRRegion)
        let x = Int(region.x * Double(imageWidth))
        let topY = Int(region.y * Double(imageHeight))
        let width = Int(region.width * Double(imageWidth))
        let height = Int(region.height * Double(imageHeight))
        
        // Ensure coordinates are within image bounds
        let clampedX = max(0, min(x, imageWidth - 1))
        let clampedTopY = max(0, min(topY, imageHeight - 1))
        let clampedWidth = max(1, min(width, imageWidth - clampedX))
        let clampedHeight = max(1, min(height, imageHeight - clampedTopY))
        
        // Convert from top-left to bottom-left coordinates for CGImage.cropping(to:)
        // IMPORTANT: CGImage uses bottom-left origin where y=0 is at the bottom
        // CGImage.cropping(to:) uses y as the bottom edge of the crop rectangle
        //
        // For region.y = 0.9537 (from top), topY = 1030 means we want rows 1030-1079 from top
        // These are the bottom 50 rows of the image.
        //
        // In CGImage (bottom-left origin):
        // - Row 0 from top = Row (imageHeight - 1) from bottom
        // - Row 1030 from top = Row (imageHeight - 1 - 1030) = Row 49 from bottom  
        // - Row 1079 from top = Row 0 from bottom
        // So rows 1030-1079 from top = rows 49-0 from bottom
        // The bottom edge of the crop should be at row 0 from bottom, so y = 0
        //
        // General formula:
        // - If we want to crop starting at row topY from top with height h
        // - Bottom row of crop in top coords = topY + h - 1
        // - In bottom coords: row (imageHeight - 1 - (topY + h - 1)) = row (imageHeight - topY - h)
        // - So y = imageHeight - topY - h
        //
        // But wait - that gives y = 1080 - 1030 - 50 = 0, which should be correct!
        // However, the user says it's cropping from the top, not the bottom...
        //
        // Maybe the CGImage from NSImage is NOT in bottom-left origin? Let me test using
        // the topY value directly to see if that's the issue:
        // If using topY directly works, then the CGImage is in top-left origin
        // If using (imageHeight - topY - height) works, then CGImage is in bottom-left origin
        
        // CGImage.cropping(to:) uses bottom-left origin where y=0 is at the bottom
        // We need to convert from top-left (OCRRegion) to bottom-left (CGImage)
        // Formula: if we want rows topY to (topY + height - 1) from top,
        // in bottom-left coords, the bottom edge is at: imageHeight - topY - height
        let cgImageBottomY = imageHeight - clampedTopY - clampedHeight
        
        // Ensure Y is within bounds
        let clampedBottomY = max(0, min(cgImageBottomY, imageHeight - clampedHeight))
        
        // Create crop rectangle for CGImage (using bottom-left origin as CGImage expects)
        let cgCropRect = CGRect(x: clampedX, y: clampedBottomY, width: clampedWidth, height: clampedHeight)
        
        // Extract the cropped CGImage using CGImage's coordinate system
        guard let croppedCGImage = image.cropping(to: cgCropRect) else {
            return (nil, nil)
        }
        
        // The cropped CGImage is in bottom-left origin orientation, but we need top-left for OCR
        // Flip it vertically so it's in the correct orientation for Vision framework
        let flippedCGImage = flipCGImageVertically(croppedCGImage)
        
        // Create NSImage from flipped CGImage for display
        let flippedNSImage = NSImage(cgImage: flippedCGImage, size: NSSize(width: flippedCGImage.width, height: flippedCGImage.height))
        
        // Return the flipped CGImage for OCR (Vision framework expects top-left origin)
        return (flippedCGImage, flippedNSImage)
    }
    
    /// Flips a CGImage vertically (from bottom-left to top-left origin)
    /// This is needed because CGImage uses bottom-left origin but Vision framework expects top-left
    nonisolated private func flipCGImageVertically(_ cgImage: CGImage) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        
        // Create bitmap context to flip the image
        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: cgImage.bitsPerComponent,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else {
            // Fallback: return original if context creation fails
            return cgImage
        }
        
        // Flip vertically by translating and scaling
        // Move origin to top-left, then flip Y axis
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        // Draw the image (now flipped vertically)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Create flipped CGImage from context
        guard let flippedCGImage = context.makeImage() else {
            return cgImage
        }
        
        return flippedCGImage
    }
}

