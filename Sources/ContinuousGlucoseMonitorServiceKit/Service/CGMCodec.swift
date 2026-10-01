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

/// IEEE 11073-20601 SFLOAT: 4-bit signed exponent (base 10), 12-bit signed mantissa.
/// Picks the exponent that keeps the most precision, preferring exponent 0 for integral values so that
/// common glucose values encode canonically (100 mg/dL -> 0x0064).
public enum SFloat {
    public static let nan: UInt16 = 0x07FF
    public static let nRes: UInt16 = 0x0800
    public static let positiveInfinity: UInt16 = 0x07FE
    public static let negativeInfinity: UInt16 = 0x0802
    public static let reservedForFutureUse: UInt16 = 0x0801

    private static let mantissaRange = -2048...2047
    private static let exponentRange = -8...7

    public static func encode(_ value: Double) -> UInt16 {
        if value.isNaN { return nan }
        if value == .infinity { return positiveInfinity }
        if value == -.infinity { return negativeInfinity }

        var exponent = 0
        var mantissa = value

        // Gain fractional precision while the mantissa still fits.
        while exponent > exponentRange.lowerBound,
              !isIntegral(mantissa),
              abs(mantissa * 10) <= Double(mantissaRange.upperBound)
        {
            mantissa *= 10
            exponent -= 1
        }

        // Shed magnitude until the mantissa fits.
        while exponent < exponentRange.upperBound,
              !mantissaRange.contains(Int(mantissa.rounded()))
        {
            mantissa /= 10
            exponent += 1
        }

        var rounded = Int(mantissa.rounded())
        guard mantissaRange.contains(rounded) else {
            return value > 0 ? positiveInfinity : negativeInfinity
        }

        // Exponent 0 with mantissa 0x7FE...0x802 collides with the special values; step up one decade.
        if exponent == 0, rounded >= 2046 || rounded <= -2046 {
            rounded = Int((Double(rounded) / 10).rounded())
            exponent = 1
        }

        let exponentBits = UInt16(truncatingIfNeeded: exponent) & 0x000F
        let mantissaBits = UInt16(truncatingIfNeeded: rounded) & 0x0FFF
        return exponentBits << 12 | mantissaBits
    }

    public static func decode(_ raw: UInt16) -> Double {
        switch raw {
        case nan, nRes, reservedForFutureUse: return .nan
        case positiveInfinity: return .infinity
        case negativeInfinity: return -.infinity
        default: break
        }

        var exponent = Int(raw >> 12)
        if exponent >= 8 { exponent -= 16 }

        var mantissa = Int(raw & 0x0FFF)
        if mantissa >= 2048 { mantissa -= 4096 }

        return Double(mantissa) * pow(10, Double(exponent))
    }

    private static func isIntegral(_ value: Double) -> Bool {
        abs(value - value.rounded()) <= 1e-9 * max(1, abs(value))
    }
}

public extension Data {
    mutating func appendSFloat(_ value: Double) {
        append(SFloat.encode(value))
    }
}

extension Double {
    /// NaN-aware equality for glucose fields, where NaN means "no valid result" and should compare equal to itself.
    func isSameMeasurement(as other: Double) -> Bool {
        (isNaN && other.isNaN) || self == other
    }
}
