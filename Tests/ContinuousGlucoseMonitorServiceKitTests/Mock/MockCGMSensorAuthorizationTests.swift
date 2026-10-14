//
//  MockCGMSensorAuthorizationTests.swift
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

@Suite("MockCGMSensor Authorization Control")
struct MockCGMSensorAuthorizationTests {
    let server = MockGATTService()
    let queue: MockMessageQueue
    let sensor: MockCGMSensor

    init() {
        queue = MockMessageQueue(gattServer: server)
        sensor = MockCGMSensor(gattServer: server, messageQueue: queue)
    }

    // MARK: - Layout and gating

    @Test func publishesTheAuthorizationControlService() {
        let acs = server.services.first { $0.uuid == ACCharacteristicUUID.service.cbUUID }
        #expect(acs?.characteristics.map(\.uuid) == [
            ACCharacteristicUUID.status.cbUUID,
            ACCharacteristicUUID.controlPoint.cbUUID,
            ACCharacteristicUUID.dataIn.cbUUID,
            ACCharacteristicUUID.dataOutNotify.cbUUID,
            ACCharacteristicUUID.dataOutIndicate.cbUUID
        ])
        #expect(sensor.isAuthorizationControlEnabled == false)
        #expect(sensor.isSecurityEstablished == false)
        #expect(sensor.securityManager.configuration.oobRandomNumber == Data("42".utf8))
    }

    /// Reads go through the published characteristic. Writes need a real CBCentral at that layer, so the
    /// write gate (same `guardedWrite` helper) is covered by the secure-channel test instead.
    @Test func authorizationToggleGatesTheCGMCharacteristics() {
        let feature = server.characteristic(.feature)!
        #expect(feature.onRead().0 == .success)

        sensor.isAuthorizationControlEnabled = true
        #expect(feature.onRead().0 == .insufficientAuthorization)
        #expect(server.characteristic(.status)?.onRead().0 == .insufficientAuthorization)
        #expect(server.characteristic(.sessionStartTime)?.onRead().0 == .insufficientAuthorization)
        #expect(server.characteristic(.sessionRunTime)?.onRead().0 == .insufficientAuthorization)
        // ACS itself and the unprotected services stay reachable.
        #expect(server.characteristic(ACCharacteristicUUID.status.cbUUID)?.onRead().0 == .success)
        #expect(server.characteristic(BatteryCharacteristicUUID.batteryLevel.cbUUID)?.onRead().0 == .success)

        sensor.isAuthorizationControlEnabled = false
        #expect(feature.onRead().0 == .success)
    }

    /// AC Status carries the active restriction map: 0 while the CGM characteristics are open, 1 when gated,
    /// indicated on each flip so a connected collector knows which path to use.
    @Test func acStatusReflectsTheToggle() throws {
        server.subscribed.insert(ACCharacteristicUUID.status.cbUUID)
        var status = try #require(ACStatusDataHandler.handleData(server.characteristic(ACCharacteristicUUID.status.cbUUID)!.onRead().1))
        #expect(status.currentRestrictionMapID == 0)

        sensor.isAuthorizationControlEnabled = true
        status = try #require(ACStatusDataHandler.handleData(sensor.authorizationStatusCharacteristic.createData()))
        #expect(status.currentRestrictionMapID == 1)
        #expect(queue.items.last?.uuid == ACCharacteristicUUID.status.cbUUID)
        #expect(queue.items.last?.value == sensor.authorizationStatusCharacteristic.createData())

        sensor.isAuthorizationControlEnabled = false
        status = try #require(ACStatusDataHandler.handleData(sensor.authorizationStatusCharacteristic.createData()))
        #expect(status.currentRestrictionMapID == 0)
        #expect(queue.items.count == 2)
    }

    /// With the toggle off, AC Data In refuses protected-resource requests instead of answering on the plain channel.
    @Test func secureRequestsAreRefusedWhileAuthorizationIsOff() throws {
        let collector = Collector()
        establishSecurity(collector)
        queue.emptyQueue()
        let segments = try collector.data.prepareSecureRequestSegments(nil, resourceHandle: CGMResourceHandle.handle(for: .feature)).get()
        for segment in segments {
            #expect(sensor.authorizationDataCharacteristic.onWrite(segment) == .requestNotSupported)
        }
        #expect(queue.items.isEmpty)
    }

    /// The key descriptor reports the fixed IV configured at init without touching configuration.
    @Test func keyDescriptorIsAPureReadOfTheConfiguredIV() {
        let before = sensor.securityManager.configuration
        #expect(before.generatedIVFixedField == MockCGMSensor.fixedIVField)
        let descriptor = sensor.getKeyDescriptor(filter: 0xFFFF)
        #expect(descriptor.suffix(4) == Data(MockCGMSensor.fixedIVField.reversed()))   // little-endian on the wire
        #expect(sensor.securityManager.configuration == before)
    }

    @Test func resourceHandlesRoundTrip() {
        for uuid in CGMCharacteristicUUID.allCases where uuid != .service {
            let handle = CGMResourceHandle.handle(for: uuid)
            #expect(handle != CGMResourceHandle.service)
            #expect(CGMResourceHandle.characteristic(for: handle) == uuid)
        }
        #expect(CGMResourceHandle.characteristic(for: 99) == nil)
        let map = sensor.resourceHandleToUUIDMap()
        #expect(map.count == 1)
        #expect(map[0][CGMCharacteristicUUID.service.cbUUID] == 1)
        #expect(map[0].count == 8)
    }

    @Test func plainMeasurementsStopWhileAuthorizationIsOn() {
        server.subscribed.insert(CGMCharacteristicUUID.measurement.cbUUID)
        sensor.trace = .constant(mgdl: 100)
        sensor.startSession()
        sensor.isAuthorizationControlEnabled = true
        _ = sensor.takeMeasurement()
        // No secure session yet, and the plain characteristic is protected: nothing goes out.
        #expect(queue.items.filter { $0.uuid == CGMCharacteristicUUID.measurement.cbUUID }.isEmpty)
        #expect(queue.items.filter { $0.uuid == ACCharacteristicUUID.dataOutNotify.cbUUID }.isEmpty)
    }

    // MARK: - End-to-end key exchange with the kit's own client handlers

    /// Stand-in collector: BluetoothCommonKit's client-side handlers driven by hand over the mock queue.
    final class Collector: SecurityManagerDelegate {
        var sharedKeyData: Data?
        var securityEstablishedCount = 0
        let securityManager: SecurityManager
        let controlPoint: ACControlPointDataHandler
        let data: ACDataDataHandler

        init(oobRandomNumber: String = "42") {
            securityManager = SecurityManager()
            securityManager.configuration.oobRandomNumber = Data(oobRandomNumber.utf8)
            controlPoint = ACControlPointDataHandler(securityManager: securityManager, maxRequestSize: 19)
            data = ACDataDataHandler(securityManager: securityManager, maxRequestSize: 19)
            securityManager.delegate = self
        }

        func securityManagerDidEstablishedSecurity(_ securityManager: SecurityManager) {
            securityEstablishedCount += 1
        }

        func securityManagerDidUpdateConfiguration(_ securityManager: SecurityManager) { }
    }

    /// Writes one queued client request to the sensor's AC Control Point and feeds every indication the
    /// sensor queues back into the client handler, which may enqueue follow-up requests. Returns the
    /// client-side failures (partial segments excluded) so a test can expect a specific one.
    @discardableResult
    private func exchangeOneRequest(_ collector: Collector) -> [DeviceCommError]? {
        guard let (request, _) = collector.controlPoint.nextRequestToSend() else { return nil }
        collector.controlPoint.procedureRunning = true
        for segment in collector.controlPoint.segmentPayload(request) {
            #expect(sensor.authorizationControlPoint.onWrite(segment) == .success)
        }
        let responses = queue.items.filter { $0.uuid == ACCharacteristicUUID.controlPoint.cbUUID }
        queue.removeItems(for: ACCharacteristicUUID.controlPoint.cbUUID)
        var failures: [DeviceCommError] = []
        for response in responses {
            let (result, _) = collector.controlPoint.handleSegmentedResponse(response.value)
            if case .failure(let error) = result {
                // Intermediate segments are reported as partial until the last one arrives.
                if case .partialResponse = error { continue }
                failures.append(error)
            }
        }
        return failures
    }

    /// Runs the full configuration + key exchange sequence; returns every client-side failure seen.
    @discardableResult
    private func establishSecurity(_ collector: Collector, expectingFailures: Bool = false) -> [DeviceCommError] {
        server.subscribed.formUnion([
            ACCharacteristicUUID.status.cbUUID,
            ACCharacteristicUUID.controlPoint.cbUUID,
            ACCharacteristicUUID.dataOutIndicate.cbUUID,
            ACCharacteristicUUID.dataOutNotify.cbUUID
        ])
        collector.controlPoint.queueConfigurationRequests()
        var failures: [DeviceCommError] = []
        var rounds = 0
        while let roundFailures = exchangeOneRequest(collector), rounds < 40 {
            failures.append(contentsOf: roundFailures)
            rounds += 1
        }
        #expect(collector.controlPoint.nextRequestToSend() == nil, "client still has requests queued after \(rounds) rounds")
        if !expectingFailures {
            #expect(failures.isEmpty, "client rejected a response: \(failures)")
        }
        return failures
    }

    @Test func keyExchangeEstablishesSecurityOnBothSides() {
        let collector = Collector()
        establishSecurity(collector)

        #expect(sensor.isSecurityEstablished)
        #expect(sensor.sharedKeyData != nil)
        #expect(sensor.currentKeyID == sensor.ecdhKeyID)
        #expect(collector.securityManager.applicationSecurityEstablished)
        #expect(collector.securityEstablishedCount == 1)
        #expect(collector.controlPoint.uuidToHandleMap[CGMCharacteristicUUID.feature.cbUUID] == CGMResourceHandle.handle(for: .feature))

        // AC Status reports the established session (flags: controls enabled + security established) and
        // the sensor indicated it the moment the confirmation validated.
        let status = ACStatusDataHandler.handleData(sensor.authorizationStatusCharacteristic.createData())
        #expect(status?.status.rawValue == 0b11)
        #expect(queue.items.contains { $0.uuid == ACCharacteristicUUID.status.cbUUID })
    }

    /// A collector with the wrong OOB number fails the confirmation: the sensor never reports established
    /// and neither side keeps the ECDH secret.
    @Test func mismatchedOOBNumberLeavesTheSensorUnestablished() {
        let collector = Collector(oobRandomNumber: "43")
        let failures = establishSecurity(collector, expectingFailures: true)

        #expect(failures.contains { if case .authenticationFailed = $0 { return true } else { return false } }, "expected authenticationFailed, got \(failures)")
        #expect(!sensor.isSecurityEstablished)
        #expect(sensor.sharedKeyData == nil)
        #expect(sensor.currentKeyID == nil)
        #expect(collector.sharedKeyData == nil)
        #expect(collector.securityEstablishedCount == 0)
        #expect(!queue.items.contains { $0.uuid == ACCharacteristicUUID.status.cbUUID })
    }

    /// Invalidate Key drops the session on both sides and the sensor indicates the status change.
    @Test func invalidateKeyDropsTheSessionOnBothSides() {
        let collector = Collector()
        establishSecurity(collector)
        queue.emptyQueue()

        collector.controlPoint.queueInvalidateKeyRequest()
        let failures = exchangeOneRequest(collector) ?? []
        #expect(failures.isEmpty, "\(failures)")

        #expect(!sensor.isSecurityEstablished)
        #expect(sensor.sharedKeyData == nil)
        #expect(sensor.currentKeyID == nil)
        #expect(collector.sharedKeyData == nil)
        #expect(!collector.securityManager.applicationSecurityEstablished)
        let status = ACStatusDataHandler.handleData(sensor.authorizationStatusCharacteristic.createData())
        #expect(status?.status.rawValue == 0b01)
        #expect(queue.items.contains { $0.uuid == ACCharacteristicUUID.status.cbUUID })
    }

    @Test func protectedReadAndWriteTravelTheSecureChannel() throws {
        let collector = Collector()
        establishSecurity(collector)
        sensor.isAuthorizationControlEnabled = true
        queue.emptyQueue()

        // Read Feature through AC Data In; the answer comes back encrypted on AC Data Out Indicate.
        let featureHandle = CGMResourceHandle.handle(for: .feature)
        let readSegments = try collector.data.prepareSecureRequestSegments(nil, resourceHandle: featureHandle).get()
        for segment in readSegments {
            #expect(sensor.authorizationDataCharacteristic.onWrite(segment) == .success)
        }
        let featureResponse = try #require(decryptIndications(collector))
        #expect(featureResponse.resourceHandle == featureHandle)
        #expect(featureResponse.response == sensor.feature.encoded())

        // Start Session through the control point handle: the Response Code indication is secure too.
        queue.emptyQueue()
        let cgmcpHandle = CGMResourceHandle.handle(for: .specificOpsControlPoint)
        let start = CGMSpecificOpsRequest.encode(.startSession, e2eCRC: false)
        for segment in try collector.data.prepareSecureRequestSegments(start, resourceHandle: cgmcpHandle).get() {
            #expect(sensor.authorizationDataCharacteristic.onWrite(segment) == .success)
        }
        #expect(sensor.sessionState == .running)
        let cgmcpResponse = try #require(decryptIndications(collector))
        #expect(cgmcpResponse.resourceHandle == cgmcpHandle)
        #expect(cgmcpResponse.response == Data([0x1C, 0x1A, 0x01]))

        // A measurement is notified encrypted on AC Data Out Notify, not on the plain characteristic.
        queue.emptyQueue()
        sensor.trace = .constant(mgdl: 123)
        let record = try #require(sensor.takeMeasurement())
        let notifications = queue.items.filter { $0.uuid == ACCharacteristicUUID.dataOutNotify.cbUUID }
        #expect(!notifications.isEmpty)
        #expect(queue.items.allSatisfy { $0.uuid != CGMCharacteristicUUID.measurement.cbUUID })
        var decrypted: ResourceResponse?
        for notification in notifications {
            if case .success(let response) = collector.data.handleSecureResponse(notification.value) {
                decrypted = response
            }
        }
        #expect(decrypted?.resourceHandle == CGMResourceHandle.handle(for: .measurement))
        #expect(decrypted?.response == record.encoded(e2eCRC: false))
    }

    /// Refusals and write errors come back as the ATT response to the AC Data In write, with nothing indicated.
    @Test func secureChannelReportsATTErrorsOnTheWriteResponse() throws {
        let collector = Collector()
        establishSecurity(collector)
        sensor.isAuthorizationControlEnabled = true
        queue.emptyQueue()

        func write(_ request: Data?, to uuid: CGMCharacteristicUUID) throws -> CBATTError.Code {
            var code: CBATTError.Code = .success
            for segment in try collector.data.prepareSecureRequestSegments(request, resourceHandle: CGMResourceHandle.handle(for: uuid)).get() {
                code = sensor.authorizationDataCharacteristic.onWrite(segment)
            }
            return code
        }

        #expect(try write(nil, to: .measurement) == .readNotPermitted)          // notify-only
        #expect(try write(Data([0x01]), to: .feature) == .writeNotPermitted)   // read-only
        #expect(try write(nil, to: .specificOpsControlPoint) == .readNotPermitted)
        #expect(try write(Data([0x01, 0x02]), to: .sessionStartTime) == .invalidAttributeValueLength)
        #expect(queue.items.isEmpty)

        // Unknown handles are refused too.
        let unknown = try collector.data.prepareSecureRequestSegments(nil, resourceHandle: 42).get()
        var code: CBATTError.Code = .success
        for segment in unknown { code = sensor.authorizationDataCharacteristic.onWrite(segment) }
        #expect(code == .attributeNotFound)

        // A valid secure write of Session Start Time succeeds and indicates the stored value.
        sensor.startSession()
        queue.emptyQueue()
        let startTime = CGMSessionStartTime(date: Date(timeIntervalSince1970: 1_790_100_000), timeZoneOffset: 0, dstOffset: .standardTime)
        #expect(try write(startTime.encoded(e2eCRC: false), to: .sessionStartTime) == .success)
        let readBack = try #require(decryptIndications(collector))
        #expect(readBack.response == sensor.readSessionStartTime().1)
        #expect(sensor.sessionStartTimeSetByCollector)
    }

    /// Reassembles and decrypts whatever the sensor queued on AC Data Out Indicate.
    private func decryptIndications(_ collector: Collector) -> ResourceResponse? {
        var decrypted: ResourceResponse?
        for item in queue.items where item.uuid == ACCharacteristicUUID.dataOutIndicate.cbUUID {
            switch collector.data.handleSecureResponse(item.value) {
            case .success(let response):
                decrypted = response
            case .failure(let error):
                // Intermediate segments report an incomplete payload; anything else is a real failure.
                if case .invalidFormat = error {
                    Issue.record("secure response rejected: \(error)")
                }
            }
        }
        return decrypted
    }
}
