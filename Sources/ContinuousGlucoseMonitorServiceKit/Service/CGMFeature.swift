//
//  CGMFeature.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  CGM Feature characteristic (CGMS §3.2): 24-bit feature flags, Type-Sample Location octet, E2E-CRC.
//  Bit positions come from the GATT Specification Supplement (CGM Feature). VERIFY against the current GSS.

import Foundation
import BluetoothCommonKit

public struct CGMFeatureFlags: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue & Self.mask
    }

    public static let calibration = CGMFeatureFlags(rawValue: 1 << 0)
    public static let patientHighLowAlerts = CGMFeatureFlags(rawValue: 1 << 1)
    public static let hypoAlerts = CGMFeatureFlags(rawValue: 1 << 2)
    public static let hyperAlerts = CGMFeatureFlags(rawValue: 1 << 3)
    public static let rateOfIncreaseDecreaseAlerts = CGMFeatureFlags(rawValue: 1 << 4)
    public static let deviceSpecificAlert = CGMFeatureFlags(rawValue: 1 << 5)
    public static let sensorMalfunctionDetection = CGMFeatureFlags(rawValue: 1 << 6)
    public static let sensorTemperatureHighLowDetection = CGMFeatureFlags(rawValue: 1 << 7)
    public static let sensorResultHighLowDetection = CGMFeatureFlags(rawValue: 1 << 8)
    public static let lowBatteryDetection = CGMFeatureFlags(rawValue: 1 << 9)
    public static let sensorTypeErrorDetection = CGMFeatureFlags(rawValue: 1 << 10)
    public static let generalDeviceFault = CGMFeatureFlags(rawValue: 1 << 11)
    public static let e2eCRC = CGMFeatureFlags(rawValue: 1 << 12)
    public static let multipleBond = CGMFeatureFlags(rawValue: 1 << 13)
    public static let multipleSessions = CGMFeatureFlags(rawValue: 1 << 14)
    public static let trendInformation = CGMFeatureFlags(rawValue: 1 << 15)
    public static let quality = CGMFeatureFlags(rawValue: 1 << 16)

    /// The field is 24 bits on the wire; bits 17–23 are RFU and shall be 0.
    public static let mask: UInt32 = 0x00FF_FFFF

    /// Little-endian 24-bit encoding.
    public var data: Data {
        Data(rawValue).dropLast(1)
    }
}

/// Low nibble of the Type-Sample Location octet.
public enum CGMType: UInt8, Codable, CaseIterable, Sendable {
    case capillaryWholeBlood = 1
    case capillaryPlasma = 2
    case venousWholeBlood = 3
    case venousPlasma = 4
    case arterialWholeBlood = 5
    case arterialPlasma = 6
    case undeterminedWholeBlood = 7
    case undeterminedPlasma = 8
    case interstitialFluid = 9
    case controlSolution = 10
}

/// High nibble of the Type-Sample Location octet.
public enum CGMSampleLocation: UInt8, Codable, CaseIterable, Sendable {
    case finger = 1
    case alternateSiteTest = 2
    case earlobe = 3
    case controlSolution = 4
    case subcutaneousTissue = 5
    case notAvailable = 15
}

public struct CGMFeature: Equatable, Codable, Sendable {
    public static let encodedSize = 6

    public var flags: CGMFeatureFlags
    public var type: CGMType
    public var sampleLocation: CGMSampleLocation

    public init(flags: CGMFeatureFlags, type: CGMType = .interstitialFluid, sampleLocation: CGMSampleLocation = .subcutaneousTissue) {
        self.flags = flags
        self.type = type
        self.sampleLocation = sampleLocation
    }

    public var isE2ECRCSupported: Bool { flags.contains(.e2eCRC) }

    public var typeSampleLocation: UInt8 {
        sampleLocation.rawValue << 4 | type.rawValue
    }

    /// The CRC field is always present (CGMS §3.2.1.3); 0xFFFF when E2E-CRC is unsupported.
    public func encoded() -> Data {
        var data = flags.data
        data.append(typeSampleLocation)
        if isE2ECRCSupported {
            return data.appendingCRC()
        }
        data.append(UInt16(0xFFFF))
        return data
    }

    public init(data: Data) throws {
        guard data.count == Self.encodedSize else {
            throw CGMCodecError.truncated(expected: Self.encodedSize, actual: data.count)
        }

        var reader = CGMDataReader(data)
        let flagsLow = try reader.read(UInt16.self)
        let flagsHigh = try reader.read(UInt8.self)
        let flags = CGMFeatureFlags(rawValue: UInt32(flagsLow) | UInt32(flagsHigh) << 16)

        let typeSampleLocation = try reader.read(UInt8.self)
        guard let type = CGMType(rawValue: typeSampleLocation & 0x0F) else {
            throw CGMCodecError.invalidValue("CGM Type \(typeSampleLocation & 0x0F)")
        }
        guard let sampleLocation = CGMSampleLocation(rawValue: typeSampleLocation >> 4) else {
            throw CGMCodecError.invalidValue("CGM Sample Location \(typeSampleLocation >> 4)")
        }

        if flags.contains(.e2eCRC), !data.isCRCValid {
            throw CGMCodecError.invalidCRC
        }

        self.init(flags: flags, type: type, sampleLocation: sampleLocation)
    }
}
