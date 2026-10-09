//
//  CGMMeasurementRecord.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  CGM Measurement record (CGMS §3.1): Size, Flags, Glucose (SFLOAT mg/dL), Time Offset (UINT16 min),
//  [Sensor Status Annunciation 1–3 octets], [Trend SFLOAT (mg/dL)/min], [Quality SFLOAT %], [E2E-CRC].
//  A characteristic value may carry several records back to back.

import Foundation
import BluetoothCommonKit

public struct CGMMeasurementFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let trendPresent = CGMMeasurementFlags(rawValue: 1 << 0)
    public static let qualityPresent = CGMMeasurementFlags(rawValue: 1 << 1)
    public static let warningOctetPresent = CGMMeasurementFlags(rawValue: 1 << 5)
    public static let calTempOctetPresent = CGMMeasurementFlags(rawValue: 1 << 6)
    public static let statusOctetPresent = CGMMeasurementFlags(rawValue: 1 << 7)
}

public struct CGMMeasurementRecord: Sendable {
    /// Size + Flags + Glucose + Time Offset (CGMS §3.1.1.1).
    public static let minimumSize = 6

    /// mg/dL; NaN when the sensor has no valid result.
    public var glucoseConcentration: Double

    /// Minutes since Session Start Time; doubles as the sequence number (CGMS §3.1.1.4).
    public var timeOffset: UInt16

    /// Only octets with at least one bit set are transmitted (CGMS §3.1.1.5).
    public var sensorStatus: CGMSensorStatusAnnunciation

    /// (mg/dL)/min
    public var trend: Double?

    /// Percent
    public var quality: Double?

    public init(glucoseConcentration: Double,
                timeOffset: UInt16,
                sensorStatus: CGMSensorStatusAnnunciation = [],
                trend: Double? = nil,
                quality: Double? = nil)
    {
        self.glucoseConcentration = glucoseConcentration
        self.timeOffset = timeOffset
        self.sensorStatus = sensorStatus
        self.trend = trend
        self.quality = quality
    }

    public var flags: CGMMeasurementFlags {
        var flags: CGMMeasurementFlags = []
        if sensorStatus.statusOctet != 0 { flags.insert(.statusOctetPresent) }
        if sensorStatus.calTempOctet != 0 { flags.insert(.calTempOctetPresent) }
        if sensorStatus.warningOctet != 0 { flags.insert(.warningOctetPresent) }
        if trend != nil { flags.insert(.trendPresent) }
        if quality != nil { flags.insert(.qualityPresent) }
        return flags
    }

    // MARK: - Encoding

    public func encoded(e2eCRC: Bool) -> Data {
        let flags = self.flags
        var body = Data()
        body.appendSFloat(glucoseConcentration)
        body.append(timeOffset)
        if flags.contains(.statusOctetPresent) { body.append(sensorStatus.statusOctet) }
        if flags.contains(.calTempOctetPresent) { body.append(sensorStatus.calTempOctet) }
        if flags.contains(.warningOctetPresent) { body.append(sensorStatus.warningOctet) }
        if let trend { body.appendSFloat(trend) }
        if let quality { body.appendSFloat(quality) }

        let size = 2 + body.count + (e2eCRC ? CGME2ECRC.size : 0)
        var record = Data([UInt8(size), flags.rawValue])
        record.append(body)
        return e2eCRC ? record.appendingCRC() : record
    }

    // MARK: - Decoding

    /// Decodes exactly one record; `data` must contain nothing else.
    public static func decode(_ data: Data, e2eCRC: Bool) throws -> CGMMeasurementRecord {
        var reader = CGMDataReader(data)
        let record = try decodeNext(from: &reader, e2eCRC: e2eCRC)
        guard reader.isAtEnd else {
            throw CGMCodecError.invalidSize(UInt8(clamping: data.count))
        }
        return record
    }

    /// Decodes a characteristic value holding one or more records.
    public static func decodeRecords(_ data: Data, e2eCRC: Bool) throws -> [CGMMeasurementRecord] {
        var reader = CGMDataReader(data)
        var records: [CGMMeasurementRecord] = []
        while !reader.isAtEnd {
            records.append(try decodeNext(from: &reader, e2eCRC: e2eCRC))
        }
        return records
    }

    /// Octets a record occupies before the CRC, as announced by its Flags.
    static func fieldsSize(for flags: CGMMeasurementFlags) -> Int {
        var size = minimumSize
        if flags.contains(.statusOctetPresent) { size += 1 }
        if flags.contains(.calTempOctetPresent) { size += 1 }
        if flags.contains(.warningOctetPresent) { size += 1 }
        if flags.contains(.trendPresent) { size += 2 }
        if flags.contains(.qualityPresent) { size += 2 }
        return size
    }

    private static func decodeNext(from reader: inout CGMDataReader, e2eCRC: Bool) throws -> CGMMeasurementRecord {
        let start = reader.offset
        let size = Int(try reader.read(UInt8.self))
        let crcSize = e2eCRC ? CGME2ECRC.size : 0

        guard size >= minimumSize else {
            throw CGMCodecError.invalidSize(UInt8(size))
        }
        guard reader.remaining >= size - 1 else {
            throw CGMCodecError.truncated(expected: size, actual: reader.remaining + 1)
        }

        // The Flags announce how many octets the fields take, so the CRC's position is known before parsing:
        // Size equal to the fields alone means the CRC was never sent (Missing CRC); otherwise the CRC is
        // verified first, so any corruption (Flags included) is reported as Invalid CRC rather than as a
        // bad field; an intact record whose Size still disagrees with its Flags is Invalid Size.
        let flags = CGMMeasurementFlags(rawValue: try reader.read(UInt8.self))
        let fieldsSize = Self.fieldsSize(for: flags)
        if e2eCRC {
            if size == fieldsSize { throw CGMCodecError.missingCRC }
            guard reader.bytes(from: start, count: size).isCRCValid else {
                throw CGMCodecError.invalidCRC
            }
        }
        guard size == fieldsSize + crcSize else {
            throw CGMCodecError.invalidSize(UInt8(size))
        }

        let glucose = try reader.readSFloat()
        let timeOffset = try reader.read(UInt16.self)

        var statusOctet: UInt8 = 0
        var calTempOctet: UInt8 = 0
        var warningOctet: UInt8 = 0
        if flags.contains(.statusOctetPresent) { statusOctet = try reader.read(UInt8.self) }
        if flags.contains(.calTempOctetPresent) { calTempOctet = try reader.read(UInt8.self) }
        if flags.contains(.warningOctetPresent) { warningOctet = try reader.read(UInt8.self) }

        var trend: Double?
        if flags.contains(.trendPresent) { trend = try reader.readSFloat() }
        var quality: Double?
        if flags.contains(.qualityPresent) { quality = try reader.readSFloat() }

        if e2eCRC {
            // Already verified above; consume the CRC octets.
            _ = try reader.read(UInt16.self)
        }

        return CGMMeasurementRecord(
            glucoseConcentration: glucose,
            timeOffset: timeOffset,
            sensorStatus: CGMSensorStatusAnnunciation(statusOctet: statusOctet, calTempOctet: calTempOctet, warningOctet: warningOctet),
            trend: trend,
            quality: quality
        )
    }
}

extension CGMMeasurementRecord: Equatable {
    public static func == (lhs: CGMMeasurementRecord, rhs: CGMMeasurementRecord) -> Bool {
        lhs.glucoseConcentration.isSameMeasurement(as: rhs.glucoseConcentration)
            && lhs.timeOffset == rhs.timeOffset
            && lhs.sensorStatus == rhs.sensorStatus
            && lhs.trend.isSameMeasurement(as: rhs.trend)
            && lhs.quality.isSameMeasurement(as: rhs.quality)
    }
}
