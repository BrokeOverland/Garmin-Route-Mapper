//
//  ExportManager.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import Foundation

/// Manages export of GPS data to GeoJSON and CSV formats
@MainActor
class ExportManager {
    
    /// Exports video data to GeoJSON format
    func exportGeoJSON(
        videoItems: [VideoItem],
        to url: URL
    ) throws {
        var features: [[String: Any]] = []
        
        for videoItem in videoItems {
            guard videoItem.hasGPSData else { continue }
            
            // Filter valid coordinates
            let validPoints = videoItem.gpsPoints.filter { $0.isValid }
            guard !validPoints.isEmpty else { continue }
            
            // Convert to GeoJSON format: [lon, lat]
            let coordinates = validPoints.compactMap { point -> [Double]? in
                guard let lat = point.latitude, let lon = point.longitude else { return nil }
                return [lon, lat] // GeoJSON uses [longitude, latitude]
            }
            
            if !coordinates.isEmpty {
                let feature: [String: Any] = [
                    "type": "Feature",
                    "properties": [
                        "name": videoItem.filename,
                        "extractionDate": ISO8601DateFormatter().string(from: Date()),
                        "totalFrames": videoItem.totalFrames,
                        "validFrames": validPoints.count
                    ],
                    "geometry": [
                        "type": "LineString",
                        "coordinates": coordinates
                    ]
                ]
                features.append(feature)
            }
        }
        
        let geoJSON: [String: Any] = [
            "type": "FeatureCollection",
            "features": features
        ]
        
        let jsonData = try JSONSerialization.data(
            withJSONObject: geoJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        
        // Write file atomically
        try jsonData.write(to: url, options: [.atomic])
    }
    
    /// Exports video data to CSV format with frame-by-frame details
    func exportCSV(
        videoItems: [VideoItem],
        to url: URL
    ) throws {
        var csvLines: [String] = []
        
        // CSV Header
        csvLines.append("filename,frame_number,latitude,longitude,extraction_status,extraction_method,timestamp")
        
        // CSV Rows
        for videoItem in videoItems {
            if videoItem.gpsPoints.isEmpty {
                // No GPS data extracted
                csvLines.append(formatCSVRow(
                    filename: videoItem.filename,
                    frameNumber: 0,
                    latitude: nil,
                    longitude: nil,
                    status: videoItem.extractionStatus.rawValue,
                    method: nil
                ))
            } else {
                // Frame-by-frame data
                for point in videoItem.gpsPoints {
                    let status = point.isValid ? "Valid" : "Invalid"
                    csvLines.append(formatCSVRow(
                        filename: videoItem.filename,
                        frameNumber: point.frameNumber,
                        latitude: point.latitude,
                        longitude: point.longitude,
                        status: status,
                        method: point.extractionMethod.rawValue
                    ))
                }
            }
        }
        
        let csvContent = csvLines.joined(separator: "\n")
        
        guard let csvData = csvContent.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        
        // Write file atomically
        try csvData.write(to: url, options: [.atomic])
    }
    
    /// Formats a CSV row with proper escaping
    private func formatCSVRow(
        filename: String,
        frameNumber: Int,
        latitude: Double?,
        longitude: Double?,
        status: String,
        method: String?
    ) -> String {
        let latStr = latitude != nil ? String(latitude!) : ""
        let lonStr = longitude != nil ? String(longitude!) : ""
        let methodStr = method ?? ""
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        // Escape commas and quotes in filename
        let escapedFilename = filename.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: ",", with: ",")
        
        return "\"\(escapedFilename)\",\(frameNumber),\(latStr),\(lonStr),\"\(status)\",\"\(methodStr)\",\(timestamp)"
    }
    
    /// Exports both GeoJSON and CSV to a directory
    func exportAll(
        videoItems: [VideoItem],
        to directory: URL,
        geoJSONFilename: String = "routes.geojson",
        csvFilename: String = "gps_log.csv"
    ) throws {
        // Ensure export directory exists
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        
        let geoJSONURL = directory.appendingPathComponent(geoJSONFilename)
        let csvURL = directory.appendingPathComponent(csvFilename)
        
        try exportGeoJSON(videoItems: videoItems, to: geoJSONURL)
        try exportCSV(videoItems: videoItems, to: csvURL)
    }
}

enum ExportError: Error, LocalizedError {
    case encodingFailed
    case writeFailed
    
    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode export data"
        case .writeFailed:
            return "Failed to write export file"
        }
    }
}

