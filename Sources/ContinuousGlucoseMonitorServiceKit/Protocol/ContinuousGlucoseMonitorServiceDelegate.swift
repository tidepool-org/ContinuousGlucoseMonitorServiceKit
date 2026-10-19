//
//  ContinuousGlucoseMonitorServiceDelegate.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-16.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Collector-side contracts, mirroring `IDPumpDelegate` / `IDPumpComms` in the pump kit so a Loop CGM
//  plugin and the simulator's test client are built on the same surface.

import Foundation
import CoreBluetooth
import BluetoothCommonKit

// MARK: - Procedure completions

public typealias CGMSpecificOpsCompletion = ProcedureCompletion<CGMSpecificOpsResponse>
public typealias CGMRACPCompletion = ProcedureCompletion<CGMRACPResponse>

// MARK: - Sensor delegate

/// Asynchronous events from the sensor. Called on BluetoothCommonKit's queues, never the main thread.
///
/// Do not call `disconnect()`, `forgetSensor()` or `prepareForDeactivation()` synchronously from inside
/// these callbacks. They reach `BluetoothManager`, which asserts it is not running on its own central
/// manager queue, and the connection callbacks are delivered on exactly that queue; the assertion traps.
/// Hop to your own queue (or the main queue) first, as the pump kit's hosts do.
public protocol CGMSensorDelegate: AnyObject {
    /// A sensor advertising CGMS was seen while scanning and is not the one the service reconnects to.
    func sensor(_ sensor: CGMSensorComms, didDiscoverSensorWithName name: String?, identifier: UUID, advertisementData: [String: Any], signalStrength: NSNumber)
    /// Connected or disconnected; read `isConnected`.
    func sensorConnectionStatusChanged(_ sensor: CGMSensorComms)
    /// Connected, Feature and Session Start Time read, and the secure session established when required.
    func sensorIsReady(_ sensor: CGMSensorComms)
    /// The ACS key exchange finished, or the secure session was lost (`error` set).
    func sensorDidCompleteAuthentication(_ sensor: CGMSensorComms, error: DeviceCommError?)
    /// Every CGM Measurement notification, periodic or from an RACP report; one notification may carry
    /// several records.
    func sensor(_ sensor: CGMSensorComms, didReceiveMeasurements records: [CGMMeasurementRecord])
    /// Feature read after connecting, on request, or indicated by the sensor when a tester flips a bit.
    func sensor(_ sensor: CGMSensorComms, didUpdateFeature feature: CGMFeature)
    /// Every decoded CGMCP indication, including the one that completes a pending request.
    func sensor(_ sensor: CGMSensorComms, didReceiveSpecificOpsResponse response: CGMSpecificOpsResponse)
    /// Every decoded RACP indication, including the one that completes a pending request.
    func sensor(_ sensor: CGMSensorComms, didReceiveRACPResponse response: CGMRACPResponse)
    /// A value that could not be decoded or a characteristic error outside any pending request.
    func sensor(_ sensor: CGMSensorComms, didEncounterError error: DeviceCommError, forCharacteristic uuid: CBUUID?)
    /// `state` changed; persist it.
    func sensorDidUpdateState(_ sensor: CGMSensorComms)
}

public extension CGMSensorDelegate {
    func sensorIsReady(_ sensor: CGMSensorComms) { }
    func sensor(_ sensor: CGMSensorComms, didUpdateFeature feature: CGMFeature) { }
    func sensor(_ sensor: CGMSensorComms, didReceiveSpecificOpsResponse response: CGMSpecificOpsResponse) { }
    func sensor(_ sensor: CGMSensorComms, didReceiveRACPResponse response: CGMRACPResponse) { }
    func sensor(_ sensor: CGMSensorComms, didEncounterError error: DeviceCommError, forCharacteristic uuid: CBUUID?) { }
    func sensorDidUpdateState(_ sensor: CGMSensorComms) { }
}

// MARK: - Sensor communication

/// What a collector can ask of a CGM sensor. Completions run on BluetoothCommonKit's queues.
public protocol CGMSensorComms: AnyObject {
    var delegate: CGMSensorDelegate? { get set }
    var loggingDelegate: DeviceCommLoggingDelegate? { get set }

    var state: CGMSensorState { get set }
    /// The sensor's CGM Feature, read once per sensor and kept in `state`; nil until the first read.
    var feature: CGMFeature? { get }
    /// Whether requests carry an E2E-CRC, from `feature`.
    var isE2EProtectionSupported: Bool { get }
    /// Last Session Start Time read on this connection; the base for a calibration's Calibration Time.
    var sessionStartTime: CGMSessionStartTime? { get }
    var isConnected: Bool { get }
    /// True when no ACS is required or the key exchange has completed.
    var isAuthenticated: Bool { get }
    var isSecurityEstablished: Bool { get }
    /// Route CGMS reads and writes through AC Data In/Out. Set when a key exchange succeeds; a tester can
    /// clear it to watch the sensor refuse plain access.
    var usesSecureChannel: Bool { get set }

    // MARK: Connection
    // `disconnect()`, `forgetSensor()` and `prepareForDeactivation()` must not be called from a
    // `CGMSensorDelegate` callback; see the note on that protocol.
    func setOOBString(_ oobString: String)
    /// Drops any connection and scans; discoveries arrive through the delegate.
    func scanForSensors()
    func connectToSensor(withIdentifier identifier: UUID)
    /// Cancels the link; BluetoothCommonKit reconnects to the remembered sensor when it reappears.
    func disconnect()
    /// Cancels the link and forgets the sensor, so nothing reconnects until a new one is chosen.
    func forgetSensor()
    func prepareForDeactivation()

    // MARK: Characteristics
    func getFeature(completion: @escaping ProcedureCompletion<CGMFeature>)
    func getStatus(completion: @escaping ProcedureCompletion<CGMStatus>)
    func getSessionStartTime(completion: @escaping ProcedureCompletion<CGMSessionStartTime>)
    func getSessionRunTime(completion: @escaping ProcedureCompletion<CGMSessionRunTime>)
    /// CGMS §3.4.1: write the collector's time; the sensor derives the session start from it.
    func setSessionStartTime(_ date: Date, timeZone: TimeZone, completion: @escaping ProcedureResultCompletion)
    func getBatteryLevel(completion: @escaping ProcedureCompletion<Int>)
    func getDeviceInformation(_ characteristic: DeviceInfoCharacteristicUUID, completion: @escaping ProcedureCompletion<String>)
    /// Notifications are enabled during configuration; this is for tests that need them off.
    func setNotifications(_ characteristic: CGMCharacteristicUUID, enabled: Bool, completion: @escaping ProcedureResultCompletion)
    func isNotifying(_ characteristic: CGMCharacteristicUUID) -> Bool

    // MARK: Control points
    /// Any CGMCP procedure; the E2E-CRC is appended when the Feature calls for it. A Response Code other than
    /// Success completes with the matching `DeviceCommError`.
    func sendSpecificOpsRequest(_ opcode: CGMSpecificOpsOpcode, operand: Data, completion: @escaping CGMSpecificOpsCompletion)
    /// Any RACP procedure. Report Stored Records completes with the closing Response Code; the records
    /// themselves arrive through `sensor(_:didReceiveMeasurements:)`.
    func sendRACPRequest(_ request: CGMRACPRequest, completion: @escaping CGMRACPCompletion)

    // MARK: Authorization Control
    func establishSecureSession(completion: @escaping ProcedureResultCompletion)
    func invalidateKey(completion: @escaping ProcedureResultCompletion)
}

public extension CGMSensorComms {
    // MARK: CGMCP conveniences (CGMS Table 3.6)

    func startSession(completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(.startSession, operand: Data(), completion: completion)
    }

    func stopSession(completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(.stopSession, operand: Data(), completion: completion)
    }

    func getCommunicationInterval(completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(.getCommunicationInterval, operand: Data(), completion: completion)
    }

    /// Minutes; 0 disables periodic communication, 0xFF asks for the fastest the sensor supports (§3.7.2.1).
    func setCommunicationInterval(minutes: UInt8, completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(.setCommunicationInterval, operand: Data([minutes]), completion: completion)
    }

    func getGlucoseCalibrationValue(recordNumber: UInt16 = CGMCalibrationRecord.lastRecordNumber, completion: @escaping CGMSpecificOpsCompletion) {
        var operand = Data()
        operand.append(recordNumber)
        sendSpecificOpsRequest(.getGlucoseCalibrationValue, operand: operand, completion: completion)
    }

    func setGlucoseCalibrationValue(_ record: CGMCalibrationRecord, completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(.setGlucoseCalibrationValue, operand: record.encoded(), completion: completion)
    }

    /// Any Get …Alert Level op code.
    func getAlertLevel(_ opcode: CGMSpecificOpsOpcode, completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(opcode, operand: Data(), completion: completion)
    }

    /// Any Set …Alert Level op code; `value` is mg/dL or mg/dL/min per the op code.
    func setAlertLevel(_ opcode: CGMSpecificOpsOpcode, value: Double, completion: @escaping CGMSpecificOpsCompletion) {
        var operand = Data()
        operand.appendSFloat(value)
        sendSpecificOpsRequest(opcode, operand: operand, completion: completion)
    }

    func resetDeviceSpecificAlert(completion: @escaping CGMSpecificOpsCompletion) {
        sendSpecificOpsRequest(.resetDeviceSpecificAlert, operand: Data(), completion: completion)
    }

    // MARK: RACP conveniences (CGMS §3.6)

    func reportNumberOfStoredRecords(_ racpOperator: CGMRACPOperator = .allRecords, minimum: UInt16 = 0, maximum: UInt16 = 0, completion: @escaping CGMRACPCompletion) {
        sendRACPRequest(CGMRACPRequest(opcode: .reportNumberOfStoredRecords, racpOperator: racpOperator, minimum: minimum, maximum: maximum), completion: completion)
    }

    func reportStoredRecords(_ racpOperator: CGMRACPOperator = .allRecords, minimum: UInt16 = 0, maximum: UInt16 = 0, completion: @escaping CGMRACPCompletion) {
        sendRACPRequest(CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: racpOperator, minimum: minimum, maximum: maximum), completion: completion)
    }

    /// HYD-G-015: everything after the last Time Offset seen, or all records when nothing was seen yet.
    func reportStoredRecords(after lastTimeOffset: UInt16?, completion: @escaping CGMRACPCompletion) {
        if let lastTimeOffset, lastTimeOffset < UInt16.max {
            reportStoredRecords(.greaterThanOrEqualTo, minimum: lastTimeOffset + 1, completion: completion)
        } else {
            reportStoredRecords(.allRecords, completion: completion)
        }
    }

    func deleteStoredRecords(_ racpOperator: CGMRACPOperator = .allRecords, minimum: UInt16 = 0, maximum: UInt16 = 0, completion: @escaping CGMRACPCompletion) {
        sendRACPRequest(CGMRACPRequest(opcode: .deleteStoredRecords, racpOperator: racpOperator, minimum: minimum, maximum: maximum), completion: completion)
    }

    func abortRACPOperation(completion: @escaping CGMRACPCompletion) {
        sendRACPRequest(.abort, completion: completion)
    }
}

// MARK: - Response code mapping

public extension CGMSpecificOpsResponseCode {
    /// nil for Success; otherwise the `DeviceCommError` a completion reports.
    var deviceCommError: DeviceCommError? {
        switch self {
        case .success: return nil
        case .opCodeNotSupported: return .opcodeNotSupported
        case .invalidOperand: return .invalidOperand
        case .procedureNotCompleted: return .procedureNotCompleted
        case .parameterOutOfRange: return .parameterOutOfRange
        }
    }
}

public extension CGMRACPResponseCode {
    /// nil for Success; otherwise the `DeviceCommError` a completion reports.
    var deviceCommError: DeviceCommError? {
        switch self {
        case .success: return nil
        case .opCodeNotSupported: return .opcodeNotSupported
        case .invalidOperator, .operatorNotSupported, .operandNotSupported: return .invalidOperand
        case .invalidOperand: return .invalidOperand
        case .noRecordsFound: return .noRecordsFound
        case .abortUnsuccessful, .procedureNotCompleted: return .procedureNotCompleted
        }
    }
}
