//
//  CGMScenarioLibrary.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-08.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Scripted glucose scenarios shipped with the kit so every host app drives the mock sensor with the same
//  data. Add a `CGMScenario-<label>.json` file to Sources/.../Resources and it appears in `bundled`.
//  Two file shapes are accepted:
//    kit form:   {"name": "...", "repeats": true, "sampleInterval": 300, "values": [mgdl, mgdl, ...]}
//    trace form: {"glucoseValues": [{"mgdlValue": value, "dateOffset": seconds}, ...]}
//                (the spacing of the first two offsets becomes sampleInterval; the name becomes "<Label> Trace")
//  The sensor steps one value per measurement; sampleInterval only feeds the trend calculation.
//  A trailing comma before a closing bracket is tolerated.

import Foundation

public enum CGMScenarioLibraryError: Error, Equatable {
    /// Neither a kit-form ("values") nor a trace-form ("glucoseValues") object.
    case unrecognizedShape(String)
}

public enum CGMScenarioLibrary {
    public static let filePrefix = "CGMScenario-"

    /// Every scenario in the kit's resource bundle, sorted by name.
    public static let bundled: [CGMGlucoseScenario] = load(from: .module)

    public static func load(from bundle: Bundle) -> [CGMGlucoseScenario] {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) }
            .compactMap { url -> CGMGlucoseScenario? in
                do {
                    return try scenario(from: Data(contentsOf: url), fileName: url.lastPathComponent)
                } catch {
                    print("CGMScenarioLibrary: could not load \(url.lastPathComponent): \(error)")
                    return nil
                }
            }
            .sorted { $0.name < $1.name }
    }

    /// Picks the file shape by its top-level key so a malformed file reports the error from its own shape.
    public static func scenario(from data: Data, fileName: String) throws -> CGMGlucoseScenario {
        let decoder = JSONDecoder()
        let json = stripTrailingCommas(data)
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CGMScenarioLibraryError.unrecognizedShape(fileName)
        }
        if object["values"] != nil {
            return try decoder.decode(CGMGlucoseScenario.self, from: json)
        }
        guard object["glucoseValues"] != nil else {
            throw CGMScenarioLibraryError.unrecognizedShape(fileName)
        }
        let trace = try decoder.decode(TraceFile.self, from: json)
        let offsets = trace.glucoseValues.compactMap(\.dateOffset)
        let spacing = offsets.count >= 2 ? offsets[1] - offsets[0] : 0
        return CGMGlucoseScenario(
            name: displayName(forFileName: fileName),
            values: trace.glucoseValues.map(\.mgdlValue),
            repeats: true,
            sampleInterval: spacing > 0 ? spacing : CGMGlucoseScenario.defaultSampleInterval
        )
    }

    /// "CGMScenario-normal.json" -> "Normal Trace"
    public static func displayName(forFileName fileName: String) -> String {
        var label = (fileName as NSString).deletingPathExtension
        if label.hasPrefix(filePrefix) {
            label.removeFirst(filePrefix.count)
        }
        return label.capitalized + " Trace"
    }

    /// Source files may end their arrays with a dangling comma, which JSONDecoder rejects. Only commas
    /// outside string literals are considered, so a name like "a,]" is left alone.
    static func stripTrailingCommas(_ data: Data) -> Data {
        let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, comma: UInt8 = 0x2C
        let closers: Set<UInt8> = [0x5D, 0x7D]                   // ] }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        let bytes = [UInt8](data)
        var output = Data(capacity: bytes.count)
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            if byte == quote {
                inString = true
            } else if byte == comma {
                var next = index + 1
                while next < bytes.count, whitespace.contains(bytes[next]) { next += 1 }
                if next < bytes.count, closers.contains(bytes[next]) { continue }   // drop the dangling comma
            }
            output.append(byte)
        }
        return output
    }

    private struct TraceFile: Decodable {
        struct Value: Decodable {
            let mgdlValue: Double
            let dateOffset: TimeInterval?
        }
        let glucoseValues: [Value]
    }
}
