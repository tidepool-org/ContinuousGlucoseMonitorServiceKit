//
//  MockCGMSensorResponseOverrideTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-11-11.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import CoreBluetooth
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

/// The tester's answer to collector commands: the real one, a refusal, a failure, or silence either way.
@Suite("MockCGMSensor command response override")
struct MockCGMSensorResponseOverrideTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor

    init() {
        queue = MockMessageQueue(gattServer: server)
        sensor = MockCGMSensor(gattServer: server, messageQueue: queue, now: { Date() })
    }

    private var setInterval: Data { CGMSpecificOpsRequest.setCommunicationInterval(minutes: 10, e2eCRC: false) }

    private var cgmcpIndications: [Data] {
        queue.items.filter { $0.uuid == CGMCharacteristicUUID.specificOpsControlPoint.cbUUID }.map(\.value)
    }

    @Test func normalLeavesTheCommandAlone() throws {
        #expect(try cgmcpSend(setInterval, to: sensor, queue: queue) == .responseCode(request: 0x01, code: CGMSpecificOpsResponseCode.success.rawValue))
        #expect(sensor.measurementInterval == 600)
    }

    @Test func refuseAnswersOpCodeNotSupportedWithoutExecuting() throws {
        sensor.commandResponseOverride = .refuse
        #expect(try cgmcpSend(setInterval, to: sensor, queue: queue) == .responseCode(request: 0x01, code: CGMSpecificOpsResponseCode.opCodeNotSupported.rawValue))
        #expect(sensor.measurementInterval == 300)
    }

    @Test func failAnswersProcedureNotCompletedWithoutExecuting() throws {
        sensor.commandResponseOverride = .fail
        #expect(try cgmcpSend(setInterval, to: sensor, queue: queue) == .responseCode(request: 0x01, code: CGMSpecificOpsResponseCode.procedureNotCompleted.rawValue))
        #expect(sensor.measurementInterval == 300)
    }

    @Test func uncertainExecutedRunsTheCommandAndWithholdsTheAnswer() {
        sensor.commandResponseOverride = .uncertainExecuted
        #expect(sensor.writeSpecificOpsControlPoint(setInterval) == .success)   // the write itself is accepted
        #expect(cgmcpIndications.isEmpty)
        #expect(sensor.measurementInterval == 600)
    }

    @Test func uncertainNotExecutedDropsTheCommandSilently() {
        sensor.commandResponseOverride = .uncertainNotExecuted
        #expect(sensor.writeSpecificOpsControlPoint(setInterval) == .success)
        #expect(cgmcpIndications.isEmpty)
        #expect(sensor.measurementInterval == 300)
    }

    /// A refused Start Session leaves the sensor as it was; the collector sees the refusal.
    @Test func refuseAppliesToSessionCommands() throws {
        sensor.commandResponseOverride = .refuse
        #expect(try cgmcpSend(cgmcpRequest(.startSession), to: sensor, queue: queue) == .responseCode(request: CGMSpecificOpsOpcode.startSession.rawValue, code: CGMSpecificOpsResponseCode.opCodeNotSupported.rawValue))
        #expect(sensor.sessionState != .running)
    }

    /// The override is about commands; a query under Refuse still gets its real answer.
    @Test func queriesAreAnsweredUnderAnyOverride() throws {
        sensor.commandResponseOverride = .refuse
        #expect(try cgmcpSend(cgmcpRequest(.getCommunicationInterval), to: sensor, queue: queue) == .communicationInterval(minutes: 5))
    }

    @Test func changingTheOverrideReachesTheDelegateOnce() {
        let spy = DelegateSpy()
        sensor.delegate = spy
        sensor.commandResponseOverride = .fail
        sensor.commandResponseOverride = .fail
        #expect(spy.updates == 1)
    }
}
