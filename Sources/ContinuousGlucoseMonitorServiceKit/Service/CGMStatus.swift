//
//  CGMStatus.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  CGM Status characteristic (CGMS §3.3): Time Offset (UINT16 min), 3-octet Sensor Status Annunciation, [E2E-CRC].

import Foundation
import BluetoothCommonKit

public struct CGMStatus: Equatable, Sendable {
    public static let baseSize = 5

    public var timeOffset: UInt16
    public var sensorStatus: CGMSensorStatusAnnunciation

    public init(timeOffset: UInt16, sensorStatus: CGMSensorStatusAnnunciation) {
        self.timeOffset = timeOffset
        self.sensorStatus = sensorStatus
    }

    public func encoded(e2eCRC: Bool) -> Data {
        var data = Data(timeOffset)
        data.append(sensorStatus.data)
        return e2eCRC ? data.appendingCRC() : data
    }

    public init(data: Data, e2eCRC: Bool) throws {
        let expected = Self.baseSize + (e2eCRC ? CGMMeasurementRecord.crcSize : 0)
        guard data.count == expected else {
            throw CGMCodecError.truncated(expected: expected, actual: data.count)
        }
        if e2eCRC, !data.isCRCValid {
            throw CGMCodecError.invalidCRC
        }

        var reader = CGMDataReader(data)
        let timeOffset = try reader.read(UInt16.self)
        let statusOctet = try reader.read(UInt8.self)
        let calTempOctet = try reader.read(UInt8.self)
        let warningOctet = try reader.read(UInt8.self)

        self.init(
            timeOffset: timeOffset,
            sensorStatus: CGMSensorStatusAnnunciation(statusOctet: statusOctet, calTempOctet: calTempOctet, warningOctet: warningOctet)
        )
    }
}
