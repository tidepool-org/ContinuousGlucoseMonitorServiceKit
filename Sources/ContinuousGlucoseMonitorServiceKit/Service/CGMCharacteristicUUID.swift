//
//  CGMCharacteristicUUID.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-09-28.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  This is based on version 1.0.2 of the Continuous Glucose Monitoring Service: https://www.bluetooth.com/specifications/specs/continuous-glucose-monitoring-service-1-0-2/
//  Table 3.1 lists the characteristics and their properties.

import CoreBluetooth
import BluetoothCommonKit

public enum CGMCharacteristicUUID: String, CaseIterable, CBUUIDDetails, Sendable {
    case service = "181f"

    // Notify
    case measurement = "2aa7"

    // Read (Indicate when features can change during the sensor lifetime, CGMS §3.2.1)
    case feature = "2aa8"

    // Read
    case status = "2aa9"

    // Read, Write
    case sessionStartTime = "2aaa"

    // Read
    case sessionRunTime = "2aab"

    // Write, Indicate (shared with the Glucose Service; no E2E-CRC, CGMS §3.6)
    case recordAccessControlPoint = "2a52"

    // Write, Indicate
    case specificOpsControlPoint = "2aac"

    private static let serviceName = "cgm"

    public var name: String {
        switch self {
        case .service: return Self.serviceName
        case .measurement: return Self.serviceName + ".measurement"
        case .feature: return Self.serviceName + ".feature"
        case .status: return Self.serviceName + ".status"
        case .sessionStartTime: return Self.serviceName + ".sessionStartTime"
        case .sessionRunTime: return Self.serviceName + ".sessionRunTime"
        case .recordAccessControlPoint: return Self.serviceName + ".recordAccessControlPoint"
        case .specificOpsControlPoint: return Self.serviceName + ".specificOpsControlPoint"
        }
    }

    public var properties: [CBUUIDProperties] {
        switch self {
        case .service:
            return []
        case .measurement:
            return [.notify]
        case .feature:
            return [.read, .indicate]
        case .status, .sessionRunTime:
            return [.read]
        case .sessionStartTime:
            return [.read, .write]
        case .recordAccessControlPoint, .specificOpsControlPoint:
            return [.write, .indicate]
        }
    }
}

extension CBPeripheral {
    public func getCGMCharacteristicWithUUID(_ uuid: CGMCharacteristicUUID, serviceUUID: CGMCharacteristicUUID = .service) -> CBCharacteristic? {
        guard let service = services?.itemWithUUID(serviceUUID.cbUUID) else {
            return nil
        }
        return service.characteristics?.itemWithUUID(uuid.cbUUID)
    }
}

/// ATT application error codes defined by CGMS §1.8, returned on control point writes when E2E-CRC is supported.
public enum CGMApplicationErrorCode: UInt8, Sendable {
    case missingCRC = 0x80
    case invalidCRC = 0x81
}
