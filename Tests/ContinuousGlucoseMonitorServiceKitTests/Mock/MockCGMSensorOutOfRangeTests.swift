//
//  MockCGMSensorOutOfRangeTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-11-12.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

/// A tester can make the sensor report a value its range would normally clamp.
@Suite("MockCGMSensor out-of-range reading")
struct MockCGMSensorOutOfRangeTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor

    init() {
        queue = MockMessageQueue(gattServer: server)
        sensor = MockCGMSensor(gattServer: server, messageQueue: queue, now: { Date() })
        sensor.feature.flags.insert(.sensorResultHighLowDetection)
        sensor.sensorRange = 40...400
        sensor.startSession()
    }

    @Test func reportedValueBypassesTheClampAndTheRangeBits() throws {
        let record = try #require(sensor.reportReading(glucose: 700))
        #expect(record.glucoseConcentration == 700)
        #expect(!record.sensorStatus.contains(.resultHigherThanDeviceCanProcess))
        #expect(sensor.lastMeasurement?.glucoseConcentration == 700)
    }

    @Test func negativeAndZeroValuesGoOutAsGiven() throws {
        #expect(try #require(sensor.reportReading(glucose: -5)).glucoseConcentration == -5)
        #expect(try #require(sensor.reportReading(glucose: 0)).glucoseConcentration == 0)
    }

    @Test func theOverrideIsConsumedByOneReading() throws {
        _ = try #require(sensor.reportReading(glucose: 900))
        sensor.trace = .constant(mgdl: 1000)
        let next = try #require(sensor.takeMeasurement())
        #expect(next.glucoseConcentration == 400, "the clamp is back for the next reading")
        #expect(next.sensorStatus.contains(.resultHigherThanDeviceCanProcess))
        #expect(sensor.pendingGlucoseOverride == nil)
    }

    /// A stale reading claims an earlier Time Offset than the moment it is taken; the next reading is current again.
    @Test func staleReadingIsDatedBackAndClampsAtSessionStart() throws {
        let clock = ClockBox(Date())
        let sensor = MockCGMSensor(gattServer: server, messageQueue: queue, now: { clock.now })
        sensor.startSession()
        clock.now = clock.now.addingTimeInterval(30 * 60)   // thirty minutes into the session
        #expect(sensor.timeOffset == 30)

        let stale = try #require(sensor.reportReading(glucose: 120, minutesOld: 10))
        #expect(stale.timeOffset == 20)
        #expect(sensor.pendingStaleMinutes == nil)

        let clamped = try #require(sensor.reportReading(glucose: 120, minutesOld: 10_000))
        #expect(clamped.timeOffset == 0, "never before the session start")

        let fresh = try #require(sensor.takeMeasurement())
        #expect(fresh.timeOffset == sensor.timeOffset)
    }

    @Test func nothingIsSentWithoutASessionAndTheOverrideIsDropped() {
        sensor.stopSession()
        #expect(sensor.reportReading(glucose: 700) == nil)
        #expect(sensor.pendingGlucoseOverride == nil)
    }
}
