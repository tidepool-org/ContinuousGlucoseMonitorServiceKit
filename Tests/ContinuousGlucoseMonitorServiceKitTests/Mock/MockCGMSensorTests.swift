//
//  MockCGMSensorTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-01.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import CoreBluetooth
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

@Suite("MockCGMSensor")
struct MockCGMSensorTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor
    let startedAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// The sensor reads `now` through this box so tests can advance the clock.
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

    // MARK: - GATT layout

    @Test func publishesCGMDeviceInformationBatteryAndAuthorizationServices() {
        let uuids = server.services.map(\.uuid)
        #expect(uuids == [
            CGMCharacteristicUUID.service.cbUUID,
            DeviceInfoCharacteristicUUID.service.cbUUID,
            BatteryCharacteristicUUID.service.cbUUID,
            ACCharacteristicUUID.service.cbUUID
        ])
        #expect(server.services.allSatisfy { $0.primary })
        #expect(server.addServiceCount == 1)
        #expect(server.startAdvertisingCount == 1)
    }

    @Test func cgmServiceHasEveryCharacteristicWithSpecProperties() {
        let cgm = server.services[0].characteristics
        #expect(cgm.count == 7)
        #expect(server.characteristic(.measurement)?.properties == .notify)
        #expect(server.characteristic(.feature)?.properties == [.read, .indicate])
        #expect(server.characteristic(.status)?.properties == .read)
        #expect(server.characteristic(.sessionStartTime)?.properties == [.read, .write])
        #expect(server.characteristic(.sessionRunTime)?.properties == .read)
        #expect(server.characteristic(.recordAccessControlPoint)?.properties == [.write, .indicate])
        #expect(server.characteristic(.specificOpsControlPoint)?.properties == [.write, .indicate])
    }

    @Test func cgmCharacteristicsAreOpenByDefault() {
        #expect(server.characteristic(.feature)?.permissions == .readable)
        #expect(server.characteristic(.sessionStartTime)?.permissions == [.readable, .writeable])
        #expect(server.characteristic(.specificOpsControlPoint)?.permissions == .writeable)
    }

    @Test func cgmCharacteristicsRequireEncryptionWhenAsked() {
        let server = MockGATTService()
        _ = MockCGMSensor(gattServer: server, messageQueue: MockMessageQueue(gattServer: server), requiresEncryption: true)
        #expect(server.characteristic(.feature)?.permissions == .readEncryptionRequired)
        #expect(server.characteristic(.sessionStartTime)?.permissions == [.readEncryptionRequired, .writeEncryptionRequired])
        #expect(server.characteristic(.specificOpsControlPoint)?.permissions == .writeEncryptionRequired)
    }

    @Test func deviceInformationIncludesMandatorySystemID() {
        let dis = server.services[1].characteristics
        #expect(dis.contains { $0.uuid == DeviceInfoCharacteristicUUID.systemID.cbUUID })
        let systemID = dis.first { $0.uuid == DeviceInfoCharacteristicUUID.systemID.cbUUID }!
        #expect(systemID.onRead().1 == CGMDeviceInformation.simulatorDefault.systemID)
    }

    // MARK: - Power-on state

    @Test func powersOnIdleUntilSessionStarts() throws {
        #expect(sensor.sessionState == .notStarted)
        #expect(sensor.nextMeasurementDate != nil)   // the cadence ticks from power-on, status-only until a session runs
        #expect(sensor.takeMeasurement() == nil)

        box.now = startedAt.addingTimeInterval(20 * 60)
        #expect(sensor.timeOffset == 0)
        let status = try CGMStatus(data: sensor.readStatus().1, e2eCRC: false)
        #expect(status.timeOffset == 0)
        #expect(status.sensorStatus == [.sessionStopped, .calibrationRecommended])   // no calibration stored yet
        #expect(sensor.sessionStartTime == nil)

        sensor.startSession()
        #expect(sensor.sessionState == .running)
        #expect(sensor.timeOffset == 0)   // offset restarts at the (new) session start
        #expect(sensor.nextMeasurementDate != nil)
    }

    /// The simulator knows its clock, so starting a session (from the UI or CGMCP) sets Session Start Time
    /// itself and nothing asks the collector for a time sync.
    @Test func startSessionSetsSessionStartTimeFromDeviceClock() throws {
        box.now = startedAt.addingTimeInterval(45 * 60)
        sensor.startSession()

        let startTime = try #require(sensor.sessionStartTime)
        #expect(startTime.date == box.now)
        #expect(startTime == CGMSessionStartTime(date: box.now, timeZone: .current))
        #expect(!sensor.sessionStartTimeSetByCollector)
        #expect(!sensor.sensorStatus.contains(.timeSynchronizationRequired))
        #expect(sensor.readSessionStartTime().1 == startTime.encoded(e2eCRC: false))
    }

    @Test func timeSyncRequiredIsTesterControlled() {
        sensor.startSession()
        sensor.manualSensorStatus.insert(.timeSynchronizationRequired)
        #expect(sensor.sensorStatus.contains(.timeSynchronizationRequired))
        sensor.manualSensorStatus.remove(.timeSynchronizationRequired)
        #expect(!sensor.sensorStatus.contains(.timeSynchronizationRequired))
    }

    // MARK: - Reads

    @Test func readsEncodeCurrentState() throws {
        sensor.startSession()
        #expect(sensor.readFeature().1 == CGMFeature.simulatorDefault.encoded())
        #expect(sensor.readSessionRunTime().1 == Data([0xF0, 0x00]))

        let status = try CGMStatus(data: sensor.readStatus().1, e2eCRC: false)
        #expect(status.timeOffset == 0)
        #expect(status.sensorStatus == [.calibrationRecommended])   // fresh sensor asks for a first calibration
    }

    @Test func timeOffsetAdvancesWithTheClock() {
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(7 * 60 + 30)
        #expect(sensor.timeOffset == 7)
    }

    // MARK: - Session Start Time

    @Test func writingSessionStartTimeDerivesSessionStartFromTimeOffset() throws {
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(10 * 60)
        let collectorNow = Date(timeIntervalSince1970: 1_790_100_000)
        let written = CGMSessionStartTime(date: collectorNow, timeZoneOffset: -20, dstOffset: .daylightTime)

        #expect(sensor.writeSessionStartTime(written.encoded(e2eCRC: false)) == .success)

        let stored = try #require(sensor.sessionStartTime)
        #expect(stored.date == collectorNow.addingTimeInterval(-10 * 60))
        #expect(stored.timeZoneOffset == -20)
        #expect(stored.dstOffset == .daylightTime)
        #expect(sensor.sessionStartTimeSetByCollector)
        #expect(sensor.readSessionStartTime().1 == stored.encoded(e2eCRC: false))
    }

    @Test func rejectsMalformedSessionStartTime() {
        #expect(sensor.writeSessionStartTime(nil) == .invalidPdu)
        #expect(sensor.writeSessionStartTime(Data([0x01, 0x02])) == .invalidAttributeValueLength)
        // Right size, but Time Zone 100 is outside -48...56.
        var badZone = CGMSessionStartTime(date: startedAt, timeZoneOffset: 0, dstOffset: .standardTime).encoded(e2eCRC: false)
        badZone[7] = 100
        #expect(sensor.writeSessionStartTime(badZone) == .outOfRange)
        #expect(sensor.sessionStartTime == nil)
    }

    /// Size first, then CRC: wrong length is a length error even with E2E on; exact payload is Missing CRC.
    @Test func enforcesE2ECRCOnWritesWhenSupported() {
        sensor.feature.flags.insert(.e2eCRC)
        let startTime = CGMSessionStartTime(date: startedAt, timeZoneOffset: 0, dstOffset: .standardTime)

        #expect(sensor.writeSessionStartTime(startTime.encoded(e2eCRC: false)).rawValue == 0x80)
        var corrupted = startTime.encoded(e2eCRC: true)
        corrupted[0] ^= 0xFF
        #expect(sensor.writeSessionStartTime(corrupted).rawValue == 0x81)
        #expect(sensor.writeSessionStartTime(startTime.encoded(e2eCRC: true) + Data([0x00])) == .invalidAttributeValueLength)
        #expect(sensor.writeSessionStartTime(startTime.encoded(e2eCRC: false).dropLast()) == .invalidAttributeValueLength)
        #expect(sensor.writeSessionStartTime(startTime.encoded(e2eCRC: true)) == .success)
    }

    /// CGMS §3.3.1: Status carries the offset of the most recent measurement, so it must not grow after a stop.
    @Test func timeOffsetFreezesWhileStopped() throws {
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(30 * 60)
        sensor.stopSession()
        box.now = startedAt.addingTimeInterval(90 * 60)

        #expect(sensor.timeOffset == 30)
        let status = try CGMStatus(data: sensor.readStatus().1, e2eCRC: false)
        #expect(status.timeOffset == 30)
        #expect(status.sensorStatus.contains(.sessionStopped))

        // A Session Start Time written during the stop derives from the frozen offset.
        let collectorNow = Date(timeIntervalSince1970: 1_790_100_000)
        _ = sensor.writeSessionStartTime(CGMSessionStartTime(date: collectorNow, timeZoneOffset: 0, dstOffset: .standardTime).encoded(e2eCRC: false))
        #expect(sensor.sessionStartTime?.date == collectorNow.addingTimeInterval(-30 * 60))
    }

    @Test func startSessionResetsOffsetAndReplacesCollectorStartTime() {
        sensor.startSession()
        _ = sensor.writeSessionStartTime(CGMSessionStartTime(date: startedAt, timeZoneOffset: 0, dstOffset: .standardTime).encoded(e2eCRC: false))
        #expect(sensor.sessionStartTimeSetByCollector)
        box.now = startedAt.addingTimeInterval(30 * 60)

        sensor.stopSession()
        #expect(sensor.sensorStatus.contains(.sessionStopped))

        sensor.startSession()
        #expect(sensor.sessionState == .running)
        #expect(sensor.timeOffset == 0)
        #expect(sensor.sessionStartTime?.date == box.now)   // new session, new clock-derived start
        #expect(!sensor.sessionStartTimeSetByCollector)
        #expect(sensor.sensorStatus == [.calibrationRecommended])
    }

    // MARK: - Measurements

    @Test func measurementSamplesTraceAtElapsedTime() throws {
        sensor.trace = .constant(mgdl: 110)
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(12 * 60 + 5)

        let record = try #require(sensor.takeMeasurement())
        #expect(record.glucoseConcentration == 110)
        #expect(record.timeOffset == 12)
        #expect(record.trend == 0)                 // trend feature on by default, flat trace
        #expect(record.quality == 100)             // quality feature on by default
        #expect(record.sensorStatus == [.calibrationRecommended])   // no calibration stored yet
        #expect(sensor.lastMeasurement == record)
        #expect(queue.items.isEmpty)               // nobody subscribed yet
    }

    @Test func sineTraceMovesWithTime() {
        sensor.trace = .sineCurve(base: 120, amplitude: 40, period: 60 * 60)
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(15 * 60)   // quarter period: peak
        #expect(sensor.takeMeasurement()?.glucoseConcentration == 160)
        box.now = startedAt.addingTimeInterval(45 * 60)   // three quarters: trough
        #expect(sensor.takeMeasurement()?.glucoseConcentration == 80)
    }

    /// A scenario advances one value per measurement whatever the clock says, and wraps at the end. Trend
    /// comes from the recorded sample spacing, so a fast playback interval does not inflate it.
    @Test func scenarioStepsOneValuePerMeasurementAndWraps() {
        sensor.trace = .scenario(CGMGlucoseScenario(name: "ramp", values: [100, 160, 130], sampleInterval: 10 * 60))
        sensor.measurementInterval = 5

        sensor.startSession()

        // Clock barely moves; the values still advance.
        let first = sensor.takeMeasurement()
        #expect(first?.glucoseConcentration == 100)
        #expect(first?.trend == 0)          // no previous value
        box.now = startedAt.addingTimeInterval(5)
        let second = sensor.takeMeasurement()
        #expect(second?.glucoseConcentration == 160)
        #expect(second?.trend == 6)         // +60 over the recorded 10 min, not over the 5 s playback
        let third = sensor.takeMeasurement()
        #expect(third?.glucoseConcentration == 130)
        #expect(third?.trend == -3)
        // Wrap: back to the first value; the trend crosses the seam.
        let fourth = sensor.takeMeasurement()
        #expect(fourth?.glucoseConcentration == 100)
        #expect(fourth?.trend == -3)

        // A new session restarts the scenario.
        sensor.startSession()
        #expect(sensor.takeMeasurement()?.glucoseConcentration == 100)
    }

    @Test func scenarioHoldsLastValueWhenNotRepeating() {
        let scenario = CGMGlucoseScenario(name: "hold", values: [90, 95], repeats: false)
        #expect(scenario.value(at: 0) == 90)
        #expect(scenario.value(at: 1) == 95)
        #expect(scenario.value(at: 7) == 95)
        #expect(CGMGlucoseScenario(name: "wrap", values: [90, 95]).value(at: 7) == 95)   // odd index wraps to 95
        #expect(CGMGlucoseScenario(name: "wrap", values: [90, 95]).value(at: 8) == 90)
    }

    @Test func switchingTraceRestartsScenario() {
        sensor.trace = .scenario(CGMGlucoseScenario(name: "a", values: [100, 110, 120]))
        sensor.startSession()
        _ = sensor.takeMeasurement()
        _ = sensor.takeMeasurement()
        sensor.trace = .scenario(CGMGlucoseScenario(name: "b", values: [50, 60]))
        #expect(sensor.takeMeasurement()?.glucoseConcentration == 50)
    }

    @Test func scenarioRoundTripsThroughJSON() throws {
        let scenario = CGMGlucoseScenario(name: "ramp", values: [100, 110], repeats: false, sampleInterval: 60)
        let data = try JSONEncoder().encode(scenario)
        #expect(try JSONDecoder().decode(CGMGlucoseScenario.self, from: data) == scenario)

        // Optional keys fall back to defaults.
        let minimal = try JSONDecoder().decode(CGMGlucoseScenario.self, from: Data(#"{"name":"m","values":[1]}"#.utf8))
        #expect(minimal.repeats)
        #expect(minimal.sampleInterval == 300)
    }

    @Test func measurementIsNotifiedOnlyWhenSubscribed() throws {
        sensor.trace = .constant(mgdl: 95)
        sensor.startSession()
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)

        let record = try #require(sensor.takeMeasurement())
        #expect(queue.items.count == 1)
        #expect(queue.items[0].uuid == CGMCharacteristicUUID.measurement.cbUUID)
        #expect(try CGMMeasurementRecord.decode(queue.items[0].value, e2eCRC: false) == record)
    }

    @Test func noMeasurementsWhileStopped() {
        sensor.startSession()
        sensor.stopSession()
        #expect(sensor.takeMeasurement() == nil)
        sensor.startSession()
        #expect(sensor.lastMeasurement == nil)
        #expect(sensor.takeMeasurement() != nil)
    }

    @Test func omitsTrendAndQualityWhenFeaturesAreOff() throws {
        sensor.feature.flags.remove([.trendInformation, .quality])
        sensor.startSession()
        let record = try #require(sensor.takeMeasurement())
        #expect(record.trend == nil)
        #expect(record.quality == nil)
    }

    /// Real timers: measurements keep flowing across an interval change made while the session runs.
    @Test @MainActor func timerKeepsFiringAfterIntervalChange() {
        let server = MockGATTService()
        let queue = MockMessageQueue(gattServer: server)
        let sensor = MockCGMSensor(gattServer: server, messageQueue: queue)
        sensor.trace = .constant(mgdl: 100)
        sensor.startSession()
        sensor.measurementInterval = 0.05

        var count = 0
        var staleNextDates = 0
        let probe = CountingDelegate { [weak sensor] in
            count += 1
            // Observers are told from inside the timer callback; the next date must still lie ahead.
            if let next = sensor?.nextMeasurementDate, next <= Date() { staleNextDates += 1 }
        }
        sensor.delegate = probe
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let firstPhase = count
        #expect(firstPhase >= 3, "expected several measurements at 50 ms, got \(firstPhase)")

        sensor.measurementInterval = 0.02
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(count > firstPhase + 3, "expected measurements to continue after the interval change")
        #expect(staleNextDates == 0, "next measurement date was in the past \(staleNextDates) times")
        #expect(sensor.measurementCount == count - 1)   // one delegate call came from the interval change
        #expect(sensor.nextMeasurementDate.map { $0 > Date() } == true)
        sensor.stopSession()
        #expect(sensor.nextMeasurementDate != nil)   // keeps ticking; the ticks now carry status only
    }

    final class CountingDelegate: MockCGMSensorDelegate {
        let onUpdate: () -> Void
        init(onUpdate: @escaping () -> Void) { self.onUpdate = onUpdate }
        func mockSensorDidUpdate(_ sensor: MockCGMSensor) { onUpdate() }
    }

    // MARK: - Lifetime

    /// The server keeps the characteristics; their handlers must not keep the sensor.
    @Test func deallocatesOnceReleased() {
        let server = MockGATTService()
        let queue = MockMessageQueue(gattServer: server)
        weak var weakSensor: MockCGMSensor?
        do {
            let sensor = MockCGMSensor(gattServer: server, messageQueue: queue)
            weakSensor = sensor
            #expect(weakSensor != nil)
        }
        #expect(weakSensor == nil)
        // Handlers left behind answer safely instead of crashing.
        #expect(server.characteristic(.feature)?.onRead().0 == .unlikelyError)
    }

    // MARK: - Control points

    @Test func cgmcpStartAndStopSessionProcedures() throws {
        // Start from idle.
        #expect(sensor.writeSpecificOpsControlPoint(Data([CGMSpecificOpsOpcode.startSession.rawValue])) == .success)
        #expect(sensor.sessionState == .running)
        #expect(queue.items.last?.value == Data([0x1C, 0x1A, 0x01]))

        // Stop while running.
        #expect(sensor.writeSpecificOpsControlPoint(Data([CGMSpecificOpsOpcode.stopSession.rawValue])) == .success)
        #expect(sensor.sessionState == .stopped)
        #expect(queue.items.last?.value == Data([0x1C, 0x1B, 0x01]))

        // Stop again: §3.7.2.9 says Op Code not supported.
        #expect(sensor.writeSpecificOpsControlPoint(Data([CGMSpecificOpsOpcode.stopSession.rawValue])) == .success)
        #expect(queue.items.last?.value == Data([0x1C, 0x1B, 0x02]))
        #expect(queue.items.count == 3)
    }

    @Test func cgmcpStartSessionRestartsARunningSession() throws {
        sensor.trace = .constant(mgdl: 100)
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(40 * 60)
        _ = sensor.takeMeasurement()
        #expect(sensor.timeOffset == 40)

        _ = sensor.writeSpecificOpsControlPoint(Data([CGMSpecificOpsOpcode.startSession.rawValue]))
        #expect(sensor.timeOffset == 0)
        #expect(sensor.lastMeasurement == nil)   // §3.7.2.8: previous session data discarded
    }

    @Test func cgmcpAnswersOpCodeNotSupportedForUnknownOpCodes() {
        // 0x30 is outside Table 3.6; a response op code written by a client is equally unknown.
        #expect(sensor.writeSpecificOpsControlPoint(Data([0x30])) == .success)
        #expect(queue.items.count == 1)
        #expect(queue.items[0].uuid == CGMCharacteristicUUID.specificOpsControlPoint.cbUUID)
        #expect(queue.items[0].value == Data([0x1C, 0x30, 0x02]))

        #expect(sensor.writeSpecificOpsControlPoint(Data([CGMSpecificOpsOpcode.responseCode.rawValue, 0x01, 0x01])) == .success)
        #expect(queue.items.last?.value == Data([0x1C, 0x1C, 0x02]))
    }

    @Test func cgmcpResponseCarriesCRCWhenE2ESupported() {
        sensor.feature.flags.insert(.e2eCRC)
        let request = Data([CGMSpecificOpsOpcode.startSession.rawValue]).appendingCRC()
        #expect(sensor.writeSpecificOpsControlPoint(request) == .success)
        let response = queue.items[0].value
        #expect(response.count == 5)
        #expect(response.isCRCValid)
        #expect(response.prefix(3) == Data([0x1C, 0x1A, 0x01]))

        #expect(sensor.writeSpecificOpsControlPoint(Data([0x02])).rawValue == 0x80)
    }

    /// Operand size is checked before the CRC: wrong size → Invalid Operand, right size without CRC →
    /// Missing CRC, right size with a bad CRC → Invalid CRC.
    @Test func cgmcpValidatesOperandSizeBeforeCRC() {
        // No E2E: a bare Set Communication Interval lacks its 1-octet operand.
        #expect(sensor.writeSpecificOpsControlPoint(Data([0x01])) == .success)
        #expect(queue.items.last?.value == Data([0x1C, 0x01, 0x03]))
        // Extra octet on an operand-free op code is also Invalid Operand.
        #expect(sensor.writeSpecificOpsControlPoint(Data([0x1A, 0x00])) == .success)
        #expect(queue.items.last?.value == Data([0x1C, 0x1A, 0x03]))
        #expect(sensor.sessionState == .notStarted)

        sensor.feature.flags.insert(.e2eCRC)
        let level = CGMSpecificOpsRequest.setLevel(.setPatientHighAlertLevel, value: 180, e2eCRC: false)   // 3 octets, no CRC
        #expect(sensor.writeSpecificOpsControlPoint(level).rawValue == 0x80)

        var corrupted = level.appendingCRC()
        corrupted[1] ^= 0xFF
        #expect(sensor.writeSpecificOpsControlPoint(corrupted).rawValue == 0x81)

        let short = Data([0x07, 0x00]).appendingCRC()   // operand truncated to 1 octet, CRC present
        #expect(sensor.writeSpecificOpsControlPoint(short) == .success)
        #expect(queue.items.last?.value.prefix(3) == Data([0x1C, 0x07, 0x03]))
        #expect(queue.items.last?.value.isCRCValid == true)

        // Right size and CRC: reaches the procedure and the level is stored.
        #expect(sensor.writeSpecificOpsControlPoint(level.appendingCRC()) == .success)
        #expect(queue.items.last?.value.prefix(3) == Data([0x1C, 0x07, 0x01]))
        #expect(sensor.alertLevels.patientHigh == 180)
    }

    @Test func measurementIntervalRejectsNonPositiveValues() {
        sensor.measurementInterval = 60
        sensor.measurementInterval = 0
        #expect(sensor.measurementInterval == 60)
        sensor.measurementInterval = -5
        #expect(sensor.measurementInterval == 60)
    }

    @Test func racpReportsZeroStoredRecordsOnAnEmptyDatabase() {
        let request = Data([CGMRACPOpcode.reportNumberOfStoredRecords.rawValue, CGMRACPOperator.allRecords.rawValue])
        #expect(sensor.writeRecordAccessControlPoint(request) == .success)
        #expect(queue.items[0].uuid == CGMCharacteristicUUID.recordAccessControlPoint.cbUUID)
        #expect(queue.items[0].value == Data([0x05, 0x00, 0x00, 0x00]))
    }

    // MARK: - Feature changes

    @Test func featureChangeIndicatesOnlyWhenSubscribed() {
        sensor.feature.flags.remove(.quality)
        #expect(queue.items.isEmpty)

        server.subscribed.insert(CGMCharacteristicUUID.feature.cbUUID)
        sensor.feature.flags.insert(.quality)
        #expect(queue.items.count == 1)
        #expect(queue.items[0].uuid == CGMCharacteristicUUID.feature.cbUUID)
        #expect(queue.items[0].value == sensor.feature.encoded())
    }
}
