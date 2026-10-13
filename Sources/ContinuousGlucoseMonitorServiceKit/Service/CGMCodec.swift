//
//  CGMCodec.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Shared decoding primitives for the CGM codec: error type, a little-endian cursor, and SFLOAT helpers.
//  CGMS §1.6: multi-octet fields are little-endian. CGMS §3.10: SFLOAT special values.

import Foundation
import BluetoothCommonKit

/// E2E-CRC field shared by every protected CGMS characteristic (CGMS §3.11): CRC-CCITT, 2 octets, appended last.
public enum CGME2ECRC {
    public static let size = 2
}

public enum CGMCodecError: Error, Equatable, Sendable {
    case truncated(expected: Int, actual: Int)
    case invalidSize(UInt8)
    case missingCRC
    case invalidCRC
    case invalidValue(String)
}

/// Sequential little-endian reader over a `Data` value or slice.
public struct CGMDataReader {
    private let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public var isAtEnd: Bool { remaining == 0 }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else {
            throw CGMCodecError.truncated(expected: size, actual: remaining)
        }
        let value = data[offset..<offset + size].to(T.self)
        offset += size
        return value
    }

    public mutating func readSFloat() throws -> Double {
        let raw = try read(UInt16.self)
        return SFloat.decode(raw)
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw CGMCodecError.truncated(expected: count, actual: remaining)
        }
        let bytes = data[offset..<offset + count]
        offset += count
        return Data(bytes)
    }

    /// Re-reads already consumed bytes, e.g. the CRC-protected span of a record.
    public func bytes(from start: Int, count: Int) -> Data {
        Data(data[start..<start + count])
    }
}

// SFLOAT encode/decode comes from BluetoothCommonKit (`SFloat`, `Data.appendSFloat`), shared with the
// Insulin Delivery Service kit.

extension Double {
    /// NaN-aware equality for SFLOAT fields, where NaN means "no valid result" and should compare equal to itself.
    func isSameMeasurement(as other: Double) -> Bool {
        (isNaN && other.isNaN) || self == other
    }
}

extension Optional where Wrapped == Double {
    /// NaN-aware equality for optional SFLOAT fields such as trend and quality.
    func isSameMeasurement(as other: Double?) -> Bool {
        switch (self, other) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isSameMeasurement(as: rhs)
        default: return false
        }
    }
}
