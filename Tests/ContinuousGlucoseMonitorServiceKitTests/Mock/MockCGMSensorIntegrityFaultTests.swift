//
//  MockCGMSensorIntegrityFaultTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-16.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import CoreBluetooth
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

@Suite("MockCGMSensor integrity fault")
struct MockCGMSensorIntegrityFaultTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor

    init() {
        queue = MockMessageQueue(gattServer: server)
        sensor = MockCGMSensor(gattServer: server, messageQueue: queue)
        sensor.feature.flags.insert(.e2eCRC)
        sensor.trace = .constant(mgdl: 120)
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        sensor.startSession()
    }

    private var measurementValues: [Data] {
        queue.items.filter { $0.uuid == CGMCharacteristicUUID.measurement.cbUUID }.map(\.value)
    }

    /// The fault hits exactly one notification; the next one is clean and the arm is cleared.
    @Test(arguments: CGMIntegrityFault.allCases)
    func faultCorruptsTheNextMeasurementOnly(fault: CGMIntegrityFault) throws {
        let clean = try #require(sensor.takeMeasurement()).encoded(e2eCRC: true)
        sensor.pendingIntegrityFault = fault
        _ = sensor.takeMeasurement()
        _ = sensor.takeMeasurement()
        let values = measurementValues
        #expect(values.count == 3)
        #expect(values[0] == clean)
        #expect(values[2].count == clean.count && values[2].isCRCValid)

        let bad = values[1]
        switch fault {
        case .omitCRC:
            #expect(bad.count == clean.count - CGME2ECRC.size)
            #expect(bad == clean.dropLast(CGME2ECRC.size))
        case .corruptCRC:
            #expect(bad.count == clean.count)
            #expect(!bad.isCRCValid)
            #expect(bad.dropLast(CGME2ECRC.size) == clean.dropLast(CGME2ECRC.size))   // payload untouched
        case .truncate:
            #expect(bad.count == clean.count - CGME2ECRC.size - 1)
        }
        #expect(throws: (any Error).self) { try CGMMeasurementRecord.decodeRecords(bad, e2eCRC: true) }

        #expect(sensor.pendingIntegrityFault == nil)
        let injected = try #require(sensor.lastInjectedFault)
        #expect(injected.fault == fault && injected.characteristic == .measurement && injected.applied)
    }

    /// Indications and read responses are payloads too.
    @Test func faultAppliesToIndicationsAndReads() throws {
        sensor.pendingIntegrityFault = .corruptCRC
        let (code, status) = sensor.readStatus()
        #expect(code == .success)
        #expect(!status.isCRCValid)
        #expect(sensor.lastInjectedFault?.characteristic == .status)
        #expect(sensor.readStatus().1.isCRCValid)   // consumed

        sensor.pendingIntegrityFault = .omitCRC
        _ = sensor.writeSpecificOpsControlPoint(CGMSpecificOpsRequest.encode(.getCommunicationInterval, e2eCRC: true))
        let indication = try #require(queue.items.last { $0.uuid == CGMCharacteristicUUID.specificOpsControlPoint.cbUUID })
        #expect(indication.value.count == 2)   // Communication Interval response op code + interval, no CRC
        #expect(throws: (any Error).self) { try CGMSpecificOpsResponse(data: indication.value, e2eCRC: true) }
        #expect(sensor.lastInjectedFault?.characteristic == .specificOpsControlPoint)
    }

    /// Without E2E-CRC there is no trailer to omit or corrupt: the payload goes out intact and the tester is
    /// told so. Truncation still works, since it is about length rather than the CRC.
    @Test func crcFaultsAreNoOpsWithoutE2E() throws {
        sensor.feature.flags.remove(.e2eCRC)
        let clean = try #require(sensor.takeMeasurement()).encoded(e2eCRC: false)

        sensor.pendingIntegrityFault = .corruptCRC
        _ = sensor.takeMeasurement()
        #expect(measurementValues.last == clean)
        #expect(sensor.pendingIntegrityFault == nil)
        #expect(sensor.lastInjectedFault?.applied == false)

        sensor.pendingIntegrityFault = .truncate
        _ = sensor.takeMeasurement()
        #expect(measurementValues.last?.count == clean.count - 1)
        #expect(sensor.lastInjectedFault?.applied == true)
    }

    /// RACP has no CRC in CGMS, so a CRC fault waits for a payload that carries one.
    @Test func crcFaultSkipsRACPAndWaitsForACRCBearingPayload() throws {
        sensor.pendingIntegrityFault = .omitCRC
        _ = sensor.writeRecordAccessControlPoint(Data([0x04, 0x01]))   // Report Number of Stored Records, all
        let racp = try #require(queue.items.last { $0.uuid == CGMCharacteristicUUID.recordAccessControlPoint.cbUUID })
        #expect(racp.value.count == 4)   // intact
        #expect(sensor.pendingIntegrityFault == .omitCRC)

        _ = sensor.takeMeasurement()
        #expect(sensor.pendingIntegrityFault == nil)
        #expect(sensor.lastInjectedFault?.characteristic == .measurement)
    }
}
