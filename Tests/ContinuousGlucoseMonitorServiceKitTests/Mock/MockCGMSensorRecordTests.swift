//
//  MockCGMSensorRecordTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-13.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import CoreBluetooth
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

// MARK: - Record store

@Suite("CGM record store")
struct CGMRecordStoreTests {
    private func record(_ offset: UInt16, _ mgdl: Double = 100) -> CGMMeasurementRecord {
        CGMMeasurementRecord(glucoseConcentration: mgdl, timeOffset: offset)
    }

    @Test func keepsTheNewestRecordsWhenFull() {
        var store = CGMRecordStore(capacity: 3)
        for offset in 0..<5 { store.append(record(UInt16(offset))) }
        #expect(store.records.map(\.timeOffset) == [2, 3, 4])

        store.capacity = 2
        #expect(store.records.map(\.timeOffset) == [3, 4])
        store.capacity = 0   // clamped to 1
        #expect(store.capacity == 1)
        #expect(store.records.map(\.timeOffset) == [4])
    }

    @Test func selectsByOperatorAndTimeOffset() {
        var store = CGMRecordStore()
        for offset in [0, 5, 10, 15, 20] { store.append(record(UInt16(offset))) }
        #expect(store.select(.allRecords).map(\.timeOffset) == [0, 5, 10, 15, 20])
        #expect(store.select(.lessThanOrEqualTo, maximum: 10).map(\.timeOffset) == [0, 5, 10])
        #expect(store.select(.greaterThanOrEqualTo, minimum: 11).map(\.timeOffset) == [15, 20])
        #expect(store.select(.withinRangeOf, minimum: 5, maximum: 15).map(\.timeOffset) == [5, 10, 15])
        #expect(store.select(.firstRecord).map(\.timeOffset) == [0])
        #expect(store.select(.lastRecord).map(\.timeOffset) == [20])
        #expect(store.select(.null).isEmpty)
        #expect(CGMRecordStore().select(.lastRecord).isEmpty)
    }

    @Test func deletesTheSelectionAndReportsTheCount() {
        var store = CGMRecordStore()
        for offset in [0, 5, 5, 10] { store.append(record(UInt16(offset))) }   // 5 s interval: offsets repeat
        #expect(store.delete(.withinRangeOf, minimum: 5, maximum: 5) == 2)
        #expect(store.records.map(\.timeOffset) == [0, 10])
        #expect(store.delete(.greaterThanOrEqualTo, minimum: 50) == 0)
        #expect(store.delete(.allRecords) == 2)
        #expect(store.isEmpty)
    }
}

// MARK: - RACP request decoding

@Suite("RACP request decoding")
struct CGMRACPRequestDecodingTests {
    @Test func decodesEveryOperatorShape() throws {
        #expect(try CGMRACPRequest(data: Data([0x04, 0x01])) == CGMRACPRequest(opcode: .reportNumberOfStoredRecords, racpOperator: .allRecords))
        #expect(try CGMRACPRequest(data: Data([0x01, 0x02, 0x01, 0x1E, 0x00])) == CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .lessThanOrEqualTo, maximum: 30))
        #expect(try CGMRACPRequest(data: Data([0x01, 0x03, 0x01, 0x05, 0x00])) == CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .greaterThanOrEqualTo, minimum: 5))
        #expect(try CGMRACPRequest(data: Data([0x02, 0x04, 0x01, 0x05, 0x00, 0x0A, 0x00])) == CGMRACPRequest(opcode: .deleteStoredRecords, racpOperator: .withinRangeOf, minimum: 5, maximum: 10))
        #expect(try CGMRACPRequest(data: Data([0x01, 0x06])) == CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .lastRecord))
        #expect(try CGMRACPRequest(data: Data([0x03, 0x00])) == .abort)
        // Round trip through the encoder.
        let request = CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .withinRangeOf, minimum: 1, maximum: 2)
        #expect(try CGMRACPRequest(data: request.encoded()) == request)
    }

    @Test func refusesMalformedRequestsWithTheRightReason() {
        #expect(throws: CGMRACPRequestError.opCodeNotSupported(0x05)) { try CGMRACPRequest(data: Data([0x05, 0x01])) }
        #expect(throws: CGMRACPRequestError.invalidOperator(0x07)) { try CGMRACPRequest(data: Data([0x01, 0x07])) }
        #expect(throws: CGMRACPRequestError.invalidOperator(0x00)) { try CGMRACPRequest(data: Data([0x01, 0x00])) }   // Null outside Abort
        #expect(throws: CGMRACPRequestError.invalidOperator(0x01)) { try CGMRACPRequest(data: Data([0x03, 0x01])) }   // Abort needs Null
        #expect(throws: CGMRACPRequestError.operandNotSupported(0x02)) { try CGMRACPRequest(data: Data([0x01, 0x03, 0x02, 0x05, 0x00])) }   // User Facing Time
        #expect(throws: CGMRACPRequestError.invalidOperand) { try CGMRACPRequest(data: Data([0x01, 0x03, 0x01, 0x05])) }   // short
        #expect(throws: CGMRACPRequestError.invalidOperand) { try CGMRACPRequest(data: Data([0x01, 0x01, 0xFF])) }   // trailing octet
        #expect(throws: CGMRACPRequestError.invalidOperand) { try CGMRACPRequest(data: Data([0x01, 0x04, 0x01, 0x0A, 0x00, 0x05, 0x00])) }   // min > max
        #expect(throws: CGMRACPRequestError.invalidOperand) { try CGMRACPRequest(data: Data([0x01])) }
    }
}

// MARK: - Sensor RACP procedures

@Suite("MockCGMSensor records and RACP")
struct MockCGMSensorRecordTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor
    let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private let box: ClockBox

    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    init() {
        queue = MockMessageQueue(gattServer: server)
        let box = ClockBox(startedAt)
        sensor = MockCGMSensor(gattServer: server, messageQueue: queue, now: { box.now })
        self.box = box
        sensor.trace = .constant(mgdl: 100)
    }

    /// Takes `count` measurements one minute apart with nobody subscribed, i.e. while the collector is away.
    private func accumulate(_ count: Int) {
        sensor.startSession()
        for minute in 0..<count {
            box.now = startedAt.addingTimeInterval(TimeInterval(minute) * 60)
            _ = sensor.takeMeasurement()
        }
        queue.emptyQueue()
    }

    private func racp(_ bytes: [UInt8]) -> CBATTError.Code {
        sensor.writeRecordAccessControlPoint(Data(bytes))
    }

    private var racpResponses: [Data] {
        queue.items.filter { $0.uuid == CGMCharacteristicUUID.recordAccessControlPoint.cbUUID }.map(\.value)
    }

    private var notifiedRecords: [CGMMeasurementRecord] {
        queue.items
            .filter { $0.uuid == CGMCharacteristicUUID.measurement.cbUUID }
            .flatMap { (try? CGMMeasurementRecord.decodeRecords($0.value, e2eCRC: false)) ?? [] }
    }

    @Test func measurementsAccumulateWhileDisconnectedAndANewSessionClearsThem() {
        accumulate(5)
        #expect(sensor.recordStore.count == 5)
        #expect(sensor.recordStore.records.map(\.timeOffset) == [0, 1, 2, 3, 4])

        sensor.startSession()
        #expect(sensor.recordStore.isEmpty)
    }

    @Test func reportNumberOfStoredRecordsHonoursTheFilter() {
        accumulate(5)
        #expect(racp([0x04, 0x01]) == .success)                           // all
        #expect(racpResponses.last == Data([0x05, 0x00, 0x05, 0x00]))
        #expect(racp([0x04, 0x03, 0x01, 0x03, 0x00]) == .success)         // >= 3
        #expect(racpResponses.last == Data([0x05, 0x00, 0x02, 0x00]))
        #expect(racp([0x04, 0x03, 0x01, 0x63, 0x00]) == .success)         // >= 99: none
        #expect(racpResponses.last == Data([0x05, 0x00, 0x00, 0x00]))
    }

    /// Backfill (HYD-G-015): the collector asks for everything after the last offset it saw.
    @Test func reportStoredRecordsNotifiesTheSelectionThenIndicatesSuccess() throws {
        accumulate(5)
        server.subscribed.formUnion([CGMCharacteristicUUID.measurement.cbUUID, CGMCharacteristicUUID.recordAccessControlPoint.cbUUID])

        #expect(racp([0x01, 0x03, 0x01, 0x02, 0x00]) == .success)         // >= 2
        #expect(notifiedRecords.map(\.timeOffset) == [2, 3, 4])
        #expect(racpResponses == [Data([0x06, 0x00, 0x01, 0x01])])
        // Records before the response, in order.
        #expect(queue.items.last?.uuid == CGMCharacteristicUUID.recordAccessControlPoint.cbUUID)
        // Copy semantics: the database is untouched.
        #expect(sensor.recordStore.count == 5)
    }

    @Test func reportStoredRecordsPacksSeveralRecordsPerNotification() throws {
        accumulate(5)
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        sensor.recordsPerNotification = 2

        #expect(racp([0x01, 0x01]) == .success)
        let notifications = queue.items.filter { $0.uuid == CGMCharacteristicUUID.measurement.cbUUID }
        #expect(notifications.count == 3)                                  // 2 + 2 + 1
        #expect(try CGMMeasurementRecord.decodeRecords(notifications[0].value, e2eCRC: false).map(\.timeOffset) == [0, 1])
        #expect(try CGMMeasurementRecord.decodeRecords(notifications[2].value, e2eCRC: false).map(\.timeOffset) == [4])
        #expect(notifiedRecords.count == 5)
    }

    @Test func reportStoredRecordsWithNoMatchAnswersNoRecordsFound() {
        accumulate(2)
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        #expect(racp([0x01, 0x03, 0x01, 0x10, 0x00]) == .success)
        #expect(notifiedRecords.isEmpty)
        #expect(racpResponses == [Data([0x06, 0x00, 0x01, 0x06])])
    }

    @Test func reportStoredRecordsNeedsTheMeasurementNotificationConfigured() {
        accumulate(2)
        #expect(racp([0x01, 0x01]) == .improperlyConfigured)
        #expect(queue.items.isEmpty)
        // Counting does not need notifications.
        #expect(racp([0x04, 0x01]) == .success)
    }

    @Test func onlyOneReportRunsAtATimeAndAbortClearsIt() {
        accumulate(3)
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        #expect(racp([0x01, 0x01]) == .success)
        // The queue still holds the transfer, so a second procedure is refused at the ATT layer.
        #expect(racp([0x04, 0x01]) == .procedureAlreadyInProgress)
        #expect(racp([0x01, 0x06]) == .procedureAlreadyInProgress)

        // Abort always gets through, drops the pending transfer and answers Success.
        #expect(racp([0x03, 0x00]) == .success)
        #expect(queue.items.count == 1)
        #expect(racpResponses == [Data([0x06, 0x00, 0x03, 0x01])])

        // A later request works again once the queue has drained.
        queue.emptyQueue()
        #expect(racp([0x04, 0x01]) == .success)
        #expect(racpResponses.last == Data([0x05, 0x00, 0x03, 0x00]))
    }

    @Test func deleteStoredRecordsRemovesTheSelection() {
        accumulate(5)
        #expect(racp([0x02, 0x02, 0x01, 0x01, 0x00]) == .success)         // <= 1
        #expect(racpResponses.last == Data([0x06, 0x00, 0x02, 0x01]))
        #expect(sensor.recordStore.records.map(\.timeOffset) == [2, 3, 4])
        #expect(racp([0x02, 0x02, 0x01, 0x01, 0x00]) == .success)         // nothing left there
        #expect(racpResponses.last == Data([0x06, 0x00, 0x02, 0x06]))
        #expect(racp([0x02, 0x01]) == .success)
        #expect(sensor.recordStore.isEmpty)
    }

    @Test func malformedRequestsAnswerWithResponseCodes() {
        accumulate(1)
        #expect(racp([0x07, 0x01]) == .success)                            // unknown op code
        #expect(racpResponses.last == Data([0x06, 0x00, 0x07, 0x02]))
        #expect(racp([0x01, 0x09]) == .success)                            // invalid operator
        #expect(racpResponses.last == Data([0x06, 0x00, 0x01, 0x03]))
        #expect(racp([0x04, 0x03, 0x02, 0x00, 0x00]) == .success)          // User Facing Time filter
        #expect(racpResponses.last == Data([0x06, 0x00, 0x04, 0x09]))
        #expect(racp([0x04, 0x03, 0x01, 0x00]) == .success)                // truncated operand
        #expect(racpResponses.last == Data([0x06, 0x00, 0x04, 0x05]))
        #expect(racp([]) == .invalidPdu)
    }

    @Test func capacityDropsTheOldestRecords() {
        sensor.recordStore.capacity = 3
        accumulate(5)
        #expect(sensor.recordStore.records.map(\.timeOffset) == [2, 3, 4])
    }

    /// Backfill pretends time passed: the session anchor moves back, records fill the gap from the glucose
    /// source, nothing is notified, and live measurements continue after them.
    @Test func backfillFillsTheGapWithoutNotifying() throws {
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        sensor.trace = .scenario(CGMGlucoseScenario(name: "ramp", values: [100, 110, 120, 130, 140, 150]))
        sensor.measurementInterval = 300
        sensor.startSession()
        _ = sensor.takeMeasurement()                 // offset 0, value 100
        queue.emptyQueue()
        let startBefore = try #require(sensor.sessionStartTime).date

        #expect(sensor.backfill(duration: 20 * 60) == 4)   // 20 min at 5 min
        #expect(queue.items.isEmpty)                        // nobody was told
        #expect(sensor.timeOffset == 20)
        #expect(sensor.recordStore.records.map(\.timeOffset) == [0, 5, 10, 15, 20])
        #expect(sensor.recordStore.records.map(\.glucoseConcentration) == [100, 110, 120, 130, 140])
        #expect(sensor.lastMeasurement?.timeOffset == 20)
        #expect(sensor.measurementCount == 5)
        // Session Start Time moved back with the anchor so offsets still map to the same instants.
        #expect(sensor.sessionStartTime?.date == startBefore.addingTimeInterval(-20 * 60))

        // The next live measurement continues the timeline and the scenario.
        box.now = startedAt.addingTimeInterval(5 * 60)      // real clock: 5 min after the session began
        let live = try #require(sensor.takeMeasurement())
        #expect(live.timeOffset == 25)
        #expect(live.glucoseConcentration == 150)
        #expect(!queue.items.isEmpty)
    }

    @Test func backfillNeedsARunningSessionAndAPositiveDuration() {
        #expect(sensor.backfill(duration: 600) == 0)        // not started
        sensor.startSession()
        #expect(sensor.backfill(duration: 0) == 0)
        #expect(sensor.backfill(duration: 10) == 0)          // shorter than one interval
        #expect(sensor.recordStore.isEmpty)
    }
}
