//
//  CGMCodecTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Spec-conformance vectors for the CGM codec (CGMS v1.0.2). Byte strings are hand-encoded from the spec,
//  not derived from the encoder, so encoder and decoder are checked independently.

import Foundation
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

// MARK: - E2E-CRC

@Suite("CGM E2E-CRC")
struct CGMCRCTests {
    /// CGMS §3.11 sample: 3E 01 02 03 04 05 06 07 08 09 -> parity octets 01 2F on the wire (value 0x2F01 LE).
    @Test func specSampleVector() {
        let sample = Data([0x3E, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        #expect(sample.crc16 == 0x2F01)
        #expect(sample.appendingCRC() == sample + Data([0x01, 0x2F]))
        #expect(sample.appendingCRC().isCRCValid)
    }

    @Test func corruptedPayloadFailsValidation() {
        var protected = Data([0x3E, 0x01, 0x02]).appendingCRC()
        protected[1] ^= 0x01
        #expect(!protected.isCRCValid)
    }
}

// MARK: - SFLOAT

@Suite("SFLOAT mg/dL")
struct SFloatTests {
    @Test(arguments: [
        (100.0, UInt16(0x0064)),   // 100 e0
        (120.5, UInt16(0xF4B5)),   // 1205 e-1
        (-1.25, UInt16(0xEF83)),   // -125 e-2
        (0.0, UInt16(0x0000)),
        (95.0, UInt16(0x005F)),
        (400.0, UInt16(0x0190)),
    ])
    func encodesCanonically(value: Double, raw: UInt16) {
        #expect(SFloat.encode(value) == raw)
        #expect(SFloat.decode(raw) == value)
    }

    @Test func specialValues() {
        #expect(SFloat.encode(.nan) == 0x07FF)
        #expect(SFloat.encode(.infinity) == 0x07FE)
        #expect(SFloat.encode(-.infinity) == 0x0802)
        #expect(SFloat.decode(0x07FF).isNaN)
        #expect(SFloat.decode(0x0800).isNaN)   // NRes
        #expect(SFloat.decode(0x0801).isNaN)   // RFU
        #expect(SFloat.decode(0x07FE) == .infinity)
        #expect(SFloat.decode(0x0802) == -.infinity)
    }

    @Test func avoidsReservedMantissaAtExponentZero() {
        let raw = SFloat.encode(2047)
        #expect(raw != 0x07FF)
        #expect(abs(SFloat.decode(raw) - 2047) <= 5)
    }

    @Test func saturatesToInfinity() {
        #expect(SFloat.encode(1e12) == 0x07FE)
        #expect(SFloat.encode(-1e12) == 0x0802)
    }
}

// MARK: - CGM Measurement

@Suite("CGM Measurement record")
struct CGMMeasurementRecordTests {
    @Test func minimalRecord() throws {
        let record = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5)
        let expected = Data([0x06, 0x00, 0x64, 0x00, 0x05, 0x00])
        #expect(record.encoded(e2eCRC: false) == expected)
        #expect(try CGMMeasurementRecord.decode(expected, e2eCRC: false) == record)
    }

    @Test func fullRecord() throws {
        let record = CGMMeasurementRecord(
            glucoseConcentration: 120.5,
            timeOffset: 300,
            sensorStatus: [.sessionStopped, .calibrationRequired, .resultHigherThanPatientHigh],
            trend: -1.25,
            quality: 95
        )
        // Size 13, Flags: trend|quality|warning|calTemp|status = 0xE3
        let expected = Data([
            0x0D, 0xE3,
            0xB5, 0xF4,          // 120.5 mg/dL
            0x2C, 0x01,          // offset 300
            0x01, 0x08, 0x02,    // status, cal/temp, warning octets
            0x83, 0xEF,          // trend -1.25
            0x5F, 0x00           // quality 95
        ])
        #expect(record.encoded(e2eCRC: false) == expected)
        #expect(try CGMMeasurementRecord.decode(expected, e2eCRC: false) == record)
    }

    @Test func onlyNonZeroAnnunciationOctetsAreSent() {
        let record = CGMMeasurementRecord(glucoseConcentration: 55, timeOffset: 10, sensorStatus: [.resultLowerThanHypo])
        // Warning octet only: Flags bit 5, one extra octet with bit 2 set.
        #expect(record.encoded(e2eCRC: false) == Data([0x07, 0x20, 0x37, 0x00, 0x0A, 0x00, 0x04]))
    }

    @Test func nanGlucoseRoundTrips() throws {
        let record = CGMMeasurementRecord(glucoseConcentration: .nan, timeOffset: 15, quality: 0)
        let decoded = try CGMMeasurementRecord.decode(record.encoded(e2eCRC: false), e2eCRC: false)
        #expect(decoded.glucoseConcentration.isNaN)
        #expect(decoded == record)
    }

    @Test func e2eCRCAppendedAndValidated() throws {
        let record = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5, trend: 0.5)
        let encoded = record.encoded(e2eCRC: true)
        #expect(encoded.count == 10)
        #expect(encoded[0] == 0x0A)
        #expect(encoded.isCRCValid)
        #expect(try CGMMeasurementRecord.decode(encoded, e2eCRC: true) == record)

        var corrupted = encoded
        corrupted[2] ^= 0xFF
        #expect(throws: CGMCodecError.invalidCRC) {
            try CGMMeasurementRecord.decode(corrupted, e2eCRC: true)
        }
    }

    @Test func missingCRCWhenE2EExpected() {
        let unprotected = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5).encoded(e2eCRC: false)
        #expect(throws: CGMCodecError.missingCRC) {
            try CGMMeasurementRecord.decode(unprotected, e2eCRC: true)
        }
    }

    @Test func multipleRecordsPerCharacteristicValue() throws {
        let first = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5)
        let second = CGMMeasurementRecord(glucoseConcentration: 105, timeOffset: 10, trend: 1)
        let value = first.encoded(e2eCRC: true) + second.encoded(e2eCRC: true)
        #expect(try CGMMeasurementRecord.decodeRecords(value, e2eCRC: true) == [first, second])
    }

    @Test func truncatedRecordThrows() {
        let value = Data([0x08, 0x01, 0x64, 0x00, 0x05, 0x00])
        #expect(throws: CGMCodecError.truncated(expected: 8, actual: 6)) {
            try CGMMeasurementRecord.decode(value, e2eCRC: false)
        }
    }

    @Test func sizeMismatchWithFlagsThrows() {
        // Size says 8 but Flags announce no optional fields.
        let value = Data([0x08, 0x00, 0x64, 0x00, 0x05, 0x00, 0x00, 0x00])
        #expect(throws: CGMCodecError.invalidSize(8)) {
            try CGMMeasurementRecord.decode(value, e2eCRC: false)
        }
    }
}

// MARK: - CGM Feature

@Suite("CGM Feature")
struct CGMFeatureTests {
    @Test func encodesWithPlaceholderCRCWhenE2EUnsupported() throws {
        let feature = CGMFeature(flags: [.calibration, .trendInformation, .quality])
        // Flags 0x018001 LE, Type ISF (9) in low nibble, Location subcutaneous (5) in high nibble, CRC 0xFFFF.
        let expected = Data([0x01, 0x80, 0x01, 0x59, 0xFF, 0xFF])
        #expect(feature.encoded() == expected)
        #expect(try CGMFeature(data: expected) == feature)
    }

    @Test func encodesRealCRCWhenE2ESupported() throws {
        let feature = CGMFeature(flags: [.e2eCRC, .patientHighLowAlerts], type: .capillaryWholeBlood, sampleLocation: .finger)
        let encoded = feature.encoded()
        #expect(encoded.prefix(4) == Data([0x02, 0x10, 0x00, 0x11]))
        #expect(encoded.isCRCValid)
        #expect(try CGMFeature(data: encoded) == feature)

        var corrupted = encoded
        corrupted[3] = 0x59
        #expect(throws: CGMCodecError.invalidCRC) {
            try CGMFeature(data: corrupted)
        }
    }

    @Test func rejectsUnknownTypeOrLocation() {
        #expect(throws: CGMCodecError.self) {
            try CGMFeature(data: Data([0x00, 0x00, 0x00, 0x50, 0xFF, 0xFF]))
        }
        #expect(throws: CGMCodecError.self) {
            try CGMFeature(data: Data([0x00, 0x00, 0x00, 0x69, 0xFF, 0xFF]))
        }
    }

    @Test func rfuBitsAreMasked() {
        #expect(CGMFeatureFlags(rawValue: 0xFF00_0000).isEmpty)
    }
}

// MARK: - CGM Status

@Suite("CGM Status")
struct CGMStatusTests {
    @Test func roundTrip() throws {
        let status = CGMStatus(timeOffset: 10, sensorStatus: [.timeSynchronizationRequired, .sessionStopped])
        let expected = Data([0x0A, 0x00, 0x01, 0x01, 0x00])
        #expect(status.encoded(e2eCRC: false) == expected)
        #expect(try CGMStatus(data: expected, e2eCRC: false) == status)

        let protected = status.encoded(e2eCRC: true)
        #expect(protected.count == 7)
        #expect(try CGMStatus(data: protected, e2eCRC: true) == status)
    }

    @Test func allThreeOctetsAlwaysPresent() {
        let status = CGMStatus(timeOffset: 0, sensorStatus: [])
        #expect(status.encoded(e2eCRC: false) == Data([0x00, 0x00, 0x00, 0x00, 0x00]))
    }
}

// MARK: - Session Start Time / Run Time

@Suite("CGM Session Start Time")
struct CGMSessionStartTimeTests {
    /// 2026-09-28 14:05:30 in UTC-4 (standard offset -5 h = -20 quarter hours, +1 h daylight).
    @Test func encodesLocalWallClockWithZoneAndDST() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var components = DateComponents(timeZone: zone, year: 2026, month: 9, day: 28, hour: 14, minute: 5, second: 30)
        components.calendar = Calendar(identifier: .gregorian)
        let date = components.date!

        let startTime = CGMSessionStartTime(date: date, timeZone: zone)
        #expect(startTime.timeZoneOffset == -20)
        #expect(startTime.dstOffset == .daylightTime)

        let expected = Data([0xEA, 0x07, 0x09, 0x1C, 0x0E, 0x05, 0x1E, 0xEC, 0x04])
        #expect(startTime.encoded(e2eCRC: false) == expected)

        let decoded = try CGMSessionStartTime(data: expected, e2eCRC: false)
        #expect(decoded == startTime)
        #expect(decoded.date == date)
    }

    @Test func unknownZoneIsTreatedAsUTC() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 06:13:20 UTC
        let startTime = CGMSessionStartTime(date: date, timeZoneOffset: CGMSessionStartTime.unknownTimeZone, dstOffset: .unknown)
        let encoded = startTime.encoded(e2eCRC: false)
        #expect(encoded.suffix(2) == Data([0x80, 0xFF]))
        #expect(encoded.prefix(7) == date.gattDateTime(using: .utc))
        #expect(try CGMSessionStartTime(data: encoded, e2eCRC: false) == startTime)
    }

    @Test func e2eCRC() throws {
        let startTime = CGMSessionStartTime(date: Date(timeIntervalSince1970: 1_790_000_000), timeZoneOffset: 0, dstOffset: .standardTime)
        let protected = startTime.encoded(e2eCRC: true)
        #expect(protected.count == 11)
        #expect(try CGMSessionStartTime(data: protected, e2eCRC: true) == startTime)
        #expect(throws: CGMCodecError.truncated(expected: 11, actual: 9)) {
            try CGMSessionStartTime(data: protected.dropLast(2), e2eCRC: true)
        }
    }

    @Test func rejectsInvalidDSTOffset() {
        var encoded = CGMSessionStartTime(date: Date(), timeZoneOffset: 0, dstOffset: .standardTime).encoded(e2eCRC: false)
        encoded[8] = 0x03
        #expect(throws: CGMCodecError.self) {
            try CGMSessionStartTime(data: encoded, e2eCRC: false)
        }
    }
}

@Suite("CGM Session Run Time")
struct CGMSessionRunTimeTests {
    @Test func roundTrip() throws {
        let runTime = CGMSessionRunTime(hours: 240)
        #expect(runTime.encoded(e2eCRC: false) == Data([0xF0, 0x00]))
        #expect(try CGMSessionRunTime(data: Data([0xF0, 0x00]), e2eCRC: false) == runTime)
        #expect(try CGMSessionRunTime(data: runTime.encoded(e2eCRC: true), e2eCRC: true) == runTime)
    }
}

// MARK: - Constants

@Suite("CGM constants")
struct CGMConstantsTests {
    @Test func characteristicUUIDs() {
        #expect(CGMCharacteristicUUID.service.rawValue == "181f")
        #expect(CGMCharacteristicUUID.measurement.rawValue == "2aa7")
        #expect(CGMCharacteristicUUID.recordAccessControlPoint.rawValue == "2a52")
        #expect(CGMCharacteristicUUID.specificOpsControlPoint.rawValue == "2aac")
        #expect(CGMCharacteristicUUID.service.cbUUID.uuidString == "181F")
    }

    @Test func typeSampleLocationNibbles() {
        let feature = CGMFeature(flags: [], type: .interstitialFluid, sampleLocation: .subcutaneousTissue)
        #expect(feature.typeSampleLocation == 0x59)
    }
}
