//
//  SensorTestHelpers.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-15.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

/// A clock the test advances by hand; the sensor reads it through its `now` closure.
final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Counts delegate updates and runs an optional probe on each one.
final class DelegateSpy: MockCGMSensorDelegate {
    private(set) var updates = 0
    private let onUpdate: () -> Void

    init(onUpdate: @escaping () -> Void = {}) { self.onUpdate = onUpdate }

    func mockSensorDidUpdate(_ sensor: MockCGMSensor) {
        updates += 1
        onUpdate()
    }
}

/// A CGMCP request without CRC.
func cgmcpRequest(_ opcode: CGMSpecificOpsOpcode, operand: Data = Data()) -> Data {
    CGMSpecificOpsRequest.encode(opcode, operand: operand, e2eCRC: false)
}

/// Writes `request` to the sensor's CGMCP and returns the decoded indication it queued.
func cgmcpSend(
    _ request: Data,
    to sensor: MockCGMSensor,
    queue: MockMessageQueue,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> CGMSpecificOpsResponse {
    let before = queue.items.count
    #expect(sensor.writeSpecificOpsControlPoint(request) == .success, sourceLocation: sourceLocation)
    let item = try #require(queue.items.last, sourceLocation: sourceLocation)
    #expect(queue.items.count == before + 1, sourceLocation: sourceLocation)
    #expect(item.uuid == CGMCharacteristicUUID.specificOpsControlPoint.cbUUID, sourceLocation: sourceLocation)
    return try CGMSpecificOpsResponse(data: item.value, e2eCRC: false)
}
