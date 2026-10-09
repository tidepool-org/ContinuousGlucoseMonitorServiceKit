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
// The codec itself is tested in BluetoothCommonKit (SFloatTests); here we only pin the glucose-facing contract.

@Suite("SFLOAT mg/dL")
struct SFloatTests {
    /// CGMS values must use the canonical encoding so hand-written spec vectors match byte for byte.
    @Test func glucoseValuesEncodeCanonically() {
        #expect(SFloat.encode(100) == 0x0064)
        #expect(SFloat.encode(120.5) == 0xF4B5)
        #expect(SFloat.encode(.nan) == 0x07FF)
    }

    @Test func recordWithFractionalTrendComparesEqualAfterRoundTrip() throws {
        let record = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 1, trend: 0.3)
        #expect(try CGMMeasurementRecord.decode(record.encoded(e2eCRC: false), e2eCRC: false) == record)
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

    /// 0x07FF in the trend or quality field is a legal "no valid value"; such records must still compare equal.
    @Test func nanTrendAndQualityRoundTrip() throws {
        let record = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 1, trend: .nan, quality: .nan)
        let decoded = try CGMMeasurementRecord.decode(record.encoded(e2eCRC: false), e2eCRC: false)
        #expect(decoded.trend?.isNaN == true)
        #expect(decoded.quality?.isNaN == true)
        #expect(decoded == record)
        #expect(record != CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 1, trend: nil, quality: .nan))
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

    /// A corrupted Flags byte must surface as a CRC failure, not as a size or field error.
    @Test func corruptedFlagsReportInvalidCRC() {
        var protected = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5, trend: 0.5).encoded(e2eCRC: true)
        protected[1] = 0x00
        #expect(throws: CGMCodecError.invalidCRC) {
            try CGMMeasurementRecord.decode(protected, e2eCRC: true)
        }
    }

    /// Size equal to what the Flags announce means the CRC was never sent, whatever optional fields are present.
    @Test func missingCRCWhenE2EExpected() {
        let minimal = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5).encoded(e2eCRC: false)
        #expect(throws: CGMCodecError.missingCRC) {
            try CGMMeasurementRecord.decode(minimal, e2eCRC: true)
        }
        let full = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 5, sensorStatus: .sessionStopped, trend: 1, quality: 90).encoded(e2eCRC: false)
        #expect(throws: CGMCodecError.missingCRC) {
            try CGMMeasurementRecord.decode(full, e2eCRC: true)
        }
    }

    /// An intact CRC with a Size that still disagrees with the Flags is the sender's bug, not corruption.
    @Test func validCRCButSizeDisagreesWithFlagsIsInvalidSize() {
        // Flags 0x00 announce 6 octets of fields, Size claims 7 + CRC.
        let value = Data([0x09, 0x00, 0x64, 0x00, 0x05, 0x00, 0x00]).appendingCRC()
        #expect(value.isCRCValid)
        #expect(throws: CGMCodecError.invalidSize(9)) {
            try CGMMeasurementRecord.decode(value, e2eCRC: true)
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

        // Even when the corruption produces an undefined Type nibble, the CRC failure wins.
        var corruptedType = encoded
        corruptedType[3] = 0x50
        #expect(throws: CGMCodecError.invalidCRC) {
            try CGMFeature(data: corruptedType)
        }
    }

    /// A corruption that clears the E2E bit must not switch the CRC check off for a collector that knows better.
    @Test func priorE2EKnowledgeForcesCRCCheck() throws {
        let feature = CGMFeature(flags: [.e2eCRC, .trendInformation])
        var corrupted = feature.encoded()
        corrupted[1] &= ~0x10   // clear bit 12 (E2E-CRC) in the flags field

        // Bootstrap read: the payload says "no CRC", the 0xFFFF-less trailer is not inspected, frame accepted.
        #expect(try CGMFeature(data: corrupted).isE2ECRCSupported == false)
        // Collector already knows E2E is on: the stale CRC no longer matches, frame rejected.
        #expect(throws: CGMCodecError.invalidCRC) {
            try CGMFeature(data: corrupted, e2eCRC: true)
        }
        // An intact protected frame passes either way.
        #expect(try CGMFeature(data: feature.encoded(), e2eCRC: true) == feature)
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

    /// Persisted flags must be masked on the way back in, and encode as a plain number.
    @Test func codableRoundTripMasksRFUBits() throws {
        let flags = try JSONDecoder().decode(CGMFeatureFlags.self, from: Data("4278190081".utf8))   // 0xFF000001
        #expect(flags == .calibration)
        #expect(String(decoding: try JSONEncoder().encode(CGMFeatureFlags([.calibration, .quality])), as: UTF8.self) == "65537")

        let status = try JSONDecoder().decode(CGMSensorStatusAnnunciation.self, from: Data("4278190081".utf8))
        #expect(status == .sessionStopped)
        #expect(String(decoding: try JSONEncoder().encode(CGMSensorStatusAnnunciation.sessionStopped), as: UTF8.self) == "1")
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

    @Test(arguments: [Int8(57), Int8(-49), Int8(100), Int8(-127)])
    func rejectsOutOfRangeTimeZone(offset: Int8) {
        var encoded = CGMSessionStartTime(date: Date(), timeZoneOffset: 0, dstOffset: .standardTime).encoded(e2eCRC: false)
        encoded[7] = UInt8(bitPattern: offset)
        #expect(throws: CGMCodecError.invalidValue("Time Zone \(offset)")) {
            try CGMSessionStartTime(data: encoded, e2eCRC: false)
        }
    }

    @Test(arguments: [Int8(56), Int8(-48), CGMSessionStartTime.unknownTimeZone])
    func acceptsBoundaryTimeZones(offset: Int8) throws {
        let startTime = CGMSessionStartTime(date: Date(timeIntervalSince1970: 1_790_000_000), timeZoneOffset: offset, dstOffset: .standardTime)
        #expect(try CGMSessionStartTime(data: startTime.encoded(e2eCRC: false), e2eCRC: false) == startTime)
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
