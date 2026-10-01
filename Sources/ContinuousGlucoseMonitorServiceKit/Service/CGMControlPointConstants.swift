//
//  CGMControlPointConstants.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Op codes, operators and response codes for the Record Access Control Point (CGMS §3.6, values from the
//  Glucose Service RACP in the GSS) and the CGM Specific Ops Control Point (CGMS §3.7, values from the GSS).
//  Request/response codecs land with the RACP and CGMCP phases. VERIFY numeric values against the current GSS.

import Foundation

// MARK: - Record Access Control Point

public enum CGMRACPOpcode: UInt8, Codable, CaseIterable, Sendable {
    case reportStoredRecords = 0x01
    case deleteStoredRecords = 0x02
    case abortOperation = 0x03
    case reportNumberOfStoredRecords = 0x04
    case numberOfStoredRecordsResponse = 0x05
    case responseCode = 0x06
}

public enum CGMRACPOperator: UInt8, Codable, CaseIterable, Sendable {
    case null = 0x00
    case allRecords = 0x01
    case lessThanOrEqualTo = 0x02
    case greaterThanOrEqualTo = 0x03
    case withinRangeOf = 0x04
    case firstRecord = 0x05
    case lastRecord = 0x06

    public var includesFilter: Bool {
        switch self {
        case .lessThanOrEqualTo, .greaterThanOrEqualTo, .withinRangeOf: return true
        case .null, .allRecords, .firstRecord, .lastRecord: return false
        }
    }
}

/// CGMS Table 3.5. Only Time Offset is allowed; User Facing Time yields Operand Not Supported (CGMS §3.6.3.1).
public enum CGMRACPFilterType: UInt8, Codable, CaseIterable, Sendable {
    case timeOffset = 0x01
    case userFacingTime = 0x02
}

public enum CGMRACPResponseCode: UInt8, Codable, CaseIterable, Sendable {
    case success = 0x01
    case opCodeNotSupported = 0x02
    case invalidOperator = 0x03
    case operatorNotSupported = 0x04
    case invalidOperand = 0x05
    case noRecordsFound = 0x06
    case abortUnsuccessful = 0x07
    case procedureNotCompleted = 0x08
    case operandNotSupported = 0x09
}

// MARK: - CGM Specific Ops Control Point

public enum CGMSpecificOpsOpcode: UInt8, Codable, CaseIterable, Sendable {
    case setCommunicationInterval = 0x01
    case getCommunicationInterval = 0x02
    case communicationIntervalResponse = 0x03
    case setGlucoseCalibrationValue = 0x04
    case getGlucoseCalibrationValue = 0x05
    case glucoseCalibrationValueResponse = 0x06
    case setPatientHighAlertLevel = 0x07
    case getPatientHighAlertLevel = 0x08
    case patientHighAlertLevelResponse = 0x09
    case setPatientLowAlertLevel = 0x0A
    case getPatientLowAlertLevel = 0x0B
    case patientLowAlertLevelResponse = 0x0C
    case setHypoAlertLevel = 0x0D
    case getHypoAlertLevel = 0x0E
    case hypoAlertLevelResponse = 0x0F
    case setHyperAlertLevel = 0x10
    case getHyperAlertLevel = 0x11
    case hyperAlertLevelResponse = 0x12
    case setRateOfDecreaseAlertLevel = 0x13
    case getRateOfDecreaseAlertLevel = 0x14
    case rateOfDecreaseAlertLevelResponse = 0x15
    case setRateOfIncreaseAlertLevel = 0x16
    case getRateOfIncreaseAlertLevel = 0x17
    case rateOfIncreaseAlertLevelResponse = 0x18
    case resetDeviceSpecificAlert = 0x19
    case startSession = 0x1A
    case stopSession = 0x1B
    case responseCode = 0x1C
}

public enum CGMSpecificOpsResponseCode: UInt8, Codable, CaseIterable, Sendable {
    case success = 0x01
    case opCodeNotSupported = 0x02
    case invalidOperand = 0x03
    case procedureNotCompleted = 0x04
    case parameterOutOfRange = 0x05
}

/// Communication Interval operand semantics (CGMS §3.7.2.1).
public enum CGMCommunicationInterval {
    public static let periodicDisabled: UInt8 = 0x00
    public static let fastestSupported: UInt8 = 0xFF
}

/// Calibration Status field of the Calibration Data Record (CGMS Table 3.7).
public struct CGMCalibrationStatus: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let dataRejected = CGMCalibrationStatus(rawValue: 1 << 0)
    public static let dataOutOfRange = CGMCalibrationStatus(rawValue: 1 << 1)
    public static let processPending = CGMCalibrationStatus(rawValue: 1 << 2)
}
