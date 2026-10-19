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
        var stateUpdates = 0
        var authentications: [DeviceCommError?] = []

        func sensor(_ sensor: CGMSensorComms, didDiscoverSensorWithName name: String?, identifier: UUID, advertisementData: [String: Any], signalStrength: NSNumber) { }
        func sensorConnectionStatusChanged(_ sensor: CGMSensorComms) { connectionChanges += 1 }
        func sensorDidCompleteAuthentication(_ sensor: CGMSensorComms, error: DeviceCommError?) { authentications.append(error) }
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
