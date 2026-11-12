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

    @Test func nothingIsSentWithoutASessionAndTheOverrideIsDropped() {
        sensor.stopSession()
        #expect(sensor.reportReading(glucose: 700) == nil)
        #expect(sensor.pendingGlucoseOverride == nil)
    }
}
