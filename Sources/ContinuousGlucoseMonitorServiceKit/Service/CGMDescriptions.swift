//
//  CGMDescriptions.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-01.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Human-readable names for flags and decoded values, used by tester UIs and logs.

import Foundation

extension CGMFeatureFlags: CustomStringConvertible {
    /// Every defined bit with its display name, in bit order.
    public static let named: [(flag: CGMFeatureFlags, name: String)] = [
        (.calibration, "Calibration"),
        (.patientHighLowAlerts, "Patient High/Low Alerts"),
        (.hypoAlerts, "Hypo Alerts"),
        (.hyperAlerts, "Hyper Alerts"),
        (.rateOfIncreaseDecreaseAlerts, "Rate of Increase/Decrease Alerts"),
        (.deviceSpecificAlert, "Device Specific Alert"),
        (.sensorMalfunctionDetection, "Sensor Malfunction Detection"),
        (.sensorTemperatureHighLowDetection, "Sensor Temperature High-Low Detection"),
        (.sensorResultHighLowDetection, "Sensor Result High-Low Detection"),
        (.lowBatteryDetection, "Low Battery Detection"),
        (.sensorTypeErrorDetection, "Sensor Type Error Detection"),
        (.generalDeviceFault, "General Device Fault"),
        (.e2eCRC, "E2E-CRC"),
        (.multipleBond, "Multiple Bond"),
        (.multipleSessions, "Multiple Sessions"),
        (.trendInformation, "CGM Trend Information"),
        (.quality, "CGM Quality"),
    ]

    public var description: String {
        let names = Self.named.filter { contains($0.flag) }.map(\.name)
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

extension CGMSensorStatusAnnunciation: CustomStringConvertible {
    /// Every defined bit with its display name, in bit order.
    public static let named: [(flag: CGMSensorStatusAnnunciation, name: String)] = [
        (.sessionStopped, "Session Stopped"),
        (.deviceBatteryLow, "Device Battery Low"),
        (.sensorTypeIncorrect, "Sensor Type Incorrect"),
        (.sensorMalfunction, "Sensor Malfunction"),
        (.deviceSpecificAlert, "Device Specific Alert"),
        (.generalDeviceFault, "General Device Fault"),
        (.timeSynchronizationRequired, "Time Synchronization Required"),
        (.calibrationNotAllowed, "Calibration Not Allowed"),
        (.calibrationRecommended, "Calibration Recommended"),
        (.calibrationRequired, "Calibration Required"),
        (.sensorTemperatureTooHigh, "Sensor Temperature Too High"),
        (.sensorTemperatureTooLow, "Sensor Temperature Too Low"),
        (.calibrationProcessPending, "Calibration Process Pending"),
        (.resultLowerThanPatientLow, "Result Lower Than Patient Low"),
        (.resultHigherThanPatientHigh, "Result Higher Than Patient High"),
        (.resultLowerThanHypo, "Result Lower Than Hypo"),
        (.resultHigherThanHyper, "Result Higher Than Hyper"),
        (.rateOfDecreaseExceeded, "Rate of Decrease Exceeded"),
        (.rateOfIncreaseExceeded, "Rate of Increase Exceeded"),
        (.resultLowerThanDeviceCanProcess, "Result Lower Than Device Can Process"),
        (.resultHigherThanDeviceCanProcess, "Result Higher Than Device Can Process"),
    ]

    public var description: String {
        let names = Self.named.filter { contains($0.flag) }.map(\.name)
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

extension CGMFeature: CustomStringConvertible {
    public var description: String {
        "features: [\(flags)], type: \(type), location: \(sampleLocation)"
    }
}

extension CGMStatus: CustomStringConvertible {
    public var description: String {
        "time offset: \(timeOffset) min, status: [\(sensorStatus)]"
    }
}

extension CGMSessionStartTime: CustomStringConvertible {
    public var description: String {
        // A FormatStyle is a value, so there is no formatter to allocate or share.
        let formatted = Date.ISO8601FormatStyle(timeZone: localTimeZone).format(date)
        let zone = timeZoneOffset == Self.unknownTimeZone ? "unknown" : "\(Double(timeZoneOffset) / 4) h"
        return "\(formatted) (zone: \(zone), DST: \(dstOffset))"
    }
}

extension CGMSessionRunTime: CustomStringConvertible {
    public var description: String {
        "\(hours) h"
    }
}

extension CGMMeasurementRecord: CustomStringConvertible {
    public var description: String {
        var parts = ["\(glucoseConcentration.isNaN ? "NaN" : String(glucoseConcentration)) mg/dL", "offset \(timeOffset) min"]
        if let trend { parts.append("trend \(trend) mg/dL/min") }
        if let quality { parts.append("quality \(quality)%") }
        if !sensorStatus.isEmpty { parts.append("status [\(sensorStatus)]") }
        return parts.joined(separator: ", ")
    }
}
