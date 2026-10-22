//
//  ContinuousGlucoseMonitorServiceTests.swift
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

/// The collector service without a radio: values are pushed in through the BluetoothManager delegate path,
/// the way BluetoothCommonKit delivers them, and the decoding, caching, delegate fan-out and error mapping
/// are checked. Requests that need a peripheral are covered by the two-device hardware pass.
@Suite("ContinuousGlucoseMonitorService")
struct ContinuousGlucoseMonitorServiceTests {
    final class DelegateSpy: CGMSensorDelegate {
        var measurements: [[CGMMeasurementRecord]] = []
        var features: [CGMFeature] = []
        var specificOpsResponses: [CGMSpecificOpsResponse] = []
        var racpResponses: [CGMRACPResponse] = []
        var errors: [(DeviceCommError, CBUUID?)] = []
        var connectionChanges = 0
        var readyReports = 0
        var stateUpdates = 0
        var authentications: [DeviceCommError?] = []
        var securityUpdates = 0

        func sensor(_ sensor: CGMSensorComms, didDiscoverSensorWithName name: String?, identifier: UUID, advertisementData: [String: Any], signalStrength: NSNumber) { }
        func sensorConnectionStatusChanged(_ sensor: CGMSensorComms) { connectionChanges += 1 }
        func sensorIsReady(_ sensor: CGMSensorComms) { readyReports += 1 }
        func sensorDidCompleteAuthentication(_ sensor: CGMSensorComms, error: DeviceCommError?) { authentications.append(error) }
        func sensorDidUpdateSecurity(_ sensor: CGMSensorComms) { securityUpdates += 1 }
        func sensor(_ sensor: CGMSensorComms, didReceiveMeasurements records: [CGMMeasurementRecord]) { measurements.append(records) }
        func sensor(_ sensor: CGMSensorComms, didUpdateFeature feature: CGMFeature) { features.append(feature) }
        func sensor(_ sensor: CGMSensorComms, didReceiveSpecificOpsResponse response: CGMSpecificOpsResponse) { specificOpsResponses.append(response) }
        func sensor(_ sensor: CGMSensorComms, didReceiveRACPResponse response: CGMRACPResponse) { racpResponses.append(response) }
        func sensor(_ sensor: CGMSensorComms, didEncounterError error: DeviceCommError, forCharacteristic uuid: CBUUID?) { errors.append((error, uuid)) }
        func sensorDidUpdateState(_ sensor: CGMSensorComms) { stateUpdates += 1 }
    }

    let bluetoothManager: BluetoothManager
    let peripheralManager = PeripheralManager()
    let securityManager = SecurityManager()
    let service: ContinuousGlucoseMonitorService
    let spy = DelegateSpy()

    init() {
        bluetoothManager = BluetoothManager(peripheralConfiguration: .continuousGlucoseMonitorServiceConfiguration, servicesToDiscover: [CGMCharacteristicUUID.service.cbUUID], restoreOptions: nil)
        bluetoothManager.peripheralManager = peripheralManager
        service = ContinuousGlucoseMonitorService(
            bluetoothManager: bluetoothManager,
            securityManager: securityManager,
            acControlPoint: ACControlPointDataHandler(securityManager: securityManager, maxRequestSize: 19),
            acData: ACDataDataHandler(securityManager: securityManager, maxRequestSize: 19),
            state: CGMSensorState(),
            isConnectedHandler: { true }
        )
        service.delegate = spy
    }

    private func receive(_ data: Data, on characteristic: CGMCharacteristicUUID) {
        service.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, didReceiveValue: data, fromCharactistic: characteristic.cbUUID)
    }

    /// AC Status as the sensor encodes it: flags octet (bit 0 controls enabled, bit 1 security established),
    /// then the current restriction map ID (UInt16 little endian; 0 = resources open).
    private func receiveACStatus(restrictionMapID: UInt16, established: Bool) {
        var value = Data([established ? 0x03 : 0x01])
        value.append(contentsOf: [UInt8(restrictionMapID & 0xFF), UInt8(restrictionMapID >> 8)])
        service.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, didReceiveValue: value, fromCharactistic: ACCharacteristicUUID.status.cbUUID)
    }

    // MARK: Response timeouts

    /// Completions handed to the service, collected from whichever queue answers them.
    final class ResultBox {
        var results: [DeviceCommResult<Data>] = []
    }

    /// A request whose answer never comes fails with Procedure Timeout and frees its characteristic, so the
    /// next request is not refused as in progress. This is the safety net for refusals BluetoothCommonKit's
    /// AC Data In send swallows.
    @Test func unansweredRequestTimesOutAndFreesTheCharacteristic() async throws {
        service.responseTimeout = 0.1
        let key = ContinuousGlucoseMonitorService.PendingKey(CGMCharacteristicUUID.specificOpsControlPoint.cbUUID)
        let box = ResultBox()
        #expect(service.setPending(key) { box.results.append($0) })
        #expect(!service.setPending(key) { _ in })   // busy until answered or timed out

        try await Task.sleep(for: .milliseconds(400))
        #expect(box.results == [.failure(.procedureTimeout)])
        #expect(service.takePending(key) == nil)
        #expect(service.setPending(key) { _ in })    // free again
        _ = service.takePending(key)
    }

    /// The answer disarms the timer: one completion, never a late timeout on top.
    @Test func answeredRequestDoesNotTimeOutLater() async throws {
        service.responseTimeout = 0.1
        let key = ContinuousGlucoseMonitorService.PendingKey(CGMCharacteristicUUID.specificOpsControlPoint.cbUUID)
        let box = ResultBox()
        #expect(service.setPending(key) { box.results.append($0) })
        receive(CGMSpecificOpsResponse.communicationInterval(minutes: 5).encoded(e2eCRC: false), on: .specificOpsControlPoint)
        #expect(box.results.count == 1)

        try await Task.sleep(for: .milliseconds(400))
        #expect(box.results.count == 1)
    }

    /// A Report Stored Records transfer can outlast any fixed wait, so each record restarts the RACP clock;
    /// the request only times out once the records stop without a Response Code.
    @Test func racpReportStaysPendingWhileRecordsArrive() async throws {
        service.responseTimeout = 0.3
        let box = ResultBox()
        #expect(service.setPending(.racp(.reportStoredRecords)) { box.results.append($0) })
        let record = CGMMeasurementRecord(glucoseConcentration: 100, timeOffset: 1, sensorStatus: [], trend: nil, quality: nil)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(150))
            receive(record.encoded(e2eCRC: false), on: .measurement)
        }
        #expect(box.results.isEmpty)   // 750 ms in, still waiting thanks to the records

        try await Task.sleep(for: .milliseconds(600))
        #expect(box.results == [.failure(.procedureTimeout)])
    }

    // MARK: RACP answer matching

    private func racpResponseCode(_ request: CGMRACPOpcode, _ code: CGMRACPResponseCode) -> Data {
        CGMRACPResponse.responseCode(request: request.rawValue, code: code.rawValue).encoded()
    }

    /// Abort Operation exists to cancel a running procedure, so it is the one request the RACP accepts while
    /// busy. Its Success also ends the aborted request, which the sensor sends no Response Code for.
    @Test func abortJoinsARunningReportAndEndsItOnSuccess() throws {
        let report = ResultBox()
        let abort = ResultBox()
        #expect(service.setPending(.racp(.reportStoredRecords)) { report.results.append($0) })
        #expect(!service.setPending(.racp(.reportNumberOfStoredRecords)) { _ in })   // one procedure at a time
        #expect(service.setPending(.racp(.abortOperation)) { abort.results.append($0) })

        let abortSuccess = racpResponseCode(.abortOperation, .success)
        receive(abortSuccess, on: .recordAccessControlPoint)
        #expect(abort.results == [.success(abortSuccess)])
        #expect(report.results == [.failure(.procedureNotCompleted)])
        #expect(service.setPending(.racp(.reportNumberOfStoredRecords)) { _ in })   // the RACP is free again
        _ = service.takePending(.racp(.reportNumberOfStoredRecords))
    }

    /// Each RACP indication completes the request whose op code it names, so an Abort that failed leaves the
    /// report waiting for its own closing Response Code.
    @Test func racpAnswersCompleteTheRequestTheyName() throws {
        let report = ResultBox()
        let abort = ResultBox()
        #expect(service.setPending(.racp(.reportStoredRecords)) { report.results.append($0) })
        #expect(service.setPending(.racp(.abortOperation)) { abort.results.append($0) })

        receive(racpResponseCode(.abortOperation, .abortUnsuccessful), on: .recordAccessControlPoint)
        #expect(abort.results.count == 1)
        #expect(report.results.isEmpty)

        let reportDone = racpResponseCode(.reportStoredRecords, .success)
        receive(reportDone, on: .recordAccessControlPoint)
        #expect(report.results == [.success(reportDone)])

        // Number of Stored Records has no op code field; it answers Report Number of Stored Records.
        let count = ResultBox()
        #expect(service.setPending(.racp(.reportNumberOfStoredRecords)) { count.results.append($0) })
        let countValue = CGMRACPResponse.numberOfStoredRecords(7).encoded()
        receive(countValue, on: .recordAccessControlPoint)
        #expect(count.results == [.success(countValue)])
        #expect(spy.racpResponses.count == 3)
    }

    // MARK: Connection setup

    /// Ready means every setup step succeeded. Without a peripheral the Feature read fails, so the connection is
    /// reported but readiness is not, and the host hears why.
    @Test func readyIsNotReportedWhenASetupStepFails() throws {
        service.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, isReadyWithError: nil)
        #expect(spy.connectionChanges == 1)
        #expect(spy.readyReports == 0)
        let setupError = try #require(spy.errors.last)
        guard case .commandFailed = setupError.0 else {
            Issue.record("expected the failed Feature read as the setup error, got \(setupError.0)")
            return
        }
        #expect(setupError.1 == nil)
    }

    /// BluetoothCommonKit only queues the ECDH steps while its `willExchangeParentKey` flag is set, and it
    /// clears the flag after the first exchange. The key does not survive a link loss, so the next link's
    /// exchange has to be a full one again rather than a nonce re-sync that leaves the collector without a key.
    @Test func linkLossArmsAFullKeyExchangeForTheNextLink() throws {
        service.acControlPoint.willExchangeParentKey = false   // as the handler leaves it after one exchange
        service.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, isReadyWithError: CBError(.peripheralDisconnected))
        #expect(service.acControlPoint.willExchangeParentKey)
    }

    // MARK: Secure channel policy

    /// AC Data In answers Request Not Supported while the restriction map ID is 0, so holding a key is not
    /// enough: the channel follows protection, and follows it live when the sensor flips the toggle.
    @Test func secureChannelFollowsProtectionAndTheKey() {
        // Key, but the sensor serves CGMS plainly: stay plain.
        service.sharedKeyData = Data([1, 2, 3])
        receiveACStatus(restrictionMapID: 0, established: true)
        #expect(service.isSecurityEstablished)
        #expect(!service.areResourcesProtected)
        #expect(!service.usesSecureChannel)
        #expect(!service.state.isAuthorizationControlRequired)
        #expect(spy.securityUpdates == 0)

        // The tester turns Required on: the sensor indicates AC Status and the channel switches.
        receiveACStatus(restrictionMapID: 1, established: true)
        #expect(service.areResourcesProtected)
        #expect(service.usesSecureChannel)
        #expect(service.state.isAuthorizationControlRequired)
        #expect(spy.securityUpdates == 1)

        // Required off again: back to plain, reported once.
        receiveACStatus(restrictionMapID: 0, established: true)
        #expect(!service.usesSecureChannel)
        #expect(spy.securityUpdates == 2)

        // Protected but no key on this side: plain (and refused by the sensor) until an exchange completes.
        service.sharedKeyData = nil
        receiveACStatus(restrictionMapID: 1, established: false)
        #expect(service.areResourcesProtected)
        #expect(!service.usesSecureChannel)
        #expect(service.state.isAuthorizationControlRequired)
        #expect(spy.securityUpdates == 2)
    }

    // MARK: Configuration

    /// The characteristic lists are BluetoothCommonKit-internal; what can be checked here is that the ACS
    /// flag changes the configuration and the default includes ACS (the mock sensor always publishes it).
    @Test func configurationDiffersWithAndWithoutACS() {
        let full = PeripheralManager.Configuration.continuousGlucoseMonitorServiceConfiguration
        let plain = PeripheralManager.Configuration.continuousGlucoseMonitorServiceConfiguration(includingAuthorizationControl: false)
        #expect(full == .continuousGlucoseMonitorServiceConfiguration(includingAuthorizationControl: true))
        #expect(full != plain)
    }

    // MARK: Inbound values

    /// Feature first: it decides whether everything after it carries a CRC.
    @Test func featureIsCachedAndDrivesE2EDecoding() throws {
        #expect(!service.isE2EProtectionSupported)
        var feature = CGMFeature.simulatorDefault
        feature.flags.insert(.e2eCRC)
        receive(feature.encoded(), on: .feature)
        #expect(service.feature == feature)
        #expect(service.isE2EProtectionSupported)
        #expect(service.state.featureFlags == feature.flags)
        #expect(spy.features == [feature])
        #expect(spy.stateUpdates >= 1)

        // With E2E on, a measurement without its CRC is an error, not a reading.
        let record = CGMMeasurementRecord(glucoseConcentration: 120, timeOffset: 3, sensorStatus: [], trend: nil, quality: nil)
        receive(record.encoded(e2eCRC: false), on: .measurement)
        #expect(spy.measurements.isEmpty)
        #expect(spy.errors.last?.0 == .invalidCRC)
        #expect(spy.errors.last?.1 == CGMCharacteristicUUID.measurement.cbUUID)

        receive(record.encoded(e2eCRC: true), on: .measurement)
        #expect(spy.measurements.count == 1)
        #expect(spy.measurements.first?.first == record)
    }

    @Test func notificationCarryingSeveralRecordsIsDeliveredWhole() throws {
        let records = (0..<3).map { CGMMeasurementRecord(glucoseConcentration: 100 + Double($0), timeOffset: UInt16($0), sensorStatus: [], trend: nil, quality: nil) }
        let value = records.reduce(into: Data()) { $0.append($1.encoded(e2eCRC: false)) }
        receive(value, on: .measurement)
        #expect(spy.measurements == [records])
    }

    @Test func sessionStartTimeIsCached() throws {
        let startTime = CGMSessionStartTime(date: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
        receive(startTime.encoded(e2eCRC: false), on: .sessionStartTime)
        #expect(service.sessionStartTime == startTime)
    }

    /// Control point indications reach the delegate whether or not a request is waiting.
    @Test func unsolicitedIndicationsReachTheDelegate() throws {
        receive(CGMSpecificOpsResponse.communicationInterval(minutes: 5).encoded(e2eCRC: false), on: .specificOpsControlPoint)
        #expect(spy.specificOpsResponses == [.communicationInterval(minutes: 5)])
        receive(CGMRACPResponse.numberOfStoredRecords(42).encoded(), on: .recordAccessControlPoint)
        #expect(spy.racpResponses == [.numberOfStoredRecords(42)])
    }

    // MARK: Error mapping

    @Test func errorsMapToDeviceCommErrors() {
        #expect(ContinuousGlucoseMonitorService.commError(from: CGMCodecError.invalidCRC) == .invalidCRC)
        #expect(ContinuousGlucoseMonitorService.commError(from: CGMCodecError.missingCRC) == .invalidCRC)
        #expect(ContinuousGlucoseMonitorService.commError(from: CGMCodecError.truncated(expected: 4, actual: 2)) == .invalidFormat)
        #expect(ContinuousGlucoseMonitorService.commError(from: PeripheralManagerError.timeout) == .procedureTimeout)
        #expect(ContinuousGlucoseMonitorService.commError(from: PeripheralManagerError.notReady) == .deviceNotReady)

        func att(_ code: Int) -> CBATTError { CBATTError(CBATTError.Code(rawValue: code)!) }
        #expect(ContinuousGlucoseMonitorService.commError(from: att(0x80)) == .invalidCRC)
        #expect(ContinuousGlucoseMonitorService.commError(from: att(0x81)) == .invalidCRC)
        #expect(ContinuousGlucoseMonitorService.commError(from: att(0xFE)) == .procedureInProgress)
        #expect(ContinuousGlucoseMonitorService.commError(from: att(0xFF)) == .parameterOutOfRange)
        #expect(ContinuousGlucoseMonitorService.commError(from: PeripheralManagerError.cbPeripheralError(att(0xFE))) == .procedureInProgress)
        #expect(ContinuousGlucoseMonitorService.commError(from: CBATTError(.insufficientAuthorization)) == .authenticationFailed)
        if case .commandFailed = ContinuousGlucoseMonitorService.commError(from: att(0xFD)) { } else {
            Issue.record("CCCD Improperly Configured should surface as a command failure with its name")
        }
    }

    @Test func responseCodesMapToDeviceCommErrors() {
        #expect(CGMSpecificOpsResponseCode.success.deviceCommError == nil)
        #expect(CGMSpecificOpsResponseCode.opCodeNotSupported.deviceCommError == .opcodeNotSupported)
        #expect(CGMSpecificOpsResponseCode.parameterOutOfRange.deviceCommError == .parameterOutOfRange)
        #expect(CGMSpecificOpsResponseCode.procedureNotCompleted.deviceCommError == .procedureNotCompleted)
        #expect(CGMRACPResponseCode.success.deviceCommError == nil)
        #expect(CGMRACPResponseCode.noRecordsFound.deviceCommError == .noRecordsFound)
        #expect(CGMRACPResponseCode.abortUnsuccessful.deviceCommError == .procedureNotCompleted)
    }

    // MARK: Link loss

    @Test func linkLossClearsTheConnectionCaches() throws {
        receive(CGMFeature.simulatorDefault.encoded(), on: .feature)
        receive(CGMSessionStartTime(date: Date(), timeZone: .current).encoded(e2eCRC: false), on: .sessionStartTime)
        service.usesSecureChannel = true
        #expect(service.feature != nil && service.sessionStartTime != nil)

        service.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, isReadyWithError: CBError(.peripheralDisconnected))
        #expect(service.feature == CGMFeature.simulatorDefault)   // the Feature belongs to the sensor, not the link
        #expect(service.sessionStartTime == nil)
        #expect(!service.usesSecureChannel)
        #expect(spy.authentications == [.disconnected])   // the secure channel was up, so its loss is reported

        // BluetoothCommonKit can deliver one disconnect through two paths; the delegate hears it once.
        service.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, didEncounterError: CBError(.peripheralDisconnected))
        #expect(spy.connectionChanges == 1)
    }

    /// The Feature is read once per sensor and restored with the state, so after a relaunch the very first
    /// measurement is decoded with the right CRC handling and no Feature read is needed.
    @Test func persistedFeatureDecidesE2EFromTheFirstValue() throws {
        var knownFeature = CGMFeature.simulatorDefault
        knownFeature.flags.insert(.e2eCRC)
        let remembered = ContinuousGlucoseMonitorService(
            bluetoothManager: bluetoothManager,
            securityManager: securityManager,
            acControlPoint: ACControlPointDataHandler(securityManager: securityManager, maxRequestSize: 19),
            acData: ACDataDataHandler(securityManager: securityManager, maxRequestSize: 19),
            state: CGMSensorState(feature: knownFeature),
            isConnectedHandler: { true }
        )
        let rememberedSpy = DelegateSpy()
        remembered.delegate = rememberedSpy
        #expect(remembered.feature == knownFeature)
        #expect(remembered.isE2EProtectionSupported)

        let record = CGMMeasurementRecord(glucoseConcentration: 110, timeOffset: 1, sensorStatus: [], trend: nil, quality: nil)
        remembered.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, didReceiveValue: record.encoded(e2eCRC: true), fromCharactistic: CGMCharacteristicUUID.measurement.cbUUID)
        #expect(rememberedSpy.measurements.first?.first == record)

        // A Feature claiming E2E off (CRC field 0xFFFF) cannot switch the check off; it is reported as a CRC
        // failure and the remembered flag stands, so the host forgets a sensor whose Feature really changed.
        remembered.bluetoothManager(bluetoothManager, peripheralManager: peripheralManager, didReceiveValue: CGMFeature.simulatorDefault.encoded(), fromCharactistic: CGMCharacteristicUUID.feature.cbUUID)
        #expect(remembered.isE2EProtectionSupported)
        #expect(remembered.feature == knownFeature)
        #expect(rememberedSpy.errors.last?.0 == .invalidCRC)
        #expect(rememberedSpy.errors.last?.1 == CGMCharacteristicUUID.feature.cbUUID)
    }

    // MARK: Requests without a peripheral

    @Test func requestsWithoutACharacteristicFailCleanly() async {
        let feature = await withCheckedContinuation { continuation in
            service.getFeature { continuation.resume(returning: $0) }
        }
        guard case .failure(let error) = feature, case .commandFailed = error else {
            Issue.record("expected a command failure naming the missing characteristic, got \(feature)")
            return
        }

        let secure = await withCheckedContinuation { continuation in
            service.usesSecureChannel = true
            service.getStatus { continuation.resume(returning: $0) }
        }
        guard case .failure(.deviceNotReady) = secure else {
            Issue.record("a secure read with no resource handle should report deviceNotReady, got \(secure)")
            return
        }
    }

    // MARK: State

    @Test func stateRoundTripsThroughItsRawValue() throws {
        var state = CGMSensorState(identifier: UUID(), name: "sensor", feature: CGMFeature(flags: [.calibration, .e2eCRC]), isAuthorizationControlRequired: true,
                                   uuidToHandleMap: [CGMCharacteristicUUID.measurement.cbUUID: 7], lastCommsDate: Date(timeIntervalSince1970: 1_790_000_000))
        state.securityManagerConfiguration.oobRandomNumber = Data("42".utf8)
        let restored = try #require(CGMSensorState(rawValue: state.rawValue))
        #expect(restored == state)
        #expect(restored.uuidToHandleMap[CGMCharacteristicUUID.measurement.cbUUID] == 7)
        #expect(restored.securityManagerConfiguration.oobRandomNumber == Data("42".utf8))
    }
}
