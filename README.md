# Garmin Route Mapper

A macOS application that extracts GPS coordinates from video files using OCR (Optical Character Recognition) and exports them as GeoJSON and CSV files. Perfect for extracting route data from Garmin device videos or any video that displays GPS coordinates.

## Features

- **Video GPS Extraction**: Automatically extracts GPS coordinates from video frames using OCR technology
- **Drag & Drop Interface**: Simple drag-and-drop or file picker to add video files
- **Video Playback**: Watch videos with synchronized map view showing your route
- **Route Visualization**: Interactive map displaying extracted GPS coordinates
- **GPS Interpolation**: Automatically fills in missing GPS points between valid frames
- **Route Smoothing**: Optional smoothing with adjustable window size (3-15 frames)
- **OCR Diagnostics**: View and manually edit extracted GPS coordinates frame-by-frame
- **Export Options**: Export routes in both GeoJSON and CSV formats
- **Multi-Video Support**: Process and export multiple videos at once

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later (for building from source)
- Swift 5.9 or later

## Installation

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/BrokeOverLand/garmin-route-mapper.git
cd garmin-route-mapper
```

2. Open the project in Xcode:
```bash
open "Garmin Route Mapper.xcodeproj"
```

3. Build and run the project (⌘R) or select Product > Run from the menu

## Usage

### Extracting GPS Data

1. **Add Videos**: Drag and drop video files into the app, or click "Add Videos" to select files
2. **Extract GPS**: Click "Extract GPS" to process all videos. The app will:
   - Extract frames from each video (approximately 1 frame per second)
   - Use OCR to read GPS coordinates from each frame
   - Interpolate missing GPS points
3. **View Results**: Select a video from the list to view:
   - Video playback with controls
   - Synchronized map showing the route
   - GPS point count and status

### Viewing and Editing GPS Data

- **OCR Diagnostics**: Use the OCR Diagnostics panel to:
  - Navigate through processed frames
  - View original and cropped frame images
  - See detected GPS coordinates
  - Manually edit GPS coordinates if OCR made mistakes

### Route Smoothing

- Toggle "Smooth Route" to enable smoothing
- Adjust the smoothing window (3-15 frames) to control how much smoothing is applied
- Larger windows create smoother routes but may reduce detail

### Exporting Routes

1. Click "Export" to save your routes
2. Choose a location and filename
3. The app will create two files:
   - **GeoJSON file** (`.geojson`): Standard format for GIS applications
   - **CSV file** (`.csv`): Frame-by-frame GPS data with metadata

#### GeoJSON Format
The exported GeoJSON file contains:
- FeatureCollection with one Feature per video
- LineString geometry for each route
- Metadata including filename, extraction date, and frame counts

#### CSV Format
The CSV file includes:
- `filename`: Source video filename
- `frame_number`: Frame index in video
- `latitude`: GPS latitude
- `longitude`: GPS longitude
- `extraction_status`: Valid/Invalid
- `extraction_method`: OCR, Interpolation, or Smoothing
- `timestamp`: When the data was extracted

## How It Works

1. **Frame Extraction**: The app extracts frames from video files at regular intervals (approximately 1 FPS)
2. **OCR Processing**: Uses Apple's Vision framework to recognize text in a predefined region of each frame
3. **GPS Parsing**: Parses GPS coordinates from recognized text using multiple pattern matching strategies
4. **Coordinate Processing**:
   - Validates coordinates (latitude: -90 to 90, longitude: -180 to 180)
   - Interpolates missing points between valid frames
   - Optionally smooths routes using a moving average window
5. **Export**: Converts processed GPS points to GeoJSON and CSV formats

## OCR Configuration

The app is configured to extract GPS coordinates from the bottom-center region of video frames (optimized for 1920x1080 videos). The OCR region can be customized in `OCRManager.swift`:

```swift
static let customGPSRegion: OCRRegion = OCRRegion(
    x: 653.0 / 1920.0,      // Normalized X position
    y: 1030.0 / 1080.0,     // Normalized Y position (from top)
    width: 390.0 / 1920.0,  // Normalized width
    height: 50.0 / 1080.0   // Normalized height
)
```

## Supported GPS Formats

The OCR parser recognizes multiple GPS coordinate formats:
- Decimal degrees: `37.7749, -122.4194`
- With degrees symbol: `37.7749°N, 122.4194°W`
- With direction indicators: `37.7749 N, 122.4194 W`
- Labeled format: `Lat: 37.7749 Lon: -122.4194`

## Project Structure

```
Garmin Route Mapper/
├── Garmin Route Mapper/
│   ├── ContentView.swift          # Main UI
│   ├── Garmin_Route_MapperApp.swift # App entry point
│   ├── Managers/
│   │   ├── VideoManager.swift     # Video playback and frame extraction
│   │   ├── GPSProcessor.swift     # GPS processing (interpolation, smoothing)
│   │   ├── OCRManager.swift       # OCR and GPS coordinate parsing
│   │   └── ExportManager.swift   # GeoJSON and CSV export
│   ├── Models/
│   │   └── VideoItem.swift        # Data models
│   ├── ViewModels/
│   │   ├── MainViewModel.swift    # Main view model
│   │   └── MapViewModel.swift     # Map view model
│   └── Views/
│       ├── DragDropArea.swift     # Drag and drop interface
│       ├── MapView.swift          # Map visualization
│       └── VideoPlayerView.swift  # Video player
└── README.md
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## License

This project is licensed under the MIT License - see the [MIT LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with SwiftUI and Swift
- Uses Apple's Vision framework for OCR
- Uses AVFoundation for video processing
- Uses MapKit for route visualization

## Author

**Chad Lynch**

Created on October 31, 2025

