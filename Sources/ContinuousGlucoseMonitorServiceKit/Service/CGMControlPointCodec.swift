//
//  CGMControlPointCodec.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-09.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Request and response codecs for the Record Access Control Point (CGMS §3.6) and the CGM Specific Ops
//  Control Point (CGMS §3.7, Table 3.6 operands, Table 3.7 calibration record). Shared by the collector that
//  builds requests and the sensor that answers them.

import Foundation
import BluetoothCommonKit

// MARK: - CGMCP operands

/// What a CGMCP request op code carries after the op code (CGMS Table 3.6).
public enum CGMSpecificOpsOperand: Equatable, Sendable {
    case none
    /// UINT8 minutes; 0x00 disables periodic communication, 0xFF asks for the fastest supported.
    case communicationIntervalMinutes
    /// Table 3.7 record; Record Number and Status are ignored by the server on a Set.
    case calibrationRecord
    /// UINT16 Calibration Data Record Number; 0xFFFF returns the last record stored.
    case calibrationRecordNumber
    /// SFLOAT in mg/dL.
    case glucoseLevel
    /// SFLOAT in mg/dL/min.
    case rateLevel

    /// Octets the operand occupies on the wire.
    public var encodedSize: Int {
        switch self {
        case .none: return 0
        case .communicationIntervalMinutes: return 1
        case .calibrationRecord: return CGMCalibrationRecord.encodedSize
        case .calibrationRecordNumber, .glucoseLevel, .rateLevel: return 2
        }
    }
}

extension CGMSpecificOpsOpcode {
    /// Operand a request op code carries; nil for response op codes, which a client never writes.
    public var requestOperand: CGMSpecificOpsOperand? {
        switch self {
        case .setCommunicationInterval: return .communicationIntervalMinutes
        case .setGlucoseCalibrationValue: return .calibrationRecord
        case .getGlucoseCalibrationValue: return .calibrationRecordNumber
        case .setPatientHighAlertLevel, .setPatientLowAlertLevel, .setHypoAlertLevel, .setHyperAlertLevel: return .glucoseLevel
        case .setRateOfDecreaseAlertLevel, .setRateOfIncreaseAlertLevel: return .rateLevel
        case .getCommunicationInterval, .getPatientHighAlertLevel, .getPatientLowAlertLevel, .getHypoAlertLevel,
             .getHyperAlertLevel, .getRateOfDecreaseAlertLevel, .getRateOfIncreaseAlertLevel,
             .resetDeviceSpecificAlert, .startSession, .stopSession:
            return CGMSpecificOpsOperand.none
        case .communicationIntervalResponse, .glucoseCalibrationValueResponse, .patientHighAlertLevelResponse,
             .patientLowAlertLevelResponse, .hypoAlertLevelResponse, .hyperAlertLevelResponse,
             .rateOfDecreaseAlertLevelResponse, .rateOfIncreaseAlertLevelResponse, .responseCode:
            return nil
        }
    }

    public var isRequest: Bool { requestOperand != nil }

    /// Request op codes in spec order, for pickers.
    public static let requests: [CGMSpecificOpsOpcode] = allCases.filter(\.isRequest)

    public var name: String {
        switch self {
        case .setCommunicationInterval: return "Set Communication Interval"
        case .getCommunicationInterval: return "Get Communication Interval"
        case .communicationIntervalResponse: return "Communication Interval Response"
        case .setGlucoseCalibrationValue: return "Set Glucose Calibration Value"
        case .getGlucoseCalibrationValue: return "Get Glucose Calibration Value"
        case .glucoseCalibrationValueResponse: return "Glucose Calibration Value Response"
        case .setPatientHighAlertLevel: return "Set Patient High Alert Level"
        case .getPatientHighAlertLevel: return "Get Patient High Alert Level"
        case .patientHighAlertLevelResponse: return "Patient High Alert Level Response"
        case .setPatientLowAlertLevel: return "Set Patient Low Alert Level"
        case .getPatientLowAlertLevel: return "Get Patient Low Alert Level"
        case .patientLowAlertLevelResponse: return "Patient Low Alert Level Response"
        case .setHypoAlertLevel: return "Set Hypo Alert Level"
        case .getHypoAlertLevel: return "Get Hypo Alert Level"
        case .hypoAlertLevelResponse: return "Hypo Alert Level Response"
        case .setHyperAlertLevel: return "Set Hyper Alert Level"
        case .getHyperAlertLevel: return "Get Hyper Alert Level"
        case .hyperAlertLevelResponse: return "Hyper Alert Level Response"
        case .setRateOfDecreaseAlertLevel: return "Set Rate of Decrease Alert Level"
        case .getRateOfDecreaseAlertLevel: return "Get Rate of Decrease Alert Level"
        case .rateOfDecreaseAlertLevelResponse: return "Rate of Decrease Alert Level Response"
        case .setRateOfIncreaseAlertLevel: return "Set Rate of Increase Alert Level"
        case .getRateOfIncreaseAlertLevel: return "Get Rate of Increase Alert Level"
        case .rateOfIncreaseAlertLevelResponse: return "Rate of Increase Alert Level Response"
        case .resetDeviceSpecificAlert: return "Reset Device Specific Alert"
        case .startSession: return "Start Session"
        case .stopSession: return "Stop Session"
        case .responseCode: return "Response Code"
        }
    }
}

extension CGMRACPOpcode {
    /// Op codes a client writes, in spec order.
    public static let requests: [CGMRACPOpcode] = [.reportStoredRecords, .deleteStoredRecords, .abortOperation, .reportNumberOfStoredRecords]

    public var name: String {
        switch self {
        case .reportStoredRecords: return "Report Stored Records"
        case .deleteStoredRecords: return "Delete Stored Records"
        case .abortOperation: return "Abort Operation"
        case .reportNumberOfStoredRecords: return "Report Number of Stored Records"
        case .numberOfStoredRecordsResponse: return "Number of Stored Records Response"
        case .responseCode: return "Response Code"
        }
    }
}

extension CGMRACPOperator {
    /// Operators a client may send with a request (Null is reserved for responses).
    public static let requests: [CGMRACPOperator] = [.allRecords, .lessThanOrEqualTo, .greaterThanOrEqualTo, .withinRangeOf, .firstRecord, .lastRecord]

    public var name: String {
        switch self {
        case .null: return "Null"
        case .allRecords: return "All Records"
        case .lessThanOrEqualTo: return "Less Than or Equal To"
        case .greaterThanOrEqualTo: return "Greater Than or Equal To"
        case .withinRangeOf: return "Within Range Of"
        case .firstRecord: return "First Record"
        case .lastRecord: return "Last Record"
        }
    }
}

// MARK: - Calibration record (Table 3.7)

public struct CGMCalibrationRecord: Sendable {
    public static let encodedSize = 10
    /// Get operand meaning "the last calibration stored".
    public static let lastRecordNumber: UInt16 = 0xFFFF

    public var glucoseConcentration: Double
    /// Minutes since Session Start Time the calibration was measured.
    public var calibrationTime: UInt16
    public var type: CGMType
    public var sampleLocation: CGMSampleLocation
    /// Minutes since Session Start Time the next calibration is due; 0 means now.
    public var nextCalibrationTime: UInt16
    public var recordNumber: UInt16
    public var status: CGMCalibrationStatus

    public init(glucoseConcentration: Double, calibrationTime: UInt16, type: CGMType = .capillaryWholeBlood, sampleLocation: CGMSampleLocation = .finger, nextCalibrationTime: UInt16 = 0, recordNumber: UInt16 = 0, status: CGMCalibrationStatus = []) {
        self.glucoseConcentration = glucoseConcentration
        self.calibrationTime = calibrationTime
        self.type = type
        self.sampleLocation = sampleLocation
        self.nextCalibrationTime = nextCalibrationTime
        self.recordNumber = recordNumber
        self.status = status
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendSFloat(glucoseConcentration)
        data.append(calibrationTime)
        data.append(sampleLocation.rawValue << 4 | type.rawValue)
        data.append(nextCalibrationTime)
        data.append(recordNumber)
        data.append(status.rawValue)
        return data
    }

    /// Decodes exactly one record from `data` (a slice is fine).
    public init(data: Data) throws {
        guard data.count == Self.encodedSize else {
            throw CGMCodecError.truncated(expected: Self.encodedSize, actual: data.count)
        }
        var reader = CGMDataReader(data)
        glucoseConcentration = try reader.readSFloat()
        calibrationTime = try reader.read(UInt16.self)
        let typeSampleLocation = try reader.read(UInt8.self)
        guard let type = CGMType(rawValue: typeSampleLocation & 0x0F) else {
            throw CGMCodecError.invalidValue("CGM Type \(typeSampleLocation & 0x0F)")
        }
        guard let sampleLocation = CGMSampleLocation(rawValue: typeSampleLocation >> 4) else {
            throw CGMCodecError.invalidValue("CGM Sample Location \(typeSampleLocation >> 4)")
        }
        self.type = type
        self.sampleLocation = sampleLocation
        nextCalibrationTime = try reader.read(UInt16.self)
        recordNumber = try reader.read(UInt16.self)
        status = CGMCalibrationStatus(rawValue: try reader.read(UInt8.self))
    }
}

extension CGMCalibrationRecord: Equatable {
    public static func == (lhs: CGMCalibrationRecord, rhs: CGMCalibrationRecord) -> Bool {
        lhs.glucoseConcentration.isSameMeasurement(as: rhs.glucoseConcentration)
            && lhs.calibrationTime == rhs.calibrationTime
            && lhs.type == rhs.type
            && lhs.sampleLocation == rhs.sampleLocation
            && lhs.nextCalibrationTime == rhs.nextCalibrationTime
            && lhs.recordNumber == rhs.recordNumber
            && lhs.status == rhs.status
    }
}

extension CGMCalibrationRecord: CustomStringConvertible {
    public var description: String {
        let glucose = glucoseConcentration.isNaN ? "NaN" : "\(glucoseConcentration) mg/dL"
        return "record \(recordNumber): \(glucose) at offset \(calibrationTime) min, \(type)/\(sampleLocation), next calibration at \(nextCalibrationTime) min, status \(status.rawValue)"
    }
}

// MARK: - CGMCP request

public enum CGMSpecificOpsRequest {
    /// Op code, operand, then the E2E-CRC when the sensor's Feature says so.
    public static func encode(_ opcode: CGMSpecificOpsOpcode, operand: Data = Data(), e2eCRC: Bool) -> Data {
        var request = Data([opcode.rawValue])
        request.append(operand)
        return e2eCRC ? request.appendingCRC() : request
    }

    public static func setCommunicationInterval(minutes: UInt8, e2eCRC: Bool) -> Data {
        encode(.setCommunicationInterval, operand: Data([minutes]), e2eCRC: e2eCRC)
    }

    public static func getGlucoseCalibrationValue(recordNumber: UInt16 = CGMCalibrationRecord.lastRecordNumber, e2eCRC: Bool) -> Data {
        var operand = Data()
        operand.append(recordNumber)
        return encode(.getGlucoseCalibrationValue, operand: operand, e2eCRC: e2eCRC)
    }

    public static func setGlucoseCalibrationValue(_ record: CGMCalibrationRecord, e2eCRC: Bool) -> Data {
        encode(.setGlucoseCalibrationValue, operand: record.encoded(), e2eCRC: e2eCRC)
    }

    /// Any Set …Alert Level op code; `value` is mg/dL or mg/dL/min per the op code.
    public static func setLevel(_ opcode: CGMSpecificOpsOpcode, value: Double, e2eCRC: Bool) -> Data {
        var operand = Data()
        operand.appendSFloat(value)
        return encode(opcode, operand: operand, e2eCRC: e2eCRC)
    }
}

// MARK: - CGMCP response

public enum CGMSpecificOpsResponse: Equatable, Sendable {
    /// Generic Response Code: the request op code and the result. Raw values are kept for unknown codes.
    case responseCode(request: UInt8, code: UInt8)
    case communicationInterval(minutes: UInt8)
    case calibrationValue(CGMCalibrationRecord)
    /// Any …Alert Level Response; `opcode` says which.
    case level(opcode: CGMSpecificOpsOpcode, value: Double)

    public static let minimumSize = 2

    /// - Parameter e2eCRC: true when the sensor's Feature has E2E-CRC; the trailing CRC is then required.
    public init(data: Data, e2eCRC: Bool) throws {
        guard data.count >= Self.minimumSize else {
            throw CGMCodecError.truncated(expected: Self.minimumSize, actual: data.count)
        }
        if e2eCRC {
            guard data.count >= Self.minimumSize + CGME2ECRC.size else { throw CGMCodecError.missingCRC }
            guard data.isCRCValid else { throw CGMCodecError.invalidCRC }
        }
        let payload = e2eCRC ? data.dropLast(CGME2ECRC.size) : data[...]
        var reader = CGMDataReader(payload)
        let rawOpcode = try reader.read(UInt8.self)
        guard let opcode = CGMSpecificOpsOpcode(rawValue: rawOpcode) else {
            throw CGMCodecError.invalidValue("CGMCP op code 0x\(String(rawOpcode, radix: 16))")
        }

        switch opcode {
        case .responseCode:
            let request = try reader.read(UInt8.self)
            let code = try reader.read(UInt8.self)
            self = .responseCode(request: request, code: code)
        case .communicationIntervalResponse:
            self = .communicationInterval(minutes: try reader.read(UInt8.self))
        case .glucoseCalibrationValueResponse:
            self = .calibrationValue(try CGMCalibrationRecord(data: try reader.readBytes(CGMCalibrationRecord.encodedSize)))
        case .patientHighAlertLevelResponse, .patientLowAlertLevelResponse, .hypoAlertLevelResponse,
             .hyperAlertLevelResponse, .rateOfDecreaseAlertLevelResponse, .rateOfIncreaseAlertLevelResponse:
            self = .level(opcode: opcode, value: try reader.readSFloat())
        default:
            throw CGMCodecError.invalidValue("\(opcode.name) is not a response op code")
        }
    }

    public func encoded(e2eCRC: Bool) -> Data {
        var data: Data
        switch self {
        case let .responseCode(request, code):
            data = Data([CGMSpecificOpsOpcode.responseCode.rawValue, request, code])
        case .communicationInterval(let minutes):
            data = Data([CGMSpecificOpsOpcode.communicationIntervalResponse.rawValue, minutes])
        case .calibrationValue(let record):
            data = Data([CGMSpecificOpsOpcode.glucoseCalibrationValueResponse.rawValue])
            data.append(record.encoded())
        case let .level(opcode, value):
            data = Data([opcode.rawValue])
            data.appendSFloat(value)
        }
        return e2eCRC ? data.appendingCRC() : data
    }
}

extension CGMSpecificOpsResponse: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .responseCode(request, code):
            let requestName = CGMSpecificOpsOpcode(rawValue: request)?.name ?? "op code 0x\(String(request, radix: 16))"
            let codeName = CGMSpecificOpsResponseCode(rawValue: code).map { "\($0)" } ?? "response code 0x\(String(code, radix: 16))"
            return "\(requestName): \(codeName)"
        case .communicationInterval(let minutes):
            switch minutes {
            case CGMCommunicationInterval.periodicDisabled: return "communication interval: periodic communication disabled"
            case CGMCommunicationInterval.fastestSupported: return "communication interval: fastest supported"
            default: return "communication interval: \(minutes) min"
            }
        case .calibrationValue(let record):
            return "calibration \(record)"
        case let .level(opcode, value):
            let unit = opcode == .rateOfDecreaseAlertLevelResponse || opcode == .rateOfIncreaseAlertLevelResponse ? "mg/dL/min" : "mg/dL"
            return "\(opcode.name): \(value.isNaN ? "NaN" : "\(value) \(unit)")"
        }
    }
}

// MARK: - RACP request

/// A client request on the Record Access Control Point. Only the Time Offset filter is legal in CGMS
/// (Table 3.5); the filter fields are UINT16 minutes.
public struct CGMRACPRequest: Equatable, Sendable {
    public var opcode: CGMRACPOpcode
    public var racpOperator: CGMRACPOperator
    public var filterType: CGMRACPFilterType
    /// Used by Greater Than or Equal To and Within Range Of.
    public var minimum: UInt16
    /// Used by Less Than or Equal To and Within Range Of.
    public var maximum: UInt16

    public init(opcode: CGMRACPOpcode, racpOperator: CGMRACPOperator, filterType: CGMRACPFilterType = .timeOffset, minimum: UInt16 = 0, maximum: UInt16 = 0) {
        self.opcode = opcode
        self.racpOperator = racpOperator
        self.filterType = filterType
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Abort Operation carries the Null operator and no operand (CGMS §3.6.3.5).
    public static let abort = CGMRACPRequest(opcode: .abortOperation, racpOperator: .null)

    /// RACP never carries an E2E-CRC (CGMS §3.6).
    public func encoded() -> Data {
        var data = Data([opcode.rawValue, racpOperator.rawValue])
        switch racpOperator {
        case .lessThanOrEqualTo:
            data.append(filterType.rawValue)
            data.append(maximum)
        case .greaterThanOrEqualTo:
            data.append(filterType.rawValue)
            data.append(minimum)
        case .withinRangeOf:
            data.append(filterType.rawValue)
            data.append(minimum)
            data.append(maximum)
        case .null, .allRecords, .firstRecord, .lastRecord:
            break
        }
        return data
    }
}

/// Why an RACP request was refused; each case maps to a Response Code (CGMS §3.6.3.6, GLS RACP).
public enum CGMRACPRequestError: Error, Equatable, Sendable {
    case opCodeNotSupported(UInt8)
    case invalidOperator(UInt8)
    /// Filter Type other than Time Offset (CGMS Table 3.5; User Facing Time is not allowed in CGMS).
    case operandNotSupported(UInt8)
    case invalidOperand
}

extension CGMRACPRequest {
    /// Decodes a client write to the RACP, validating op code, operator and operand shape together.
    public init(data: Data) throws {
        guard data.count >= 2 else { throw CGMRACPRequestError.invalidOperand }
        var reader = CGMDataReader(data)
        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            do { return try reader.read(type) } catch { throw CGMRACPRequestError.invalidOperand }
        }

        let rawOpcode = try read(UInt8.self)
        guard let opcode = CGMRACPOpcode(rawValue: rawOpcode), CGMRACPOpcode.requests.contains(opcode) else {
            throw CGMRACPRequestError.opCodeNotSupported(rawOpcode)
        }
        let rawOperator = try read(UInt8.self)
        guard let racpOperator = CGMRACPOperator(rawValue: rawOperator) else {
            throw CGMRACPRequestError.invalidOperator(rawOperator)
        }

        // Abort carries the Null operator and nothing else; every other op code needs a real operator.
        if opcode == .abortOperation {
            guard racpOperator == .null else { throw CGMRACPRequestError.invalidOperator(rawOperator) }
            guard reader.isAtEnd else { throw CGMRACPRequestError.invalidOperand }
            self = .abort
            return
        }
        guard racpOperator != .null else { throw CGMRACPRequestError.invalidOperator(rawOperator) }

        var minimum: UInt16 = 0
        var maximum: UInt16 = 0
        if racpOperator.includesFilter {
            let rawFilter = try read(UInt8.self)
            guard CGMRACPFilterType(rawValue: rawFilter) == .timeOffset else {
                throw CGMRACPRequestError.operandNotSupported(rawFilter)
            }
            switch racpOperator {
            case .lessThanOrEqualTo:
                maximum = try read(UInt16.self)
            case .greaterThanOrEqualTo:
                minimum = try read(UInt16.self)
            case .withinRangeOf:
                minimum = try read(UInt16.self)
                maximum = try read(UInt16.self)
                guard minimum <= maximum else { throw CGMRACPRequestError.invalidOperand }
            default:
                break
            }
        }
        guard reader.isAtEnd else { throw CGMRACPRequestError.invalidOperand }

        self.init(opcode: opcode, racpOperator: racpOperator, filterType: .timeOffset, minimum: minimum, maximum: maximum)
    }
}

// MARK: - RACP response

public enum CGMRACPResponse: Equatable, Sendable {
    /// Raw values are kept so unknown codes still display.
    case responseCode(request: UInt8, code: UInt8)
    case numberOfStoredRecords(UInt16)

    /// The op code of the request this indication answers; Number of Stored Records has only one.
    public var requestOpcode: UInt8 {
        switch self {
        case .responseCode(let request, _): return request
        case .numberOfStoredRecords: return CGMRACPOpcode.reportNumberOfStoredRecords.rawValue
        }
    }

    public init(data: Data) throws {
        guard data.count >= 4 else {
            throw CGMCodecError.truncated(expected: 4, actual: data.count)
        }
        var reader = CGMDataReader(data)
        let rawOpcode = try reader.read(UInt8.self)
        _ = try reader.read(UInt8.self)   // operator, Null in responses
        switch CGMRACPOpcode(rawValue: rawOpcode) {
        case .responseCode:
            self = .responseCode(request: try reader.read(UInt8.self), code: try reader.read(UInt8.self))
        case .numberOfStoredRecordsResponse:
            self = .numberOfStoredRecords(try reader.read(UInt16.self))
        default:
            throw CGMCodecError.invalidValue("RACP op code 0x\(String(rawOpcode, radix: 16)) is not a response")
        }
    }

    public func encoded() -> Data {
        var data = Data()
        switch self {
        case let .responseCode(request, code):
            data.append(contentsOf: [CGMRACPOpcode.responseCode.rawValue, CGMRACPOperator.null.rawValue, request, code])
        case .numberOfStoredRecords(let count):
            data.append(contentsOf: [CGMRACPOpcode.numberOfStoredRecordsResponse.rawValue, CGMRACPOperator.null.rawValue])
            data.append(count)
        }
        return data
    }
}

extension CGMRACPResponse: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .responseCode(request, code):
            let requestName = CGMRACPOpcode(rawValue: request)?.name ?? "op code 0x\(String(request, radix: 16))"
            let codeName = CGMRACPResponseCode(rawValue: code).map { "\($0)" } ?? "response code 0x\(String(code, radix: 16))"
            return "\(requestName): \(codeName)"
        case .numberOfStoredRecords(let count):
            return "number of stored records: \(count)"
        }
    }
}
