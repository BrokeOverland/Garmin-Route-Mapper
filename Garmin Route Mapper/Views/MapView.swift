//
//  MapView.swift
//  Garmin Route Mapper
//
//  Created by Chad Lynch on 10/31/25.
//

import SwiftUI
import MapKit
import AppKit

/// MapKit view showing route and current position
struct MapView: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var routeCoordinates: [CLLocationCoordinate2D]
    var currentPosition: CLLocationCoordinate2D?
    
    /// Validates that a region is valid for MKMapView
    private func isValidRegion(_ region: MKCoordinateRegion) -> Bool {
        // Check center coordinates are valid and within bounds
        guard region.center.latitude.isFinite && region.center.longitude.isFinite else {
            return false
        }
        
        guard abs(region.center.latitude) <= 90.0 && abs(region.center.longitude) <= 180.0 else {
            return false
        }
        
        // Check spans are valid and within bounds
        guard region.span.latitudeDelta.isFinite && region.span.longitudeDelta.isFinite else {
            return false
        }
        
        guard region.span.latitudeDelta > 0 && region.span.longitudeDelta > 0 else {
            return false
        }
        
        // MKMapView limits: latitude span <= 180, longitude span <= 360
        guard region.span.latitudeDelta <= 180.0 && region.span.longitudeDelta <= 360.0 else {
            return false
        }
        
        // Check that the region doesn't extend beyond valid coordinate bounds
        let minLat = region.center.latitude - region.span.latitudeDelta / 2.0
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2.0
        
        // For latitude, we need to ensure it stays within -90 to 90
        // For longitude, wrapping is allowed, but we'll check if it's reasonable
        guard minLat >= -90.0 && maxLat <= 90.0 else {
            return false
        }
        
        return true
    }
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        // Defer initial region setting until view is laid out
        DispatchQueue.main.async {
            if mapView.bounds.width > 0 && mapView.bounds.height > 0 && isValidRegion(region) {
                mapView.setRegion(region, animated: false)
            }
        }
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        
        return mapView
    }
    
    func updateNSView(_ mapView: MKMapView, context: Context) {
        // Check if view has valid bounds before updating
        guard mapView.bounds.width > 0 && mapView.bounds.height > 0 else {
            // Skip updates until view has valid bounds (will be called again when layout completes)
            return
        }
        
        // Validate region before using it
        guard isValidRegion(region) else {
            // If region is invalid, try to fit map to route using visible map rect instead
            if !routeCoordinates.isEmpty {
                let validCoordinates = routeCoordinates.filter { coordinate in
                    coordinate.latitude.isFinite && 
                    coordinate.longitude.isFinite &&
                    abs(coordinate.latitude) <= 90.0 &&
                    abs(coordinate.longitude) <= 180.0
                }
                
                if !validCoordinates.isEmpty {
                    // Remove existing overlays and annotations first
                    mapView.removeOverlays(mapView.overlays)
                    mapView.removeAnnotations(mapView.annotations)
                    
                    // Add route polyline
                    let polyline = MKPolyline(coordinates: validCoordinates, count: validCoordinates.count)
                    mapView.addOverlay(polyline)
                    
                    // Add current position marker
                    if let position = currentPosition, 
                       position.latitude.isFinite && 
                       position.longitude.isFinite &&
                       abs(position.latitude) <= 90.0 &&
                       abs(position.longitude) <= 180.0 {
                        let annotation = MKPointAnnotation()
                        annotation.coordinate = position
                        annotation.title = "Current Position"
                        mapView.addAnnotation(annotation)
                    }
                    
                    // Fit map to route using visible map rect
                    DispatchQueue.main.async {
                        let rect = polyline.boundingMapRect
                        if rect.width > 0 && rect.height > 0 {
                            mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), animated: false)
                        }
                    }
                }
            }
            return
        }
        
        // Check if region changed significantly to avoid unnecessary updates
        let currentRegion = mapView.region
        let regionChanged = abs(currentRegion.center.latitude - region.center.latitude) > 0.001 ||
                            abs(currentRegion.center.longitude - region.center.longitude) > 0.001 ||
                            abs(currentRegion.span.latitudeDelta - region.span.latitudeDelta) > 0.001 ||
                            abs(currentRegion.span.longitudeDelta - region.span.longitudeDelta) > 0.001
        
        // Remove existing overlays and annotations first
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        
        // Add route polyline
        var polyline: MKPolyline?
        if !routeCoordinates.isEmpty {
            polyline = MKPolyline(coordinates: routeCoordinates, count: routeCoordinates.count)
            mapView.addOverlay(polyline!)
        }
        
        // Add current position marker
        if let position = currentPosition {
            let annotation = MKPointAnnotation()
            annotation.coordinate = position
            annotation.title = "Current Position"
            mapView.addAnnotation(annotation)
        }
        
        // Defer layout-triggering updates to avoid reentrant layout issues
        DispatchQueue.main.async {
            // Update region only if changed and valid
            if regionChanged && isValidRegion(region) {
                mapView.setRegion(region, animated: false)
            }
            
            // Fit map to route after adding overlay
            if let polyline = polyline {
                let rect = polyline.boundingMapRect
                if rect.width > 0 && rect.height > 0 {
                    mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), animated: false)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3.0
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "CurrentPosition"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = true
            } else {
                annotationView?.annotation = annotation
            }
            
            // Custom pin for current position
            if let image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Current Position") {
                annotationView?.image = image
            }
            
            return annotationView
        }
    }
}

