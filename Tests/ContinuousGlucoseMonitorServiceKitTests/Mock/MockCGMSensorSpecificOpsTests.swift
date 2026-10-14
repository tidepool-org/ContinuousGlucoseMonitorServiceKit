//
//  MockCGMSensorSpecificOpsTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-14.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import CoreBluetooth
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

// MARK: - Alert levels and calibration store

@Suite("CGM alert levels")
struct CGMAlertLevelsTests {
    @Test func tripsOnlyTheFamiliesTheFeatureAdvertises() {
        let levels = CGMAlertLevels(patientHigh: 200, patientLow: 80, hypo: 60, hyper: 250, rateOfDecrease: -2, rateOfIncrease: 2)
        let all: CGMFeatureFlags = [.patientHighLowAlerts, .hypoAlerts, .hyperAlerts, .rateOfIncreaseDecreaseAlerts]

        #expect(levels.annunciation(glucose: 120, trend: 0, feature: all) == [])
        #expect(levels.annunciation(glucose: 260, trend: 3, feature: all) == [.resultHigherThanPatientHigh, .resultHigherThanHyper, .rateOfIncreaseExceeded])
        #expect(levels.annunciation(glucose: 55, trend: -2.5, feature: all) == [.resultLowerThanPatientLow, .resultLowerThanHypo, .rateOfDecreaseExceeded])
        // Equal to the level is not "higher than" / "lower than".
        #expect(levels.annunciation(glucose: 200, trend: 2, feature: all) == [])
        // No trend, no rate bits; no feature, no bits.
        #expect(levels.annunciation(glucose: 260, trend: nil, feature: all) == [.resultHigherThanPatientHigh, .resultHigherThanHyper])
        #expect(levels.annunciation(glucose: 260, trend: 3, feature: [.hyperAlerts]) == [.resultHigherThanHyper])
        #expect(levels.annunciation(glucose: .nan, trend: .nan, feature: all) == [])
    }

    @Test func rangesRejectNonFiniteAndOutOfRangeValues() {
        #expect(CGMAlertLevels.isInRange(180, for: .setPatientHighAlertLevel))
        #expect(!CGMAlertLevels.isInRange(5, for: .setPatientLowAlertLevel))
        #expect(!CGMAlertLevels.isInRange(.nan, for: .setHypoAlertLevel))
        #expect(!CGMAlertLevels.isInRange(.infinity, for: .setHyperAlertLevel))
        #expect(CGMAlertLevels.isInRange(-4, for: .setRateOfDecreaseAlertLevel))
        #expect(!CGMAlertLevels.isInRange(75, for: .setRateOfIncreaseAlertLevel))
    }
}

@Suite("CGM calibration store")
struct CGMCalibrationStoreTests {
    private func submitted(_ mgdl: Double, at minutes: UInt16) -> CGMCalibrationRecord {
        // Record Number and Status as a collector might send them: both ignored on a Set.
        CGMCalibrationRecord(glucoseConcentration: mgdl, calibrationTime: minutes, recordNumber: 99, status: .dataRejected)
    }

    @Test func numbersRecordsFromOneAndReportsNextCalibration() {
        var store = CGMCalibrationStore()
        let first = store.store(submitted(110, at: 30), nextCalibrationTime: 750)
        let second = store.store(submitted(130, at: 400), nextCalibrationTime: 1120)
        #expect(first.recordNumber == 1 && second.recordNumber == 2)
        #expect(first.nextCalibrationTime == 750 && first.status == [])
        #expect(store.record(number: 1) == first)
        #expect(store.record(number: CGMCalibrationRecord.lastRecordNumber) == second)
        #expect(store.record(number: 3) == nil)
    }

    @Test func recordZeroIsTheNoCalibrationPlaceholder() throws {
        let store = CGMCalibrationStore()
        let none = try #require(store.record(number: 0))
        #expect(none.recordNumber == 0 && none.calibrationTime == 0 && none.glucoseConcentration.isNaN)
        // An empty store asked for the last record answers the same placeholder, not an error.
        #expect(store.record(number: CGMCalibrationRecord.lastRecordNumber) == none)
    }

    @Test func dropsTheOldestWhenFullAndRestartsNumberingOnRemoveAll() {
        var store = CGMCalibrationStore(capacity: 2)
        for minutes in [10, 20, 30] as [UInt16] { store.store(submitted(100, at: minutes), nextCalibrationTime: 0) }
        #expect(store.records.map(\.recordNumber) == [2, 3])
        #expect(store.record(number: 1) == nil)   // fell out: Parameter Out of Range at the sensor
        store.removeAll()
        #expect(store.count == 0 && store.nextRecordNumber == 1)
    }
}

// MARK: - Sensor procedures

@Suite("MockCGMSensor Specific Ops")
struct MockCGMSensorSpecificOpsTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor
    let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private let box: ClockBox

    init() {
        queue = MockMessageQueue(gattServer: server)
        let box = ClockBox(startedAt)
        sensor = MockCGMSensor(gattServer: server, messageQueue: queue, now: { box.now })
        self.box = box
    }

    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let cgmcp = CGMCharacteristicUUID.specificOpsControlPoint.cbUUID
    private let measurement = CGMCharacteristicUUID.measurement.cbUUID

    /// Writes `request` and returns the decoded indication it produced.
    private func send(_ request: Data) throws -> CGMSpecificOpsResponse {
        let before = queue.items.count
        #expect(sensor.writeSpecificOpsControlPoint(request) == .success)
        let item = try #require(queue.items.last)
        #expect(queue.items.count == before + 1)
        #expect(item.uuid == cgmcp)
        return try CGMSpecificOpsResponse(data: item.value, e2eCRC: false)
    }

    private func request(_ opcode: CGMSpecificOpsOpcode, operand: Data = Data()) -> Data {
        CGMSpecificOpsRequest.encode(opcode, operand: operand, e2eCRC: false)
    }

    private func measurementValues() -> [Data] {
        queue.items.filter { $0.uuid == measurement }.map(\.value)
    }

    // MARK: Communication interval

    /// Measurement and communication cadence are one setting: the operand drives the measurement timer.
    @Test func communicationIntervalIsTheMeasurementInterval() throws {
        #expect(sensor.measurementInterval == 300)
        #expect(try send(request(.getCommunicationInterval)) == .communicationInterval(minutes: 5))

        #expect(try send(CGMSpecificOpsRequest.setCommunicationInterval(minutes: 10, e2eCRC: false)) == .responseCode(request: 0x01, code: 0x01))
        #expect(sensor.measurementInterval == 600)
        #expect(try send(request(.getCommunicationInterval)) == .communicationInterval(minutes: 10))

        // 0xFF: the fastest the sensor offers, reported back as 0xFF because it is under a minute.
        #expect(try send(CGMSpecificOpsRequest.setCommunicationInterval(minutes: 0xFF, e2eCRC: false)) == .responseCode(request: 0x01, code: 0x01))
        #expect(sensor.measurementInterval == MockCGMSensor.fastestMeasurementInterval)
        #expect(try send(request(.getCommunicationInterval)) == .communicationInterval(minutes: 0xFF))

        // The tester's own picker reports in the same terms.
        sensor.measurementInterval = 60
        #expect(sensor.communicationInterval == 1)
    }

    @Test func disabledIntervalStopsPeriodicReadingsAndNotifications() throws {
        server.subscribed.insert(measurement)
        sensor.trace = .constant(mgdl: 100)
        sensor.startSession()
        #expect(sensor.nextMeasurementDate != nil)

        #expect(try send(CGMSpecificOpsRequest.setCommunicationInterval(minutes: 0, e2eCRC: false)) == .responseCode(request: 0x01, code: 0x01))
        #expect(!sensor.isPeriodicCommunicationEnabled)
        #expect(sensor.nextMeasurementDate == nil)   // timer stopped
        #expect(try send(request(.getCommunicationInterval)) == .communicationInterval(minutes: 0))

        // Measure Now still stores a reading for RACP, silently.
        _ = sensor.takeMeasurement()
        #expect(measurementValues().isEmpty)
        #expect(sensor.recordStore.count == 1)

        // Turning it back on resumes the timer at the previous cadence.
        _ = try send(CGMSpecificOpsRequest.setCommunicationInterval(minutes: 5, e2eCRC: false))
        #expect(sensor.isPeriodicCommunicationEnabled)
        #expect(sensor.nextMeasurementDate != nil)
        _ = sensor.takeMeasurement()
        #expect(measurementValues().count == 1)
    }

    // MARK: Calibration

    @Test func calibrationSetAssignsNumbersAndGetReturnsThem() throws {
        sensor.calibrationSchedule = .every(minutes: 600)
        let submitted = CGMCalibrationRecord(glucoseConcentration: 112, calibrationTime: 45, type: .capillaryWholeBlood, sampleLocation: .finger, recordNumber: 42, status: .dataRejected)
        #expect(try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(submitted, e2eCRC: false)) == .responseCode(request: 0x04, code: 0x01))
        #expect(sensor.calibrationStore.count == 1)

        let expected = CGMCalibrationRecord(glucoseConcentration: 112, calibrationTime: 45, nextCalibrationTime: 645, recordNumber: 1, status: [])
        #expect(try send(CGMSpecificOpsRequest.getGlucoseCalibrationValue(recordNumber: 1, e2eCRC: false)) == .calibrationValue(expected))
        #expect(try send(CGMSpecificOpsRequest.getGlucoseCalibrationValue(e2eCRC: false)) == .calibrationValue(expected))   // 0xFFFF = last

        // Record 0 is the placeholder; a number never stored is Parameter Out of Range.
        guard case let .calibrationValue(none) = try send(CGMSpecificOpsRequest.getGlucoseCalibrationValue(recordNumber: 0, e2eCRC: false)) else {
            Issue.record("expected the record 0 placeholder")
            return
        }
        #expect(none.recordNumber == 0 && none.glucoseConcentration.isNaN)
        #expect(try send(CGMSpecificOpsRequest.getGlucoseCalibrationValue(recordNumber: 7, e2eCRC: false)) == .responseCode(request: 0x05, code: 0x05))
    }

    @Test func successfulCalibrationClearsTheCalibrationRequestBits() throws {
        sensor.manualSensorStatus.formUnion([.calibrationRequired, .calibrationRecommended, .deviceSpecificAlert])
        let record = CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 0)

        // A refused calibration leaves the request standing.
        let tooHigh = CGMCalibrationRecord(glucoseConcentration: 900, calibrationTime: 0)
        _ = try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(tooHigh, e2eCRC: false))
        #expect(sensor.sensorStatus.contains(.calibrationRequired))

        _ = try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(record, e2eCRC: false))
        #expect(!sensor.sensorStatus.contains(.calibrationRequired))
        #expect(!sensor.sensorStatus.contains(.calibrationRecommended))
        #expect(sensor.sensorStatus.contains(.deviceSpecificAlert))   // unrelated bits untouched
    }

    @Test func calibrationSchedulesSetNextCalibrationTimeAndInitialStatus() throws {
        func calibrate() throws {
            _ = try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 30), e2eCRC: false))
        }
        #expect(sensor.calibrationSchedule == .oncePerSession)   // default
        sensor.startSession()

        // Once per session: recommended from the start, required after 3 h without one.
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        box.now = startedAt.addingTimeInterval(179 * 60)
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        box.now = startedAt.addingTimeInterval(180 * 60)
        #expect(sensor.calibrationStatus == .calibrationRequired)
        try calibrate()
        #expect(sensor.calibrationStatus == [])
        box.now = startedAt.addingTimeInterval(5000 * 60)
        #expect(sensor.calibrationStatus == [])   // nothing further this session
        box.now = startedAt

        sensor.startSession()
        sensor.calibrationSchedule = .never
        #expect(sensor.calibrationStatus == [])
        try calibrate()
        #expect(sensor.calibrationStore.last?.nextCalibrationTime == CGMCalibrationSchedule.noFurtherCalibration)
        #expect(sensor.calibrationStatus == [])

        sensor.startSession()
        sensor.calibrationSchedule = .immediately
        #expect(sensor.calibrationStatus == .calibrationRequired)
        try calibrate()
        #expect(sensor.calibrationStore.last?.nextCalibrationTime == 0)   // spec: required instantly
        #expect(sensor.calibrationStatus == .calibrationRequired)

        // Periodic: the first calibration is due one interval into the session.
        sensor.startSession()
        sensor.calibrationSchedule = .every(minutes: 1440)
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        box.now = startedAt.addingTimeInterval(1439 * 60)
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        box.now = startedAt.addingTimeInterval(1440 * 60)
        #expect(sensor.calibrationStatus == .calibrationRequired)
        box.now = startedAt
        try calibrate()
        #expect(sensor.calibrationStore.last?.nextCalibrationTime == 1470)

        // A short test schedule keeps a recommended phase: the 20 min lead shrinks to half the interval.
        sensor.startSession()
        sensor.calibrationSchedule = .every(minutes: 10)
        box.now = startedAt.addingTimeInterval(10 * 60)
        #expect(sensor.calibrationStatus == .calibrationRequired)   // first one due at 10 min
        box.now = startedAt
        try calibrate()   // measured at offset 30 → due at 40
        box.now = startedAt.addingTimeInterval(34 * 60)
        #expect(sensor.calibrationStatus == [])
        box.now = startedAt.addingTimeInterval(35 * 60)
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        box.now = startedAt.addingTimeInterval(40 * 60)
        #expect(sensor.calibrationStatus == .calibrationRequired)
    }

    @Test func nextCalibrationTimeRaisesRecommendedThenRequired() throws {
        sensor.calibrationSchedule = .every(minutes: 720)
        sensor.calibrationRecommendedLeadMinutes = 20
        sensor.trace = .constant(mgdl: 100)
        // Nothing stored yet: the sensor recommends a first calibration, unless it does not support calibration.
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        sensor.feature.flags.remove(.calibration)
        #expect(sensor.calibrationStatus == [])
        sensor.feature.flags.insert(.calibration)
        sensor.startSession()
        #expect(sensor.sensorStatus.contains(.calibrationRecommended))

        _ = try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 0), e2eCRC: false))
        #expect(sensor.calibrationStore.last?.nextCalibrationTime == 720)
        #expect(sensor.calibrationStatus == [])   // satisfied

        box.now = startedAt.addingTimeInterval(699 * 60)
        #expect(sensor.calibrationStatus == [])
        box.now = startedAt.addingTimeInterval(700 * 60)
        #expect(sensor.calibrationStatus == .calibrationRecommended)
        #expect(sensor.status.sensorStatus.contains(.calibrationRecommended))
        box.now = startedAt.addingTimeInterval(720 * 60)
        #expect(sensor.calibrationStatus == .calibrationRequired)
        // The record taken now carries the bit.
        let record = try #require(sensor.takeMeasurement())
        #expect(record.sensorStatus.contains(.calibrationRequired))

        // Calibrating again moves the due time out and clears both bits.
        _ = try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 720), e2eCRC: false))
        #expect(sensor.calibrationStore.last?.nextCalibrationTime == 1440)
        #expect(sensor.calibrationStatus == [])
    }

    @Test func calibrationRejectsOutOfRangeGlucoseAndBadNibbles() throws {
        let tooHigh = CGMCalibrationRecord(glucoseConcentration: 900, calibrationTime: 0)
        #expect(try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(tooHigh, e2eCRC: false)) == .responseCode(request: 0x04, code: 0x05))
        #expect(sensor.calibrationStore.count == 0)

        // Type nibble 0 is reserved: the operand decodes as invalid.
        var bad = CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 0).encoded()
        bad[4] = 0x00
        #expect(try send(request(.setGlucoseCalibrationValue, operand: bad)) == .responseCode(request: 0x04, code: 0x03))
    }

    @Test func calibrationIsExcludedWithoutTheFeatureAndClearedByStartSession() throws {
        let record = CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 0)
        _ = try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(record, e2eCRC: false))
        #expect(sensor.calibrationStore.count == 1)
        sensor.startSession()
        #expect(sensor.calibrationStore.count == 0)

        sensor.feature.flags.remove(.calibration)
        #expect(try send(CGMSpecificOpsRequest.setGlucoseCalibrationValue(record, e2eCRC: false)) == .responseCode(request: 0x04, code: 0x02))
        #expect(try send(CGMSpecificOpsRequest.getGlucoseCalibrationValue(e2eCRC: false)) == .responseCode(request: 0x05, code: 0x02))
    }

    // MARK: Alert levels

    @Test func everyAlertLevelSetsAndGets() throws {
        let cases: [(set: CGMSpecificOpsOpcode, get: CGMSpecificOpsOpcode, response: CGMSpecificOpsOpcode, value: Double)] = [
            (.setPatientHighAlertLevel, .getPatientHighAlertLevel, .patientHighAlertLevelResponse, 220),
            (.setPatientLowAlertLevel, .getPatientLowAlertLevel, .patientLowAlertLevelResponse, 65),
            (.setHypoAlertLevel, .getHypoAlertLevel, .hypoAlertLevelResponse, 50),
            (.setHyperAlertLevel, .getHyperAlertLevel, .hyperAlertLevelResponse, 280),
            (.setRateOfDecreaseAlertLevel, .getRateOfDecreaseAlertLevel, .rateOfDecreaseAlertLevelResponse, -2.5),
            (.setRateOfIncreaseAlertLevel, .getRateOfIncreaseAlertLevel, .rateOfIncreaseAlertLevelResponse, 2.5)
        ]
        for entry in cases {
            #expect(try send(CGMSpecificOpsRequest.setLevel(entry.set, value: entry.value, e2eCRC: false)) == .responseCode(request: entry.set.rawValue, code: 0x01))
            #expect(try send(request(entry.get)) == .level(opcode: entry.response, value: entry.value))
        }
        #expect(sensor.alertLevels == CGMAlertLevels(patientHigh: 220, patientLow: 65, hypo: 50, hyper: 280, rateOfDecrease: -2.5, rateOfIncrease: 2.5))
    }

    @Test func alertLevelOutOfRangeLeavesTheLevelUnchanged() throws {
        #expect(try send(CGMSpecificOpsRequest.setLevel(.setPatientHighAlertLevel, value: 1000, e2eCRC: false)) == .responseCode(request: 0x07, code: 0x05))
        #expect(try send(CGMSpecificOpsRequest.setLevel(.setRateOfIncreaseAlertLevel, value: 80, e2eCRC: false)) == .responseCode(request: 0x16, code: 0x05))
        #expect(sensor.alertLevels == CGMAlertLevels())
    }

    @Test func alertLevelOpCodesAreExcludedWithoutTheirFeature() throws {
        sensor.feature.flags.subtract([.patientHighLowAlerts, .hypoAlerts, .hyperAlerts, .rateOfIncreaseDecreaseAlerts])
        for opcode in [CGMSpecificOpsOpcode.getPatientHighAlertLevel, .getPatientLowAlertLevel, .getHypoAlertLevel, .getHyperAlertLevel, .getRateOfDecreaseAlertLevel, .getRateOfIncreaseAlertLevel] {
            #expect(try send(request(opcode)) == .responseCode(request: opcode.rawValue, code: 0x02))
        }
        #expect(try send(CGMSpecificOpsRequest.setLevel(.setHypoAlertLevel, value: 60, e2eCRC: false)) == .responseCode(request: 0x0D, code: 0x02))
    }

    @Test func measurementsCarryTheAlertBitsTheyTrip() throws {
        server.subscribed.insert(measurement)
        sensor.trace = .constant(mgdl: 260)
        sensor.startSession()
        let record = try #require(sensor.takeMeasurement())
        #expect(record.sensorStatus.contains(.resultHigherThanPatientHigh))   // default high is 250
        #expect(!record.sensorStatus.contains(.resultHigherThanHyper))        // default hyper is 300
        #expect(sensor.status.sensorStatus.contains(.resultHigherThanPatientHigh))

        // Lowering the hyper level re-evaluates the latest reading at once.
        _ = try send(CGMSpecificOpsRequest.setLevel(.setHyperAlertLevel, value: 255, e2eCRC: false))
        #expect(sensor.sensorStatus.contains(.resultHigherThanHyper))

        // The notified record matches what the sensor reports.
        let notified = try CGMMeasurementRecord.decode(try #require(measurementValues().first), e2eCRC: false)
        #expect(notified.sensorStatus.contains(.resultHigherThanPatientHigh))

        // Back in range: the bits clear on the next reading.
        sensor.trace = .constant(mgdl: 120)
        _ = sensor.takeMeasurement()
        #expect(sensor.sensorStatus.isDisjoint(with: CGMAlertLevels.annunciationBits))
    }

    // MARK: Device specific alert

    @Test func resetDeviceSpecificAlertClearsTheBit() throws {
        sensor.manualSensorStatus.insert(.deviceSpecificAlert)
        #expect(sensor.sensorStatus.contains(.deviceSpecificAlert))
        #expect(try send(request(.resetDeviceSpecificAlert)) == .responseCode(request: 0x19, code: 0x01))
        #expect(!sensor.sensorStatus.contains(.deviceSpecificAlert))

        sensor.feature.flags.remove(.deviceSpecificAlert)
        #expect(try send(request(.resetDeviceSpecificAlert)) == .responseCode(request: 0x19, code: 0x02))
    }

    // MARK: E2E

    @Test func valueResponsesCarryTheCRCWhenE2ESupported() throws {
        sensor.feature.flags.insert(.e2eCRC)
        #expect(sensor.writeSpecificOpsControlPoint(CGMSpecificOpsRequest.encode(.getPatientHighAlertLevel, e2eCRC: true)) == .success)
        let value = try #require(queue.items.last?.value)
        #expect(value.isCRCValid)
        #expect(try CGMSpecificOpsResponse(data: value, e2eCRC: true) == .level(opcode: .patientHighAlertLevelResponse, value: 250))
    }
}
