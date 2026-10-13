//
//  CGMControlPointCodecTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-09.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

@Suite("CGMCP requests")
struct CGMSpecificOpsRequestTests {
    @Test func operandTableCoversEveryRequestOpCode() {
        #expect(CGMSpecificOpsOpcode.requests.count == 19)
        #expect(CGMSpecificOpsOpcode.responseCode.requestOperand == nil)
        #expect(CGMSpecificOpsOpcode.hypoAlertLevelResponse.requestOperand == nil)
        #expect(CGMSpecificOpsOpcode.startSession.requestOperand == CGMSpecificOpsOperand.none)
        #expect(CGMSpecificOpsOpcode.setHypoAlertLevel.requestOperand == .glucoseLevel)
        #expect(CGMSpecificOpsOpcode.setRateOfIncreaseAlertLevel.requestOperand == .rateLevel)
    }

    @Test func encodesOperands() throws {
        #expect(CGMSpecificOpsRequest.encode(.startSession, e2eCRC: false) == Data([0x1A]))
        #expect(CGMSpecificOpsRequest.setCommunicationInterval(minutes: 5, e2eCRC: false) == Data([0x01, 0x05]))
        #expect(CGMSpecificOpsRequest.getGlucoseCalibrationValue(e2eCRC: false) == Data([0x05, 0xFF, 0xFF]))

        let level = CGMSpecificOpsRequest.setLevel(.setPatientHighAlertLevel, value: 180, e2eCRC: false)
        #expect(level.count == 3)
        #expect(level[0] == 0x07)
        var reader = CGMDataReader(level.dropFirst())
        #expect(try reader.readSFloat() == 180)
    }

    @Test func appendsCRCWhenE2ESupported() {
        let request = CGMSpecificOpsRequest.setCommunicationInterval(minutes: 1, e2eCRC: true)
        #expect(request.count == 4)
        #expect(request.isCRCValid)
    }
}

@Suite("CGM calibration record")
struct CGMCalibrationRecordTests {
    @Test func roundTrip() throws {
        let record = CGMCalibrationRecord(glucoseConcentration: 123, calibrationTime: 90, type: .capillaryWholeBlood, sampleLocation: .finger, nextCalibrationTime: 810, recordNumber: 3, status: .processPending)
        let data = record.encoded()
        #expect(data.count == CGMCalibrationRecord.encodedSize)
        #expect(data[4] == 0x11)   // finger (1) << 4 | capillary whole blood (1)
        #expect(try CGMCalibrationRecord(data: data) == record)
    }

    @Test func rejectsWrongSizeAndUnknownNibbles() {
        #expect(throws: CGMCodecError.truncated(expected: 10, actual: 9)) {
            try CGMCalibrationRecord(data: Data(repeating: 0, count: 9))
        }
        var bad = CGMCalibrationRecord(glucoseConcentration: 100, calibrationTime: 0).encoded()
        bad[4] = 0x10   // type nibble 0 is RFU
        #expect(throws: CGMCodecError.self) { try CGMCalibrationRecord(data: bad) }
    }
}

@Suite("CGMCP responses")
struct CGMSpecificOpsResponseTests {
    @Test func decodesEachResponseShape() throws {
        let code = try CGMSpecificOpsResponse(data: Data([0x1C, 0x1A, 0x01]), e2eCRC: false)
        #expect(code == .responseCode(request: 0x1A, code: 0x01))
        #expect(String(describing: code) == "Start Session: success")

        let interval = try CGMSpecificOpsResponse(data: Data([0x03, 0xFF]), e2eCRC: false)
        #expect(interval == .communicationInterval(minutes: 0xFF))
        #expect(String(describing: interval).contains("fastest"))

        let level = CGMSpecificOpsResponse.level(opcode: .rateOfDecreaseAlertLevelResponse, value: 3)
        #expect(try CGMSpecificOpsResponse(data: level.encoded(e2eCRC: false), e2eCRC: false) == level)
        #expect(String(describing: level) == "Rate of Decrease Alert Level Response: 3.0 mg/dL/min")

        let record = CGMCalibrationRecord(glucoseConcentration: 110, calibrationTime: 15, recordNumber: 1)
        let calibration = CGMSpecificOpsResponse.calibrationValue(record)
        #expect(try CGMSpecificOpsResponse(data: calibration.encoded(e2eCRC: false), e2eCRC: false) == calibration)
    }

    @Test func unknownCodesStillDescribe() throws {
        let response = try CGMSpecificOpsResponse(data: Data([0x1C, 0x7E, 0x7F]), e2eCRC: false)
        #expect(String(describing: response) == "op code 0x7e: response code 0x7f")
    }

    @Test func enforcesCRCWhenE2ESupported() throws {
        let plain = Data([0x1C, 0x1A, 0x01])
        #expect(throws: CGMCodecError.missingCRC) { try CGMSpecificOpsResponse(data: plain, e2eCRC: true) }
        var corrupted = plain.appendingCRC()
        corrupted[1] ^= 0xFF
        #expect(throws: CGMCodecError.invalidCRC) { try CGMSpecificOpsResponse(data: corrupted, e2eCRC: true) }
        #expect(try CGMSpecificOpsResponse(data: plain.appendingCRC(), e2eCRC: true) == .responseCode(request: 0x1A, code: 0x01))
    }

    @Test func rejectsRequestOpCodesAndShortData() {
        #expect(throws: CGMCodecError.self) { try CGMSpecificOpsResponse(data: Data([0x1A, 0x00]), e2eCRC: false) }
        #expect(throws: CGMCodecError.self) { try CGMSpecificOpsResponse(data: Data([0x1C]), e2eCRC: false) }
    }
}

@Suite("RACP requests and responses")
struct CGMRACPCodecTests {
    @Test func encodesOperatorsAndFilters() {
        #expect(CGMRACPRequest(opcode: .reportNumberOfStoredRecords, racpOperator: .allRecords).encoded() == Data([0x04, 0x01]))
        #expect(CGMRACPRequest.abort.encoded() == Data([0x03, 0x00]))
        #expect(CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .lessThanOrEqualTo, maximum: 0x0102).encoded() == Data([0x01, 0x02, 0x01, 0x02, 0x01]))
        #expect(CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .greaterThanOrEqualTo, minimum: 30).encoded() == Data([0x01, 0x03, 0x01, 0x1E, 0x00]))
        #expect(CGMRACPRequest(opcode: .deleteStoredRecords, racpOperator: .withinRangeOf, minimum: 10, maximum: 20).encoded() == Data([0x02, 0x04, 0x01, 0x0A, 0x00, 0x14, 0x00]))
        #expect(CGMRACPRequest(opcode: .reportStoredRecords, racpOperator: .lastRecord).encoded() == Data([0x01, 0x06]))
    }

    @Test func decodesResponses() throws {
        let code = try CGMRACPResponse(data: Data([0x06, 0x00, 0x04, 0x02]))
        #expect(code == .responseCode(request: 0x04, code: 0x02))
        #expect(String(describing: code) == "Report Number of Stored Records: opCodeNotSupported")

        let count = try CGMRACPResponse(data: Data([0x05, 0x00, 0x2A, 0x00]))
        #expect(count == .numberOfStoredRecords(42))
        #expect(count.encoded() == Data([0x05, 0x00, 0x2A, 0x00]))

        #expect(throws: CGMCodecError.self) { try CGMRACPResponse(data: Data([0x01, 0x01, 0x00, 0x00])) }
        #expect(throws: CGMCodecError.self) { try CGMRACPResponse(data: Data([0x06, 0x00])) }
    }

    @Test func requestListsExcludeResponsesAndNull() {
        #expect(CGMRACPOpcode.requests.count == 4)
        #expect(!CGMRACPOperator.requests.contains(.null))
    }
}
