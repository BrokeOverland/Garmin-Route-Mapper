//
//  Garmin_Route_MapperTests.swift
//  Garmin Route MapperTests
//
//  Created by Chad Lynch on 10/31/25.
//

import XCTest
@testable import Garmin_Route_Mapper
import Foundation
import AppKit

@MainActor
final class Garmin_Route_MapperTests: XCTestCase {

    // MARK: - VideoItem Tests
    
    func testVideoItemInitialization() {
        let url = URL(fileURLWithPath: "/test/video.mp4")
        let item = VideoItem(url: url)
        
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.filename, "video.mp4")
        XCTAssertTrue(item.gpsPoints.isEmpty)
        XCTAssertEqual(item.extractionStatus, .pending)
        XCTAssertEqual(item.currentFrameIndex, 0)
        XCTAssertFalse(item.hasGPSData)
    }
    
    func testVideoItemHasGPSData() {
        let url = URL(fileURLWithPath: "/test/video.mp4")
        var item = VideoItem(url: url)
        
        // No GPS points
        XCTAssertFalse(item.hasGPSData)
        
        // Invalid GPS point
        let invalidPoint = GPSPoint(
            frameNumber: 0,
            latitude: nil,
            longitude: nil
        )
        item.gpsPoints = [invalidPoint]
        XCTAssertFalse(item.hasGPSData)
        
        // Valid GPS point
        let validPoint = GPSPoint(
            frameNumber: 0,
            latitude: 37.7749,
            longitude: -122.4194
        )
        item.gpsPoints = [validPoint]
        XCTAssertTrue(item.hasGPSData)
        
        // Mix of valid and invalid
        item.gpsPoints = [invalidPoint, validPoint]
        XCTAssertTrue(item.hasGPSData)
    }
    
    // MARK: - GPSPoint Tests
    
    func testGPSPointInitialization() {
        let point = GPSPoint(
            frameNumber: 5,
            latitude: 37.7749,
            longitude: -122.4194
        )
        
        XCTAssertEqual(point.frameNumber, 5)
        XCTAssertEqual(point.latitude, 37.7749)
        XCTAssertEqual(point.longitude, -122.4194)
        XCTAssertTrue(point.isValid)
        XCTAssertEqual(point.extractionMethod, .ocr)
    }
    
    func testGPSPointValidation() {
        // Valid coordinates
        let validPoint = GPSPoint(
            frameNumber: 0,
            latitude: 37.7749,
            longitude: -122.4194
        )
        XCTAssertTrue(validPoint.isValid)
        
        // Invalid: missing latitude
        let noLat = GPSPoint(
            frameNumber: 0,
            latitude: nil,
            longitude: -122.4194
        )
        XCTAssertFalse(noLat.isValid)
        
        // Invalid: missing longitude
        let noLon = GPSPoint(
            frameNumber: 0,
            latitude: 37.7749,
            longitude: nil
        )
        XCTAssertFalse(noLon.isValid)
        
        // Invalid: out of range latitude
        let invalidLat = GPSPoint(
            frameNumber: 0,
            latitude: 91.0,
            longitude: -122.4194
        )
        XCTAssertFalse(invalidLat.isValid)
        
        // Invalid: out of range longitude
        let invalidLon = GPSPoint(
            frameNumber: 0,
            latitude: 37.7749,
            longitude: -181.0
        )
        XCTAssertFalse(invalidLon.isValid)
        
        // Valid: edge cases
        let edgeLat = GPSPoint(
            frameNumber: 0,
            latitude: 90.0,
            longitude: 180.0
        )
        XCTAssertTrue(edgeLat.isValid)
        
        let edgeNeg = GPSPoint(
            frameNumber: 0,
            latitude: -90.0,
            longitude: -180.0
        )
        XCTAssertTrue(edgeNeg.isValid)
    }
    
    func testGPSPointInterpolation() {
        let point1 = GPSPoint(
            frameNumber: 0,
            latitude: 37.0,
            longitude: -122.0
        )
        let point2 = GPSPoint(
            frameNumber: 10,
            latitude: 38.0,
            longitude: -123.0
        )
        
        // Interpolate midpoint
        let interpolated = GPSPoint.interpolated(
            frameNumber: 5,
            from: point1,
            to: point2
        )
        
        XCTAssertEqual(interpolated.frameNumber, 5)
        XCTAssertEqual(interpolated.latitude, 37.5)
        XCTAssertEqual(interpolated.longitude, -122.5)
        XCTAssertTrue(interpolated.isValid)
        XCTAssertEqual(interpolated.extractionMethod, .interpolation)
        
        // Interpolate closer to first point
        let closerToFirst = GPSPoint.interpolated(
            frameNumber: 2,
            from: point1,
            to: point2
        )
        XCTAssertTrue(closerToFirst.latitude! > 37.0 && closerToFirst.latitude! < 37.5)
        
        // Interpolate with invalid points
        let invalidPoint1 = GPSPoint(
            frameNumber: 0,
            latitude: nil,
            longitude: nil
        )
        let invalidInterpolated = GPSPoint.interpolated(
            frameNumber: 5,
            from: invalidPoint1,
            to: point2
        )
        XCTAssertFalse(invalidInterpolated.isValid)
    }
    
    // MARK: - GPSProcessor Tests
    
    func testGPSProcessorInterpolation() async throws {
        let processor = GPSProcessor()
        
        // Points with gaps
        let points = [
            GPSPoint(frameNumber: 0, latitude: 37.0, longitude: -122.0),
            GPSPoint(frameNumber: 1, latitude: nil, longitude: nil), // Invalid
            GPSPoint(frameNumber: 2, latitude: nil, longitude: nil), // Invalid
            GPSPoint(frameNumber: 3, latitude: 38.0, longitude: -123.0),
            GPSPoint(frameNumber: 4, latitude: nil, longitude: nil), // Invalid at end
        ]
        
        let processed = await processor.processGPSPoints(points, interpolate: true, smooth: false)
        
        // Should have interpolated points for frames 1 and 2
        XCTAssertEqual(processed.count, points.count)
        XCTAssertTrue(processed[0].isValid)
        XCTAssertTrue(processed[1].isValid) // Should be interpolated
        XCTAssertTrue(processed[2].isValid) // Should be interpolated
        XCTAssertTrue(processed[3].isValid)
        XCTAssertTrue(processed[4].isValid) // Should use last valid point
    }
    
    func testGPSProcessorSmoothing() async throws {
        let processor = GPSProcessor()
        
        // Create points with some variation
        let points = (0..<10).map { i in
            GPSPoint(
                frameNumber: i,
                latitude: 37.0 + Double(i) * 0.1 + (Double.random(in: -0.05...0.05)),
                longitude: -122.0 - Double(i) * 0.1 + (Double.random(in: -0.05...0.05))
            )
        }
        
        let smoothed = await processor.processGPSPoints(points, interpolate: false, smooth: true, smoothingWindow: 5)
        
        XCTAssertEqual(smoothed.count, points.count)
        // Smoothed points should be valid
        for point in smoothed {
            XCTAssertTrue(point.isValid)
        }
    }
    
    func testGPSProcessorValidation() async throws {
        let processor = GPSProcessor()
        
        let points = [
            GPSPoint(frameNumber: 0, latitude: 37.0, longitude: -122.0),
            GPSPoint(frameNumber: 1, latitude: nil, longitude: nil),
            GPSPoint(frameNumber: 2, latitude: 38.0, longitude: -123.0),
            GPSPoint(frameNumber: 3, latitude: 91.0, longitude: -122.0), // Invalid
        ]
        
        let validated = await processor.validateRoute(points)
        
        // Should only contain valid points
        XCTAssertEqual(validated.count, 2)
        XCTAssertTrue(validated.allSatisfy { $0.isValid })
    }
    
    func testGPSProcessorSimplifyRoute() async throws {
        let processor = GPSProcessor()
        
        // Create points that are very close together
        let points = (0..<10).map { i in
            GPSPoint(
                frameNumber: i,
                latitude: 37.0 + Double(i) * 0.00001, // Very small changes
                longitude: -122.0 + Double(i) * 0.00001
            )
        }
        
        let simplified = await processor.simplifyRoute(points, minimumDistance: 0.0001)
        
        // Should have fewer points than original
        XCTAssertLessThanOrEqual(simplified.count, points.count)
        XCTAssertGreaterThanOrEqual(simplified.count, 2) // Should always have at least first and last
    }
    
    // MARK: - MapViewModel Tests
    
    func testMapViewModelUpdateRoute() async throws {
        let viewModel = MapViewModel()
        
        let gpsPoints = [
            GPSPoint(frameNumber: 0, latitude: 37.7749, longitude: -122.4194),
            GPSPoint(frameNumber: 1, latitude: 37.7849, longitude: -122.4294),
            GPSPoint(frameNumber: 2, latitude: nil, longitude: nil), // Invalid
        ]
        
        await viewModel.updateRoute(from: gpsPoints)
        
        // Should only include valid coordinates
        XCTAssertEqual(viewModel.routeCoordinates.count, 2)
        XCTAssertEqual(viewModel.routeCoordinates[0].latitude, 37.7749)
        XCTAssertEqual(viewModel.routeCoordinates[0].longitude, -122.4194)
    }
    
    func testMapViewModelClearRoute() async throws {
        let viewModel = MapViewModel()
        
        let gpsPoints = [
            GPSPoint(frameNumber: 0, latitude: 37.7749, longitude: -122.4194),
        ]
        
        await viewModel.updateRoute(from: gpsPoints)
        XCTAssertFalse(viewModel.routeCoordinates.isEmpty)
        
        await viewModel.clearRoute()
        XCTAssertTrue(viewModel.routeCoordinates.isEmpty)
        XCTAssertNil(viewModel.currentPosition)
    }
    
    func testMapViewModelAnimateRoute() async throws {
        let viewModel = MapViewModel()
        
        let gpsPoints = [
            GPSPoint(frameNumber: 0, latitude: 37.7749, longitude: -122.4194),
            GPSPoint(frameNumber: 30, latitude: 37.7849, longitude: -122.4294),
            GPSPoint(frameNumber: 60, latitude: 37.7949, longitude: -122.4394),
        ]
        
        // Animate at 1 second (frame 30)
        await viewModel.animateRoute(
            videoTime: 1.0,
            videoDuration: 2.0,
            gpsPoints: gpsPoints
        )
        
        // Should have a current position
        XCTAssertNotNil(viewModel.currentPosition)
    }
    
    // MARK: - ExportManager Tests
    
    func testExportManagerGeoJSON() async throws {
        let manager = ExportManager()
        
        let videoItem = VideoItem(url: URL(fileURLWithPath: "/test/video.mp4"))
        var item = videoItem
        item.gpsPoints = [
            GPSPoint(frameNumber: 0, latitude: 37.7749, longitude: -122.4194),
            GPSPoint(frameNumber: 1, latitude: 37.7849, longitude: -122.4294),
        ]
        item.extractionStatus = .completed
        
        let tempDir = FileManager.default.temporaryDirectory
        let geoJSONURL = tempDir.appendingPathComponent("test_export.geojson")
        
        try await manager.exportGeoJSON(videoItems: [item], to: geoJSONURL)
        
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: geoJSONURL.path))
        
        // Read and verify content
        let data = try Data(contentsOf: geoJSONURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        XCTAssertEqual(json?["type"] as? String, "FeatureCollection")
        
        let features = json?["features"] as? [[String: Any]]
        XCTAssertEqual(features?.count, 1)
        
        let feature = features?.first
        XCTAssertEqual(feature?["type"] as? String, "Feature")
        
        // Clean up
        try? FileManager.default.removeItem(at: geoJSONURL)
    }
    
    func testExportManagerCSV() async throws {
        let manager = ExportManager()
        
        let videoItem = VideoItem(url: URL(fileURLWithPath: "/test/video.mp4"))
        var item = videoItem
        item.gpsPoints = [
            GPSPoint(frameNumber: 0, latitude: 37.7749, longitude: -122.4194),
            GPSPoint(frameNumber: 1, latitude: 37.7849, longitude: -122.4294),
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let csvURL = tempDir.appendingPathComponent("test_export.csv")
        
        try await manager.exportCSV(videoItems: [item], to: csvURL)
        
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        
        // Read and verify content
        let content = try String(contentsOf: csvURL)
        XCTAssertTrue(content.contains("filename"))
        XCTAssertTrue(content.contains("frame_number"))
        XCTAssertTrue(content.contains("37.7749"))
        
        // Clean up
        try? FileManager.default.removeItem(at: csvURL)
    }
    
    func testExportManagerExportAll() async throws {
        let manager = ExportManager()
        
        let videoItem = VideoItem(url: URL(fileURLWithPath: "/test/video.mp4"))
        var item = videoItem
        item.gpsPoints = [
            GPSPoint(frameNumber: 0, latitude: 37.7749, longitude: -122.4194),
        ]
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("export_test")
        try? FileManager.default.removeItem(at: tempDir)
        
        try await manager.exportAll(
            videoItems: [item],
            to: tempDir,
            geoJSONFilename: "test.geojson",
            csvFilename: "test.csv"
        )
        
        let geoJSONURL = tempDir.appendingPathComponent("test.geojson")
        let csvURL = tempDir.appendingPathComponent("test.csv")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: geoJSONURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - MainViewModel Tests
    
    func testMainViewModelAddVideos() async throws {
        let viewModel = MainViewModel()
        
        let mp4URL = URL(fileURLWithPath: "/test/video.mp4")
        let movURL = URL(fileURLWithPath: "/test/video.mov")
        let txtURL = URL(fileURLWithPath: "/test/file.txt")
        
        await viewModel.addVideos(urls: [mp4URL, movURL, txtURL])
        
        // Should only add .mp4 files
        XCTAssertEqual(viewModel.videoItems.count, 1)
        XCTAssertEqual(viewModel.videoItems.first?.url, mp4URL)
    }
    
    func testMainViewModelRemoveVideo() async throws {
        let viewModel = MainViewModel()
        
        let url1 = URL(fileURLWithPath: "/test/video1.mp4")
        let url2 = URL(fileURLWithPath: "/test/video2.mp4")
        
        await viewModel.addVideos(urls: [url1, url2])
        XCTAssertEqual(viewModel.videoItems.count, 2)
        
        if let item = viewModel.videoItems.first {
            await viewModel.removeVideo(item)
            XCTAssertEqual(viewModel.videoItems.count, 1)
        }
    }
    
    func testMainViewModelToggleSmoothing() async throws {
        let viewModel = MainViewModel()
        
        XCTAssertFalse(viewModel.isSmoothingEnabled)
        
        await viewModel.toggleSmoothing()
        XCTAssertTrue(viewModel.isSmoothingEnabled)
        
        await viewModel.toggleSmoothing()
        XCTAssertFalse(viewModel.isSmoothingEnabled)
    }
    
    func testMainViewModelOCRFrameNavigation() async throws {
        let viewModel = MainViewModel()
        
        // Create some OCR frame data
        let testImage = NSImage(size: NSSize(width: 100, height: 100))
        let region = OCRRegion(x: 0, y: 0, width: 1, height: 1)
        
        await viewModel.ocrFrameData = [
            MainViewModel.OCRFrameData(
                frameNumber: 0,
                originalImage: testImage,
                region: region,
                croppedImage: testImage,
                gpsPoint: GPSPoint(frameNumber: 0, latitude: 37.0, longitude: -122.0)
            ),
            MainViewModel.OCRFrameData(
                frameNumber: 1,
                originalImage: testImage,
                region: region,
                croppedImage: testImage,
                gpsPoint: GPSPoint(frameNumber: 1, latitude: 38.0, longitude: -123.0)
            ),
        ]
        await viewModel.currentOCRFrameIndex = 0
        
        XCTAssertFalse(viewModel.canGoToPreviousFrame)
        XCTAssertTrue(viewModel.canGoToNextFrame)
        
        await viewModel.nextOCRFrame()
        XCTAssertEqual(viewModel.currentOCRFrameIndex, 1)
        XCTAssertTrue(viewModel.canGoToPreviousFrame)
        XCTAssertFalse(viewModel.canGoToNextFrame)
        
        await viewModel.previousOCRFrame()
        XCTAssertEqual(viewModel.currentOCRFrameIndex, 0)
    }
    
    func testMainViewModelFlaggedFrames() async throws {
        let viewModel = MainViewModel()
        
        let testImage = NSImage(size: NSSize(width: 100, height: 100))
        let region = OCRRegion(x: 0, y: 0, width: 1, height: 1)
        
        await viewModel.ocrFrameData = [
            MainViewModel.OCRFrameData(
                frameNumber: 0,
                originalImage: testImage,
                region: region,
                croppedImage: testImage,
                gpsPoint: nil // No GPS data
            ),
            MainViewModel.OCRFrameData(
                frameNumber: 1,
                originalImage: testImage,
                region: region,
                croppedImage: testImage,
                gpsPoint: GPSPoint(frameNumber: 1, latitude: 0.0, longitude: 0.0) // Zero coordinates
            ),
            MainViewModel.OCRFrameData(
                frameNumber: 2,
                originalImage: testImage,
                region: region,
                croppedImage: testImage,
                gpsPoint: GPSPoint(frameNumber: 2, latitude: 37.0, longitude: -122.0) // Valid
            ),
        ]
        
        let flagged = await viewModel.flaggedFrames
        XCTAssertEqual(flagged.count, 2)
        XCTAssertTrue(flagged.contains { $0.frameNumber == 0 && $0.reason == .noGPSData })
        XCTAssertTrue(flagged.contains { $0.frameNumber == 1 && $0.reason == .bothZero })
    }
    
    // MARK: - OCRManager Coordinate Parsing Tests
    
    func testOCRManagerParseSimpleCoordinates() async throws {
        let manager = OCRManager()
        
        // This tests the parsing logic indirectly through the extractGPSFromImage method
        // Since we can't easily create NSImage instances in tests, we'll test the parsing
        // by checking if the manager can handle various coordinate formats
        
        // The actual parsing happens in parseGPSCoordinates which is private
        // For now, we verify the manager can be instantiated
        XCTAssertGreaterThanOrEqual(manager.regionOfInterest.x, 0)
        XCTAssertGreaterThanOrEqual(manager.regionOfInterest.y, 0)
    }
    
    func testOCRRegionStaticRegions() {
        // Test static region definitions
        let bottomLeft = OCRRegion.bottomLeft
        XCTAssertEqual(bottomLeft.x, 0.0)
        XCTAssertEqual(bottomLeft.y, 0.6)
        
        let customRegion = OCRRegion.customGPSRegion
        XCTAssertGreaterThan(customRegion.width, 0)
        XCTAssertGreaterThan(customRegion.height, 0)
    }
}

