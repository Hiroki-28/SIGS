//
//  CaptureFolderManager.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/07/22.
//

import Dispatch
import Foundation
import os


class CaptureFolderManager {
    // The top-level capture directory that contains Images and Depths subdirectories.
    // This sample automatically creates this directory at `init()` with timestamp.
    let rootScanFolder: URL

    // Subdirectory of `rootScanFolder` for images
    let imagesFolder: URL

    // Subdirectory of `rootScanFolder` for depthMaps
    let depthMapsFolder: URL
    
    // Subdirectory of `rootScanFolder` for pointCloudFolder
    let pointCloudFolder: URL
    
    // Subdirectory of `rootScanFolder` for cameraTransformFolder
    let cameraTransformFolder: URL
    
    // Subdirectory of `rootScanFolder` for fovFolder
    let fovFolder: URL
    
    // Subdirectory of `rootScanFolder` for trackingStatusFolder
    let trackingStatusFolder: URL

    @Published var shots: [ShotFileInfo] = []

    init?() {
        guard let newFolder = CaptureFolderManager.createNewScanDirectory() else {
            print("Unable to create a new scan directory.")
            return nil
        }
        print("newFolder: \(newFolder)")
        rootScanFolder = newFolder

        // Creates the subdirectories.
        imagesFolder = newFolder.appendingPathComponent("Images/")
        guard CaptureFolderManager.createDirectoryRecursively(imagesFolder) else {
            return nil
        }
        
        depthMapsFolder = newFolder.appendingPathComponent("DepthMaps/")
        guard CaptureFolderManager.createDirectoryRecursively(depthMapsFolder) else {
            return nil
        }
        
        pointCloudFolder = newFolder.appendingPathComponent("PointCloud/")
        guard CaptureFolderManager.createDirectoryRecursively(pointCloudFolder) else {
            return nil
        }
        
        cameraTransformFolder = newFolder.appendingPathComponent("CameraTransform/")
        guard CaptureFolderManager.createDirectoryRecursively(cameraTransformFolder) else {
            return nil
        }
        
        fovFolder = newFolder.appendingPathComponent("FOV/")
        guard CaptureFolderManager.createDirectoryRecursively(fovFolder) else {
            return nil
        }
        
        trackingStatusFolder = newFolder.appendingPathComponent("TrackingStatus/")
        guard CaptureFolderManager.createDirectoryRecursively(trackingStatusFolder) else {
            return nil
        }
    }

    static func parseShotId(url: URL) -> UInt32? {
        let photoBasename = url.deletingPathExtension().lastPathComponent

        guard let endOfPrefix = photoBasename.lastIndex(of: "_") else {
            return nil
        }

        let imgPrefix = photoBasename[...endOfPrefix]
        guard imgPrefix == imageStringPrefix else {
            return nil
        }

        let idString = photoBasename[photoBasename.index(after: endOfPrefix)...]
        guard let id = UInt32(idString) else {
            return nil
        }

        return id
    }

    static func imageIdString(for id: UInt32) -> String {
        return String(format: "%@%04d", imageStringPrefix, id)
    }

    static func heicImageUrl(in outputDir: URL, id: UInt32) -> URL {
        return outputDir
            .appendingPathComponent(imageIdString(for: id))
            .appendingPathExtension(heicImageExtension)
    }

    static func createNewScanDirectory() -> URL? {
        guard let capturesFolder = rootScansFolder() else {
            print("Can't get user document dir!")
            return nil
        }

        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let newCaptureDir = capturesFolder
            .appendingPathComponent(timestamp, isDirectory: true)

        let capturePath = newCaptureDir.path
        do {
            try FileManager.default.createDirectory(atPath: capturePath,
                                                    withIntermediateDirectories: true)
            print("capturePath:\(capturePath)")
        } catch {
            print("Failed to create capturepath=\"\(capturePath)\" error=\(String(describing: error))")
            return nil
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: capturePath, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            return nil
        }
        return newCaptureDir
    }

    private static func createDirectoryRecursively(_ outputDir: URL) -> Bool {
        guard outputDir.isFileURL else {
            return false
        }
        let expandedPath = outputDir.path
        var isDirectory: ObjCBool = false
        let fileManager = FileManager()
        guard !fileManager.fileExists(atPath: outputDir.path, isDirectory: &isDirectory) else {
            print("File already exists at \(expandedPath)")
            return false
        }

        let result: ()? = try? fileManager.createDirectory(atPath: expandedPath,
                                                           withIntermediateDirectories: true)

        guard result != nil else {
            return false
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDir) && isDir.boolValue else {
            print("Dir \"\(expandedPath)\" doesn't exist after creation!")
            return false
        }

        return true
    }

    private static let imageStringPrefix = "IMG_"
    private static let heicImageExtension = "HEIC"

    private static func rootScansFolder() -> URL? {
        guard let documentsFolder =
                try? FileManager.default.url(for: .documentDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil, create: false) else {
            return nil
        }
        print("documentsFolder:\(documentsFolder)")
        return documentsFolder.appendingPathComponent("Scans/", isDirectory: true)
    }
}
