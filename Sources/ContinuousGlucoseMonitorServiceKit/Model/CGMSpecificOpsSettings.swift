//
//  CGMSpecificOpsSettings.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-14.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Sensor-side state behind the CGM Specific Ops Control Point procedures (CGMS §3.7.2): the alert levels a
//  collector sets and the sensor compares every reading against, and the calibration records it stores.

import Foundation

// MARK: - Alert levels (§3.7.2.3 – §3.7.2.6)

/// Thresholds in mg/dL (levels) and mg/dL/min (rates). A Rate of Decrease level is negative: the bit trips
/// when the trend is lower than it, just as Rate of Increase trips when the trend is higher (§3.7.2.6).
public struct CGMAlertLevels: Equatable, Sendable {
    /// What this sensor accepts; anything else is Parameter Out of Range (§3.7.2.3). Wide enough for any
    /// clinical value, narrow enough that a tester can provoke the refusal.
    public static let glucoseRange: ClosedRange<Double> = 20...600
    public static let rateRange: ClosedRange<Double> = -50...50

    public var patientHigh: Double
    public var patientLow: Double
    public var hypo: Double
    public var hyper: Double
    public var rateOfDecrease: Double
    public var rateOfIncrease: Double

    public init(patientHigh: Double = 250, patientLow: Double = 70, hypo: Double = 55, hyper: Double = 300, rateOfDecrease: Double = -3, rateOfIncrease: Double = 3) {
        self.patientHigh = patientHigh
        self.patientLow = patientLow
        self.hypo = hypo
        self.hyper = hyper
        self.rateOfDecrease = rateOfDecrease
        self.rateOfIncrease = rateOfIncrease
    }

    /// True when `value` may be stored for the level `opcode` sets. NaN and infinities fall outside both ranges.
    public static func isInRange(_ value: Double, for opcode: CGMSpecificOpsOpcode) -> Bool {
        switch opcode {
        case .setRateOfDecreaseAlertLevel, .setRateOfIncreaseAlertLevel: return rateRange.contains(value)
        default: return glucoseRange.contains(value)
        }
    }

    /// Annunciation bits a reading trips, limited to the alert families the Feature says exist. A reading
    /// the sensor could not quantify (NaN) trips nothing.
    public func annunciation(glucose: Double, trend: Double?, feature: CGMFeatureFlags) -> CGMSensorStatusAnnunciation {
        var bits: CGMSensorStatusAnnunciation = []
        if feature.contains(.patientHighLowAlerts) {
            if glucose > patientHigh { bits.insert(.resultHigherThanPatientHigh) }
            if glucose < patientLow { bits.insert(.resultLowerThanPatientLow) }
        }
        if feature.contains(.hypoAlerts), glucose < hypo { bits.insert(.resultLowerThanHypo) }
        if feature.contains(.hyperAlerts), glucose > hyper { bits.insert(.resultHigherThanHyper) }
        if feature.contains(.rateOfIncreaseDecreaseAlerts), let trend {
            if trend > rateOfIncrease { bits.insert(.rateOfIncreaseExceeded) }
            if trend < rateOfDecrease { bits.insert(.rateOfDecreaseExceeded) }
        }
        return bits
    }

    /// Bits this struct can set, so a caller can clear them before re-evaluating.
    public static let annunciationBits: CGMSensorStatusAnnunciation = [
        .resultHigherThanPatientHigh, .resultLowerThanPatientLow,
        .resultLowerThanHypo, .resultHigherThanHyper,
        .rateOfIncreaseExceeded, .rateOfDecreaseExceeded
    ]
}

extension CGMSpecificOpsOpcode {
    /// Feature bit without which the op code is excluded (Table 3.6, C.1–C.9); nil for the always-present ones.
    public var requiredFeature: CGMFeatureFlags? {
        switch self {
        case .setGlucoseCalibrationValue, .getGlucoseCalibrationValue: return .calibration
        case .setPatientHighAlertLevel, .getPatientHighAlertLevel, .setPatientLowAlertLevel, .getPatientLowAlertLevel: return .patientHighLowAlerts
        case .setHypoAlertLevel, .getHypoAlertLevel: return .hypoAlerts
        case .setHyperAlertLevel, .getHyperAlertLevel: return .hyperAlerts
        case .setRateOfDecreaseAlertLevel, .getRateOfDecreaseAlertLevel, .setRateOfIncreaseAlertLevel, .getRateOfIncreaseAlertLevel: return .rateOfIncreaseDecreaseAlerts
        case .resetDeviceSpecificAlert: return .deviceSpecificAlert
        default: return nil
        }
    }

    /// The level a Set or Get …Alert Level op code works on.
    public var alertLevelKeyPath: WritableKeyPath<CGMAlertLevels, Double>? {
        switch self {
        case .setPatientHighAlertLevel, .getPatientHighAlertLevel, .patientHighAlertLevelResponse: return \.patientHigh
        case .setPatientLowAlertLevel, .getPatientLowAlertLevel, .patientLowAlertLevelResponse: return \.patientLow
        case .setHypoAlertLevel, .getHypoAlertLevel, .hypoAlertLevelResponse: return \.hypo
        case .setHyperAlertLevel, .getHyperAlertLevel, .hyperAlertLevelResponse: return \.hyper
        case .setRateOfDecreaseAlertLevel, .getRateOfDecreaseAlertLevel, .rateOfDecreaseAlertLevelResponse: return \.rateOfDecrease
        case .setRateOfIncreaseAlertLevel, .getRateOfIncreaseAlertLevel, .rateOfIncreaseAlertLevelResponse: return \.rateOfIncrease
        default: return nil
        }
    }

    /// Response op code that answers a Get …Alert Level request.
    public var levelResponseOpcode: CGMSpecificOpsOpcode? {
        switch self {
        case .getPatientHighAlertLevel: return .patientHighAlertLevelResponse
        case .getPatientLowAlertLevel: return .patientLowAlertLevelResponse
        case .getHypoAlertLevel: return .hypoAlertLevelResponse
        case .getHyperAlertLevel: return .hyperAlertLevelResponse
        case .getRateOfDecreaseAlertLevel: return .rateOfDecreaseAlertLevelResponse
        case .getRateOfIncreaseAlertLevel: return .rateOfIncreaseAlertLevelResponse
        default: return nil
        }
    }
}

// MARK: - Calibration schedule (§3.7.2.2 Next Calibration Time)

/// How often the sensor asks for calibration. Each stored calibration carries the Next Calibration Time this
/// produces; 0 means "required instantly" (spec), 0xFFFF stands in for "no further calibration".
public enum CGMCalibrationSchedule: Hashable, Sendable {
    /// Never asks: no Recommended or Required bits, even before a first calibration.
    case never
    /// Recommends a first calibration each session, then nothing more.
    case oncePerSession
    /// Recommends `leadMinutes` before each due time and requires once it has passed.
    case every(minutes: UInt16)
    /// Always required: before any calibration and again right after each one.
    case immediately

    /// Sentinel Next Calibration Time for schedules with nothing further due.
    public static let noFurtherCalibration: UInt16 = .max

    /// Next Calibration Time to store with a calibration measured at `calibrationTime`.
    public func nextCalibrationTime(after calibrationTime: UInt16) -> UInt16 {
        switch self {
        case .never, .oncePerSession: return Self.noFurtherCalibration
        case .every(let minutes):
            let next = calibrationTime.addingReportingOverflow(minutes)
            return next.overflow ? Self.noFurtherCalibration : next.partialValue
        case .immediately: return 0
        }
    }

    /// Minutes ahead of the due time to recommend: the sensor's lead, capped at half the interval so a short
    /// test schedule still shows a recommended phase before the required one.
    public func recommendedLead(_ lead: UInt16) -> UInt16 {
        if case .every(let minutes) = self { return min(lead, minutes / 2) }
        return lead
    }

    /// Bits to raise before any calibration has been stored this session.
    public var initialStatus: CGMSensorStatusAnnunciation {
        switch self {
        case .never: return []
        case .oncePerSession, .every: return .calibrationRecommended
        case .immediately: return .calibrationRequired
        }
    }

    /// Session minutes after which an unanswered first-calibration recommendation becomes Required: the
    /// interval itself for a periodic schedule, `graceMinutes` for Once; nil when nothing escalates.
    public func firstCalibrationRequiredAfter(graceMinutes: UInt16) -> UInt16? {
        switch self {
        case .oncePerSession: return graceMinutes
        case .every(let minutes): return minutes
        case .never, .immediately: return nil
        }
    }
}

// MARK: - Calibration records (§3.7.2.2)

/// Calibration Data Records indexed by record number, which increments on every stored calibration. Record 0
/// is the spec's "nothing stored" placeholder and is never kept in the list.
public struct CGMCalibrationStore: Equatable, Sendable {
    /// A real sensor keeps a handful; enough here that a tester can ask for a number that has fallen out.
    public static let defaultCapacity = 20

    /// CGMS §3.7.2.2: record number 0 means no calibration value is stored.
    public static let noCalibration = CGMCalibrationRecord(glucoseConcentration: .nan, calibrationTime: 0, recordNumber: 0)

    public var capacity: Int {
        didSet {
            capacity = max(1, capacity)
            trim()
        }
    }

    public private(set) var records: [CGMCalibrationRecord] = []
    public private(set) var nextRecordNumber: UInt16 = 1

    public init(capacity: Int = CGMCalibrationStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { records.count }
    public var last: CGMCalibrationRecord? { records.last }

    /// Stores a collector's calibration. Record Number and Status in `submitted` are ignored (§3.7.2.2);
    /// the sensor assigns the number and reports when the next calibration is due. Returns what was stored.
    @discardableResult
    public mutating func store(_ submitted: CGMCalibrationRecord, nextCalibrationTime: UInt16, status: CGMCalibrationStatus = []) -> CGMCalibrationRecord {
        var record = submitted
        record.recordNumber = nextRecordNumber
        record.nextCalibrationTime = nextCalibrationTime
        record.status = status
        records.append(record)
        trim()
        // 0xFFFF is the "last record" request operand, so the counter skips it.
        nextRecordNumber = nextRecordNumber >= CGMCalibrationRecord.lastRecordNumber - 1 ? 1 : nextRecordNumber + 1
        return record
    }

    /// The record a Get asks for: 0xFFFF is the last stored, 0 (or an empty store asked for the last) is the
    /// placeholder, and a number no longer held is nil so the caller can answer Parameter Out of Range.
    public func record(number: UInt16) -> CGMCalibrationRecord? {
        switch number {
        case 0: return Self.noCalibration
        case CGMCalibrationRecord.lastRecordNumber: return last ?? Self.noCalibration
        default: return records.first { $0.recordNumber == number }
        }
    }

    /// A new session starts with no calibrations (§3.7.2.8 deletes all previous data).
    public mutating func removeAll() {
        records.removeAll()
        nextRecordNumber = 1
    }

    private mutating func trim() {
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }
}
