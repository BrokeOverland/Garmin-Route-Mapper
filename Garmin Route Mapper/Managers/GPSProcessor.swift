//
//  GPSProcessor.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import Foundation

/// Processes GPS coordinates: validation, interpolation, and smoothing
@MainActor
class GPSProcessor {
    
    /// Processes GPS points with interpolation and optional smoothing
    func processGPSPoints(
        _ points: [GPSPoint],
        interpolate: Bool = true,
        smooth: Bool = false,
        smoothingWindow: Int = 5
    ) -> [GPSPoint] {
        var processed = points
        
        // Step 1: Interpolate missing points
        if interpolate {
            processed = interpolateMissingPoints(processed)
        }
        
        // Step 2: Smooth points if requested
        if smooth {
            processed = smoothPoints(processed, windowSize: smoothingWindow)
        }
        
        return processed
    }
    
    /// Interpolates missing GPS points by averaging previous and next valid frames
    private func interpolateMissingPoints(_ points: [GPSPoint]) -> [GPSPoint] {
        guard !points.isEmpty else { return points }
        
        var interpolated: [GPSPoint] = []
        var lastValidPoint: GPSPoint?
        var pendingInvalidPoints: [(Int, GPSPoint)] = []
        
        for point in points {
            if point.isValid {
                // If we have pending invalid points, interpolate them
                if !pendingInvalidPoints.isEmpty, let prevValid = lastValidPoint {
                    for (_, invalidPoint) in pendingInvalidPoints {
                        let interpolatedPoint = GPSPoint.interpolated(
                            frameNumber: invalidPoint.frameNumber,
                            from: prevValid,
                            to: point
                        )
                        interpolated.append(interpolatedPoint)
                    }
                    pendingInvalidPoints.removeAll()
                }
                
                interpolated.append(point)
                lastValidPoint = point
            } else {
                // Track invalid points for interpolation
                pendingInvalidPoints.append((interpolated.count, point))
                interpolated.append(point) // Keep original for now
            }
        }
        
        // Handle remaining invalid points at the end by using the last valid point
        if !pendingInvalidPoints.isEmpty, let lastValid = lastValidPoint {
            for (index, invalidPoint) in pendingInvalidPoints {
                let interpolatedPoint = GPSPoint(
                    frameNumber: invalidPoint.frameNumber,
                    latitude: lastValid.latitude,
                    longitude: lastValid.longitude,
                    timestamp: invalidPoint.timestamp,
                    extractionMethod: .interpolation
                )
                // Replace in interpolated array
                if index < interpolated.count {
                    interpolated[index] = interpolatedPoint
                }
            }
        }
        
        return interpolated
    }
    
    /// Smooths GPS points using a moving average window
    private func smoothPoints(_ points: [GPSPoint], windowSize: Int) -> [GPSPoint] {
        guard windowSize > 1, points.count > 1 else { return points }
        
        var smoothed: [GPSPoint] = []
        let halfWindow = windowSize / 2
        
        for i in 0..<points.count {
            let point = points[i]
            
            // If point is invalid, keep it as is
            guard point.isValid, let _ = point.latitude, let _ = point.longitude else {
                smoothed.append(point)
                continue
            }
            
            // Collect valid points in the window
            var validPoints: [(lat: Double, lon: Double)] = []
            let startIndex = max(0, i - halfWindow)
            let endIndex = min(points.count - 1, i + halfWindow)
            
            for j in startIndex...endIndex {
                if let windowPoint = points[safe: j], windowPoint.isValid,
                   let windowLat = windowPoint.latitude, let windowLon = windowPoint.longitude {
                    validPoints.append((windowLat, windowLon))
                }
            }
            
            if validPoints.count > 1 {
                // Calculate average
                let avgLat = validPoints.map { $0.lat }.reduce(0, +) / Double(validPoints.count)
                let avgLon = validPoints.map { $0.lon }.reduce(0, +) / Double(validPoints.count)
                
                let smoothedPoint = GPSPoint(
                    frameNumber: point.frameNumber,
                    latitude: avgLat,
                    longitude: avgLon,
                    timestamp: point.timestamp,
                    extractionMethod: .smoothing
                )
                smoothed.append(smoothedPoint)
            } else {
                smoothed.append(point)
            }
        }
        
        return smoothed
    }
    
    /// Filters out invalid points and validates the route
    func validateRoute(_ points: [GPSPoint]) -> [GPSPoint] {
        return points.filter { $0.isValid }
    }
    
    /// Simplifies route by removing points that are too close together
    func simplifyRoute(_ points: [GPSPoint], minimumDistance: Double = 0.0001) -> [GPSPoint] {
        guard points.count > 2 else { return points }
        
        var simplified: [GPSPoint] = [points[0]]
        
        for i in 1..<points.count - 1 {
            let prev = simplified.last!
            let current = points[i]
            
            if let prevLat = prev.latitude, let prevLon = prev.longitude,
               let currLat = current.latitude, let currLon = current.longitude {
                
                let distance = calculateDistance(
                    lat1: prevLat, lon1: prevLon,
                    lat2: currLat, lon2: currLon
                )
                
                if distance >= minimumDistance {
                    simplified.append(current)
                }
            } else if !current.isValid {
                simplified.append(current)
            }
        }
        
        // Always include the last point
        if let last = points.last {
            simplified.append(last)
        }
        
        return simplified
    }
    
    /// Calculates distance between two coordinates using Haversine formula (approximate)
    private func calculateDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius: Double = 6371000 // meters
        
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        
        let a = sin(dLat / 2.0) * sin(dLat / 2.0) +
                cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
                sin(dLon / 2.0) * sin(dLon / 2.0)
        
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        
        return earthRadius * c
    }
}

extension Array {
    /// Safe array access
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

