//
//  MockCGMSensorLifecycleTests.swift
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

@Suite("MockCGMSensor lifecycle")
struct MockCGMSensorLifecycleTests {
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
        sensor.trace = .constant(mgdl: 120)
    }

    /// The response code a bare-opcode procedure answers with; nil when the sensor answered with a value instead.
    private func cgmcp(_ opcode: CGMSpecificOpsOpcode) throws -> CGMSpecificOpsResponseCode? {
        guard case .responseCode(opcode.rawValue, let code) = try cgmcpSend(cgmcpRequest(opcode), to: sensor, queue: queue) else { return nil }
        return CGMSpecificOpsResponseCode(rawValue: code)
    }

    // MARK: Warm-up (TBD-03)

    @Test func warmupSuppressesReadingsAndIsEditableLive() throws {
        sensor.warmupDuration = 60
        sensor.startSession()
        #expect(sensor.isWarmingUp)
        #expect(sensor.warmupEndDate == startedAt.addingTimeInterval(60))
        #expect(sensor.takeMeasurement() == nil)
        #expect(sensor.nextMeasurementDate != nil)   // the cadence ticks through the warm-up, status only

        box.now = startedAt.addingTimeInterval(30)
        #expect(sensor.takeMeasurement() == nil)
        sensor.warmupDuration = 45
        #expect(sensor.isWarmingUp)

        // Shortening the warm-up below the elapsed time ends it at once and re-aligns the cadence to now.
        sensor.warmupDuration = 10
        #expect(!sensor.isWarmingUp)
        #expect(sensor.warmupEndDate == nil)
        #expect(sensor.nextMeasurementDate != nil)
        let record = try #require(sensor.takeMeasurement())
        #expect(record.timeOffset == 0)
        #expect(record.glucoseConcentration == 120)

        // Zero warm-up (the kit default) reports immediately after Start Session.
        sensor.warmupDuration = 0
        sensor.startSession()
        #expect(!sensor.isWarmingUp)
        #expect(sensor.takeMeasurement() != nil)
    }

    // MARK: Sensor failure (HYD-G-006)

    @Test func failedSensorStopsReportingUntilReplaced() throws {
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        sensor.startSession()
        #expect(sensor.takeMeasurement() != nil)

        sensor.failSensor()
        #expect(sensor.condition == .failed)
        // CGM Status cannot be notified, so the failure goes out at once as a status-only record (NaN glucose,
        // Sensor Malfunction bit) that is not stored as a measurement.
        let notified = queue.items.filter { $0.uuid == CGMCharacteristicUUID.measurement.cbUUID }
        #expect(notified.count == 2)
        let status = try CGMMeasurementRecord.decode(try #require(notified.last?.value), e2eCRC: false)
        #expect(status.glucoseConcentration.isNaN)
        #expect(status.sensorStatus.contains(.sensorMalfunction))
        #expect(sensor.lastStatusRecord == status)
        #expect(sensor.recordStore.count == 1)
        #expect(sensor.takeMeasurement() == nil)
        #expect(sensor.sessionState == .running)   // the session itself is untouched; RACP still serves
        #expect(sensor.sensorStatus.contains(.sensorMalfunction))
        #expect(sensor.lifecycleEvents.last?.kind == .sensorFailed)

        // The bit only shows when the Feature advertises malfunction detection.
        sensor.feature.flags.remove(.sensorMalfunctionDetection)
        #expect(!sensor.sensorStatus.contains(.sensorMalfunction))
        sensor.feature.flags.insert(.sensorMalfunctionDetection)

        // The collector cannot start a session on a failed sensor; the refusal is on record.
        #expect(try cgmcp(.startSession) == .procedureNotCompleted)
        let rejected = try #require(sensor.lifecycleEvents.last)
        #expect(rejected.kind == .sessionStarted && rejected.source == .collector && !rejected.accepted)
        // Nor can the tester, other than by replacing it.
        #expect(!sensor.startSession())

        sensor.replaceSensor()
        #expect(sensor.condition == .healthy)
        #expect(sensor.sessionState == .running)
        #expect(sensor.recordStore.isEmpty)   // new sensor, new session
        #expect(sensor.lifecycleEvents.suffix(2).map(\.kind) == [.sensorReplaced, .sessionStarted])
        #expect(!sensor.sensorStatus.contains(.sensorMalfunction))
        #expect(sensor.takeMeasurement() != nil)
    }

    // MARK: Temporary issue (TBD-05)

    @Test func temporaryIssueReportsNaNWithFaultBitUntilResolved() throws {
        sensor.startSession()
        sensor.beginTemporaryIssue()
        #expect(sensor.condition == .impaired)
        // Reported at once, not at the next tick.
        #expect(sensor.recordStore.count == 1)
        #expect(sensor.recordStore.last?.sensorStatus.contains(.generalDeviceFault) == true)

        let impaired = try #require(sensor.takeMeasurement())
        #expect(impaired.glucoseConcentration.isNaN)
        #expect(impaired.trend == nil)
        #expect(impaired.quality == 0)
        #expect(impaired.sensorStatus.contains(.generalDeviceFault))
        #expect(sensor.alertStatus == [])   // NaN trips no alert
        #expect(sensor.sensorStatus.contains(.generalDeviceFault))

        sensor.feature.flags.remove(.generalDeviceFault)
        #expect(!sensor.sensorStatus.contains(.generalDeviceFault))
        sensor.feature.flags.insert(.generalDeviceFault)

        sensor.resolveTemporaryIssue()
        #expect(sensor.condition == .healthy)
        #expect(sensor.recordStore.last?.glucoseConcentration == 120)   // the recovery is reported at once too
        let healthy = try #require(sensor.takeMeasurement())
        #expect(healthy.glucoseConcentration == 120)
        #expect(healthy.quality == 100)
        #expect(!healthy.sensorStatus.contains(.generalDeviceFault))
        #expect(sensor.lifecycleEvents.suffix(2).map(\.kind) == [.temporaryIssueBegan, .temporaryIssueResolved])
    }

    // MARK: Sensor range (HYD-G-003)

    @Test func readingsOutsideTheSensorRangeAreClampedAndFlagged() throws {
        sensor.feature.flags.insert(.sensorResultHighLowDetection)
        sensor.startSession()

        sensor.trace = .constant(mgdl: 500)
        let high = try #require(sensor.takeMeasurement())
        #expect(high.glucoseConcentration == 400)
        #expect(high.sensorStatus.contains(.resultHigherThanDeviceCanProcess))
        #expect(sensor.sensorStatus.contains(.resultHigherThanDeviceCanProcess))

        sensor.trace = .constant(mgdl: 20)
        let low = try #require(sensor.takeMeasurement())
        #expect(low.glucoseConcentration == 40)
        #expect(low.sensorStatus.contains(.resultLowerThanDeviceCanProcess))
        #expect(!low.sensorStatus.contains(.resultHigherThanDeviceCanProcess))

        // Status follows a range change at once: widening clears the bit, narrowing below the last
        // (clamped) reading sets it again.
        sensor.sensorRange = 10...600
        #expect(sensor.rangeStatus == [])
        sensor.sensorRange = 50...600
        #expect(sensor.sensorStatus.contains(.resultLowerThanDeviceCanProcess))
        sensor.sensorRange = 10...600
        let inRange = try #require(sensor.takeMeasurement())
        #expect(inRange.glucoseConcentration == 20)
        #expect(sensor.rangeStatus == [])

        // Without the detection feature the raw value goes out and nothing is flagged; switching it off
        // drops a bit already in Status.
        sensor.sensorRange = 40...400
        sensor.trace = .constant(mgdl: 500)
        _ = sensor.takeMeasurement()
        #expect(sensor.sensorStatus.contains(.resultHigherThanDeviceCanProcess))
        sensor.feature.flags.remove(.sensorResultHighLowDetection)
        #expect(sensor.rangeStatus == [])
        sensor.trace = .constant(mgdl: 700)
        let raw = try #require(sensor.takeMeasurement())
        #expect(raw.glucoseConcentration == 700)
        #expect(raw.sensorStatus.isDisjoint(with: [.resultLowerThanDeviceCanProcess, .resultHigherThanDeviceCanProcess]))
    }

    // MARK: Lifecycle record (TBD-07/08)

    @Test func lifecycleEventsRecordSourceAcceptanceAndConnection() throws {
        // Stop with nothing running: rejected, from the collector, no subscriber.
        #expect(try cgmcp(.stopSession) == .opCodeNotSupported)
        var event = try #require(sensor.lifecycleEvents.last)
        #expect(event.kind == .sessionStopped && event.source == .collector && !event.accepted && !event.collectorSubscribed)

        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        #expect(try cgmcp(.startSession) == .success)
        event = try #require(sensor.lifecycleEvents.last)
        #expect(event.kind == .sessionStarted && event.source == .collector && event.accepted && event.collectorSubscribed)

        box.now = startedAt.addingTimeInterval(42 * 60)
        #expect(sensor.stopSession())
        event = try #require(sensor.lifecycleEvents.last)
        #expect(event.kind == .sessionStopped && event.source == .tester && event.timeOffset == 42)
        #expect(sensor.lifecycleEvents.count == 3)
    }

    // MARK: Run time (HYD-G-009)

    @Test func sessionExpiresWhenRunTimeElapses() throws {
        sensor.sessionRunTime = CGMSessionRunTime(hours: 1)
        sensor.startSession()
        box.now = startedAt.addingTimeInterval(59 * 60)
        #expect(sensor.takeMeasurement() != nil)
        box.now = startedAt.addingTimeInterval(60 * 60)
        #expect(sensor.takeMeasurement() == nil)
        #expect(sensor.sessionState == .stopped)
        #expect(sensor.sensorStatus.contains(.sessionStopped))
        // The collector hears about it at once, from Measure Now as from a cadence tick.
        #expect(sensor.lastStatusRecord?.sensorStatus.contains(.sessionStopped) == true)
        let event = try #require(sensor.lifecycleEvents.last)
        #expect(event.kind == .sessionExpired && event.source == .sensor && event.timeOffset == 60)
    }

    /// Real timers: the first reading goes out when the warm-up ends and the cadence counts from there, so a
    /// warm-up on a 5 min cadence reads at 1:00, 6:00, 11:00. With no warm-up it goes out at Start Session.
    @Test @MainActor func cadenceStartsAtWarmupEnd() {
        let server = MockGATTService()
        let queue = MockMessageQueue(gattServer: server)
        let sensor = MockCGMSensor(gattServer: server, messageQueue: queue)
        sensor.trace = .constant(mgdl: 100)
        sensor.measurementInterval = 1
        sensor.warmupDuration = 0.1
        sensor.startSession()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(sensor.measurementCount == 0)   // still warming up
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        #expect(sensor.measurementCount == 1)   // the warm-up-end reading
        let next = sensor.nextMeasurementDate.map { $0.timeIntervalSinceNow } ?? 0
        #expect(next > 0.7 && next <= 1.0, "next reading should be one interval after the warm-up end, got \(next)")

        sensor.warmupDuration = 0
        sensor.startSession()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(sensor.measurementCount == 1)
    }

    @Test func replaceNotifiesTheDelegateOnce() {
        let spy = DelegateSpy()
        sensor.delegate = spy
        sensor.replaceSensor()   // nests a Start Session inside the replacement batch
        #expect(spy.updates == 1)
    }
}
