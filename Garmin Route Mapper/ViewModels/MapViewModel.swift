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
        guard videoDuration > 0 else { return }
        
        let progress = videoTime / videoDuration
        let frameIndex = Int(progress * Double(max(gpsPoints.count - 1, 0)))
        let clampedIndex = min(max(frameIndex, 0), gpsPoints.count - 1)
        
        if clampedIndex < gpsPoints.count {
            let point = gpsPoints[clampedIndex]
            if point.isValid, let lat = point.latitude, let lon = point.longitude {
                currentPosition = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                
                // The view will update the displayed route based on currentPosition
            }
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

