//
//  CGMSessionStartTime.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  CGM Session Start Time (CGMS §3.4): Date Time (7 octets, local wall clock), Time Zone (INT8, quarter hours,
//  -128 unknown), DST Offset (UINT8, 255 unknown), [E2E-CRC].
//  CGM Session Run Time (CGMS §3.5): UINT16 hours, [E2E-CRC].

import Foundation
import BluetoothCommonKit

/// GSS DST Offset characteristic values.
public enum CGMDSTOffset: UInt8, Codable, CaseIterable, Sendable {
    case standardTime = 0
    case halfHourDaylightTime = 2
    case daylightTime = 4
    case doubleDaylightTime = 8
    case unknown = 255

    public var seconds: Int? {
        switch self {
        case .standardTime: return 0
        case .halfHourDaylightTime: return 30 * 60
        case .daylightTime: return 60 * 60
        case .doubleDaylightTime: return 2 * 60 * 60
        case .unknown: return nil
        }
    }

    public init(daylightSavingTimeOffset seconds: TimeInterval) {
        self = Self.allCases.first(where: { $0.seconds == Int(seconds) }) ?? .unknown
    }
}

public struct CGMSessionStartTime: Equatable, Codable, Sendable {
    public static let baseSize = 9
    public static let unknownTimeZone: Int8 = -128

    /// Absolute instant of the session start.
    public var date: Date

    /// Standard-time offset from UTC in 15-minute increments; `unknownTimeZone` when not known.
    public var timeZoneOffset: Int8

    public var dstOffset: CGMDSTOffset

    public init(date: Date, timeZoneOffset: Int8, dstOffset: CGMDSTOffset) {
        self.date = date
        self.timeZoneOffset = timeZoneOffset
        self.dstOffset = dstOffset
    }

    public init(date: Date, timeZone: TimeZone) {
        // GSS Time Zone is the offset of local *standard* time from UTC, so strip any DST component.
        let daylightSeconds = timeZone.daylightSavingTimeOffset(for: date)
        let standardSeconds = timeZone.secondsFromGMT(for: date) - Int(daylightSeconds)
        self.init(
            date: date,
            timeZoneOffset: Int8(clamping: standardSeconds / (15 * 60)),
            dstOffset: CGMDSTOffset(daylightSavingTimeOffset: daylightSeconds)
        )
    }

    /// Fixed-offset zone the Date Time octets are expressed in; UTC when the offset is unknown.
    public var localTimeZone: TimeZone {
        guard timeZoneOffset != Self.unknownTimeZone else { return .utc }
        let seconds = Int(timeZoneOffset) * 15 * 60 + (dstOffset.seconds ?? 0)
        return TimeZone(secondsFromGMT: seconds) ?? .utc
    }

    public func encoded(e2eCRC: Bool) -> Data {
        var data = date.gattDateTime(using: localTimeZone)
        data.append(UInt8(bitPattern: timeZoneOffset))
        data.append(dstOffset.rawValue)
        return e2eCRC ? data.appendingCRC() : data
    }

    public init(data: Data, e2eCRC: Bool) throws {
        let expected = Self.baseSize + (e2eCRC ? CGMMeasurementRecord.crcSize : 0)
        guard data.count == expected else {
            throw CGMCodecError.truncated(expected: expected, actual: data.count)
        }
        if e2eCRC, !data.isCRCValid {
            throw CGMCodecError.invalidCRC
        }

        var reader = CGMDataReader(data)
        let dateTime = try reader.readBytes(7)
        let rawTimeZone = try reader.read(UInt8.self)
        let timeZoneOffset = Int8(bitPattern: rawTimeZone)
        let rawDST = try reader.read(UInt8.self)
        guard let dstOffset = CGMDSTOffset(rawValue: rawDST) else {
            throw CGMCodecError.invalidValue("DST Offset \(rawDST)")
        }

        // Resolve the zone first so the wall-clock octets map to the right instant.
        var startTime = CGMSessionStartTime(date: Date(), timeZoneOffset: timeZoneOffset, dstOffset: dstOffset)
        guard let date = Date(gattDateTime: dateTime, timeZone: startTime.localTimeZone) else {
            throw CGMCodecError.invalidValue("Date Time \(dateTime.hexadecimalString)")
        }
        startTime.date = date
        self = startTime
    }
}

public struct CGMSessionRunTime: Equatable, Codable, Sendable {
    public static let baseSize = 2

    /// Expected session run time in hours, relative to Session Start Time.
    public var hours: UInt16

    public init(hours: UInt16) {
        self.hours = hours
    }

    public func encoded(e2eCRC: Bool) -> Data {
        let data = Data(hours)
        return e2eCRC ? data.appendingCRC() : data
    }

    public init(data: Data, e2eCRC: Bool) throws {
        let expected = Self.baseSize + (e2eCRC ? CGMMeasurementRecord.crcSize : 0)
        guard data.count == expected else {
            throw CGMCodecError.truncated(expected: expected, actual: data.count)
        }
        if e2eCRC, !data.isCRCValid {
            throw CGMCodecError.invalidCRC
        }
        var reader = CGMDataReader(data)
        let hours = try reader.read(UInt16.self)
        self.init(hours: hours)
    }
}
