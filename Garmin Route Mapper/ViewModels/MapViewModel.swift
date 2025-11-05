//
//  MapViewModel.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import MapKit
import SwiftUI
import Combine

/// ViewModel for managing map display and route animation
@MainActor
class MapViewModel: ObservableObject {
    @Published var region = MKCoordinateRegion()
    @Published var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var currentPosition: CLLocationCoordinate2D?
    @Published var isAnimating = false
    
    private var animationTimer: Timer?
    
    /// Updates the route from GPS points
    func updateRoute(from gpsPoints: [GPSPoint]) {
        routeCoordinates = gpsPoints.compactMap { point -> CLLocationCoordinate2D? in
            guard point.isValid,
                  let lat = point.latitude,
                  let lon = point.longitude else {
                return nil
            }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        
        updateRegion()
    }
    
    /// Updates the map region to fit all route coordinates
    private func updateRegion() {
        guard !routeCoordinates.isEmpty else { return }
        
        // Filter out invalid coordinates
        let validCoordinates = routeCoordinates.filter { coordinate in
            coordinate.latitude.isFinite && 
            coordinate.longitude.isFinite &&
            abs(coordinate.latitude) <= 90.0 &&
            abs(coordinate.longitude) <= 180.0
        }
        
        guard !validCoordinates.isEmpty else { return }
        
        let latitudes = validCoordinates.map { $0.latitude }
        let longitudes = validCoordinates.map { $0.longitude }
        
        let minLat = latitudes.min()!
        let maxLat = latitudes.max()!
        let minLon = longitudes.min()!
        let maxLon = longitudes.max()!
        
        // Handle longitude wrapping
        var lonDelta = maxLon - minLon
        if lonDelta > 180.0 {
            // Coordinates wrap around the date line
            let altMinLon = minLon + 360.0
            let altMaxLon = maxLon
            let altLonDelta = altMaxLon - altMinLon
            if altLonDelta < lonDelta {
                lonDelta = altLonDelta
            }
        }
        
        let centerLat = (minLat + maxLat) / 2.0
        let centerLon = (minLon + maxLon) / 2.0
        
        // Calculate deltas with padding
        var latDelta = (maxLat - minLat) * 1.2
        lonDelta = lonDelta * 1.2
        
        // Ensure minimum spans for zoom level
        latDelta = max(latDelta, 0.01)
        lonDelta = max(lonDelta, 0.01)
        
        // Clamp spans to valid ranges
        // MKMapView allows up to 180 degrees for latitude span, but we'll cap it lower for better UX
        latDelta = min(latDelta, 170.0)
        // MKMapView allows up to 360 degrees for longitude span, but we'll cap it lower
        lonDelta = min(lonDelta, 350.0)
        
        // Ensure center is within valid ranges
        let clampedCenterLat = max(-90.0, min(90.0, centerLat))
        let clampedCenterLon = max(-180.0, min(180.0, centerLon))
        
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: clampedCenterLat, longitude: clampedCenterLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
    
    /// Updates current position based on video playback frame
    func updateCurrentPosition(frameIndex: Int, totalFrames: Int) {
        guard !routeCoordinates.isEmpty, totalFrames > 0 else {
            currentPosition = nil
            return
        }
        
        let progress = Double(frameIndex) / Double(max(totalFrames - 1, 1))
        let routeIndex = Int(progress * Double(routeCoordinates.count - 1))
        let clampedIndex = min(max(routeIndex, 0), routeCoordinates.count - 1)
        
        currentPosition = routeCoordinates[clampedIndex]
        
        // Optionally adjust map region to follow current position
        if let position = currentPosition {
            region.center = position
        }
    }
    
    /// Animates the route based on video playback time
    func animateRoute(
        videoTime: Double,
        videoDuration: Double,
        gpsPoints: [GPSPoint]
    ) {
        guard videoDuration > 0, !gpsPoints.isEmpty else { return }
        
        // Calculate frame number from video time (frames extracted at 30 FPS)
        // Frame number corresponds to the frame index used during extraction
        let frameRate: Double = 30.0 // Frames per second (matches VideoManager.extractFrames)
        let currentFrameNumber = Int(videoTime * frameRate)
        
        // GPS points are sorted by frameNumber, so we can use binary search
        var matchingPoint: GPSPoint?
        var closestValidIndex: Int?
        var minDistance = Int.max
        
        // Binary search for exact match or closest valid point
        var left = 0
        var right = gpsPoints.count - 1
        
        while left <= right {
            let mid = (left + right) / 2
            let midFrameNumber = gpsPoints[mid].frameNumber
            let midPoint = gpsPoints[mid]
            
            // Always track closest valid point as we search
            if midPoint.isValid {
                let distance: Int
                if midFrameNumber < currentFrameNumber {
                    distance = currentFrameNumber - midFrameNumber
                } else if midFrameNumber > currentFrameNumber {
                    distance = midFrameNumber - currentFrameNumber
                } else {
                    distance = 0 // Exact match
                }
                
                if distance < minDistance {
                    minDistance = distance
                    closestValidIndex = mid
                }
            }
            
            if midFrameNumber == currentFrameNumber {
                // Exact match found - check if valid before breaking
                if midPoint.isValid {
                    matchingPoint = midPoint
                    break
                }
                // Exact match but invalid - search adjacent points linearly for closest valid point
                // Since we're at the exact frame number, the closest valid point must be nearby
                var bestIndex: Int?
                var bestDistance = Int.max
                
                // Search forward and backward from exact match simultaneously
                var forwardIndex = mid + 1
                var backwardIndex = mid - 1
                var forwardExhausted = false
                var backwardExhausted = false
                
                // Search both directions, stopping each direction when it moves beyond best distance
                while !forwardExhausted || !backwardExhausted {
                    // Check forward
                    if !forwardExhausted && forwardIndex < gpsPoints.count {
                        let forwardPoint = gpsPoints[forwardIndex]
                        let forwardDistance = forwardPoint.frameNumber - currentFrameNumber
                        
                        if forwardPoint.isValid {
                            if bestIndex == nil || forwardDistance < bestDistance {
                                bestDistance = forwardDistance
                                bestIndex = forwardIndex
                            }
                        }
                        
                        // Stop searching forward if we've moved beyond the best distance
                        if bestIndex != nil && forwardDistance > bestDistance {
                            forwardExhausted = true
                        } else {
                            forwardIndex += 1
                        }
                    } else {
                        forwardExhausted = true
                    }
                    
                    // Check backward
                    if !backwardExhausted && backwardIndex >= 0 {
                        let backwardPoint = gpsPoints[backwardIndex]
                        let backwardDistance = currentFrameNumber - backwardPoint.frameNumber
                        
                        if backwardPoint.isValid {
                            if bestIndex == nil || backwardDistance < bestDistance {
                                bestDistance = backwardDistance
                                bestIndex = backwardIndex
                            }
                        }
                        
                        // Stop searching backward if we've moved beyond the best distance
                        if bestIndex != nil && backwardDistance > bestDistance {
                            backwardExhausted = true
                        } else {
                            backwardIndex -= 1
                        }
                    } else {
                        backwardExhausted = true
                    }
                }
                
                // Use the closest valid point found, or fall back to closestValidIndex from binary search
                if let best = bestIndex {
                    matchingPoint = gpsPoints[best]
                }
                break // Found exact match location, done searching
            } else if midFrameNumber < currentFrameNumber {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        
        // If exact match found but invalid, or no exact match, use closest valid point
        if matchingPoint == nil || !(matchingPoint?.isValid ?? false) {
            if let closestIndex = closestValidIndex {
                matchingPoint = gpsPoints[closestIndex]
            } else {
                // Fallback: find any valid point
                matchingPoint = gpsPoints.first(where: { $0.isValid })
            }
        }
        
        // Update current position if we found a valid point
        if let point = matchingPoint, point.isValid,
           let lat = point.latitude, let lon = point.longitude {
            currentPosition = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            currentPosition = nil
        }
    }
    
    /// Clears the route and resets the map
    func clearRoute() {
        routeCoordinates = []
        currentPosition = nil
        region = MKCoordinateRegion()
    }
    
    deinit {
        animationTimer?.invalidate()
    }
}

