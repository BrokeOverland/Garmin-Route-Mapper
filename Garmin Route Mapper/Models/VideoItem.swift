//
//  VideoItem.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import Foundation
import AVFoundation

/// Represents a video file with extracted GPS data
struct VideoItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let filename: String
    var gpsPoints: [GPSPoint]
    var extractionStatus: ExtractionStatus
    var currentFrameIndex: Int
    
    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.filename = url.lastPathComponent
        self.gpsPoints = []
        self.extractionStatus = .pending
        self.currentFrameIndex = 0
    }
    
    /// Total number of frames in the video
    var totalFrames: Int {
        return gpsPoints.count
    }
    
    /// Whether GPS data has been extracted
    var hasGPSData: Bool {
        return !gpsPoints.isEmpty && gpsPoints.contains { $0.isValid }
    }
}

/// Status of GPS extraction for a video
enum ExtractionStatus: String {
    case pending = "Pending"
    case extracting = "Extracting..."
    case completed = "Completed"
    case failed = "Failed - No GPS Data"
    case error = "Error"
}

/// Represents a GPS coordinate point with frame information
struct GPSPoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let frameNumber: Int
    let latitude: Double?
    let longitude: Double?
    let timestamp: Date
    let isValid: Bool
    let extractionMethod: ExtractionMethod
    
    nonisolated init(
        frameNumber: Int,
        latitude: Double?,
        longitude: Double?,
        timestamp: Date = Date(),
        extractionMethod: ExtractionMethod = .ocr
    ) {
        self.id = UUID()
        self.frameNumber = frameNumber
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.isValid = latitude != nil && longitude != nil &&
            latitude! >= -90 && latitude! <= 90 &&
            longitude! >= -180 && longitude! <= 180
        self.extractionMethod = extractionMethod
    }
    
    /// Creates an interpolated GPS point
    static func interpolated(
        frameNumber: Int,
        from point1: GPSPoint,
        to point2: GPSPoint
    ) -> GPSPoint {
        guard let lat1 = point1.latitude, let lon1 = point1.longitude,
              let lat2 = point2.latitude, let lon2 = point2.longitude else {
            return GPSPoint(
                frameNumber: frameNumber,
                latitude: nil,
                longitude: nil,
                extractionMethod: .interpolation
            )
        }
        
        // Linear interpolation
        let t = Double(frameNumber - point1.frameNumber) / Double(point2.frameNumber - point1.frameNumber)
        let lat = lat1 + (lat2 - lat1) * t
        let lon = lon1 + (lon2 - lon1) * t
        
        return GPSPoint(
            frameNumber: frameNumber,
            latitude: lat,
            longitude: lon,
            extractionMethod: .interpolation
        )
    }
}

/// Method used to extract GPS coordinates
enum ExtractionMethod: String, Codable, Sendable {
    case ocr = "OCR"
    case interpolation = "Interpolation"
    case smoothing = "Smoothing"
}

/// Route data for export
struct RouteData: Codable {
    let filename: String
    let coordinates: [[Double]] // [[lon, lat], ...] for GeoJSON
    let metadata: RouteMetadata
}

struct RouteMetadata: Codable {
    let totalFrames: Int
    let validFrames: Int
    let extractionDate: Date
}

