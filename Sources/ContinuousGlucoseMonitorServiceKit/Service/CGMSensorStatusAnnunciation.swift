//
//  CGMSensorStatusAnnunciation.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Sensor Status Annunciation field (CGMS §3.1.1.5, Table 3.2): three octets, Status / Cal-Temp / Warning.
//  Bit positions come from the GATT Specification Supplement. VERIFY against the current GSS, in particular
//  Calibration Process Pending (assumed bit 14).

import Foundation
import BluetoothCommonKit

public struct CGMSensorStatusAnnunciation: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & Self.mask
    }

    public init(statusOctet: UInt8 = 0, calTempOctet: UInt8 = 0, warningOctet: UInt8 = 0) {
        self.init(rawValue: UInt32(statusOctet) | UInt32(calTempOctet) << 8 | UInt32(warningOctet) << 16)
    }

    // Status octet (bits 0–7)
    public static let sessionStopped = CGMSensorStatusAnnunciation(rawValue: 1 << 0)
    public static let deviceBatteryLow = CGMSensorStatusAnnunciation(rawValue: 1 << 1)
    public static let sensorTypeIncorrect = CGMSensorStatusAnnunciation(rawValue: 1 << 2)
    public static let sensorMalfunction = CGMSensorStatusAnnunciation(rawValue: 1 << 3)
    public static let deviceSpecificAlert = CGMSensorStatusAnnunciation(rawValue: 1 << 4)
    public static let generalDeviceFault = CGMSensorStatusAnnunciation(rawValue: 1 << 5)

    // Cal/Temp octet (bits 8–15)
    public static let timeSynchronizationRequired = CGMSensorStatusAnnunciation(rawValue: 1 << 8)
    public static let calibrationNotAllowed = CGMSensorStatusAnnunciation(rawValue: 1 << 9)
    public static let calibrationRecommended = CGMSensorStatusAnnunciation(rawValue: 1 << 10)
    public static let calibrationRequired = CGMSensorStatusAnnunciation(rawValue: 1 << 11)
    public static let sensorTemperatureTooHigh = CGMSensorStatusAnnunciation(rawValue: 1 << 12)
    public static let sensorTemperatureTooLow = CGMSensorStatusAnnunciation(rawValue: 1 << 13)
    public static let calibrationProcessPending = CGMSensorStatusAnnunciation(rawValue: 1 << 14)

    // Warning octet (bits 16–23)
    public static let resultLowerThanPatientLow = CGMSensorStatusAnnunciation(rawValue: 1 << 16)
    public static let resultHigherThanPatientHigh = CGMSensorStatusAnnunciation(rawValue: 1 << 17)
    public static let resultLowerThanHypo = CGMSensorStatusAnnunciation(rawValue: 1 << 18)
    public static let resultHigherThanHyper = CGMSensorStatusAnnunciation(rawValue: 1 << 19)
    public static let rateOfDecreaseExceeded = CGMSensorStatusAnnunciation(rawValue: 1 << 20)
    public static let rateOfIncreaseExceeded = CGMSensorStatusAnnunciation(rawValue: 1 << 21)
    public static let resultLowerThanDeviceCanProcess = CGMSensorStatusAnnunciation(rawValue: 1 << 22)
    public static let resultHigherThanDeviceCanProcess = CGMSensorStatusAnnunciation(rawValue: 1 << 23)

    public static let mask: UInt32 = 0x00FF_FFFF

    public var statusOctet: UInt8 { UInt8(truncatingIfNeeded: rawValue) }
    public var calTempOctet: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 8) }
    public var warningOctet: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 16) }

    /// Fixed 3-octet form used by the CGM Status characteristic (CGMS §3.3.2).
    public var data: Data {
        Data([statusOctet, calTempOctet, warningOctet])
    }
}
