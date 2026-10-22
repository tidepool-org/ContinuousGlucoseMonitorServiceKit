//
//  CGMSensorState.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-16.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import CoreBluetooth
import BluetoothCommonKit

/// What a collector keeps about its sensor between launches, mirroring `IDPumpState` in the pump kit: which
/// peripheral to reconnect to, what its Feature said, and the Authorization Control state needed to resume
/// a protected session. `RawRepresentable` as a property list dictionary so a host app can store it as is.
public struct CGMSensorState: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public static let version = 1

    private enum Key: String {
        case identifier
        case name
        case feature
        case isAuthorizationControlRequired
        case uuidStringToHandleMap
        case securityManagerConfiguration
        case lastCommsDate
    }

    /// CoreBluetooth identifier of the sensor to reconnect to; nil until one was chosen.
    public var identifier: UUID?
    public var name: String?
    /// The sensor's CGM Feature. It describes the device rather than the connection, so it is read once per
    /// sensor and kept here; a reconnect uses it as is and only a Feature indication replaces it.
    public var feature: CGMFeature?
    /// When true the service runs the ACS key exchange on connection before reporting ready.
    public var isAuthorizationControlRequired: Bool
    /// Resource handles learned during the key exchange, keyed by characteristic.
    public var uuidToHandleMap: [CBUUID: UInt16]
    public var securityManagerConfiguration: SecurityManager.Configuration
    public var lastCommsDate: Date?

    public var featureFlags: CGMFeatureFlags { feature?.flags ?? [] }

    public init(identifier: UUID? = nil,
                name: String? = nil,
                feature: CGMFeature? = nil,
                isAuthorizationControlRequired: Bool = false,
                uuidToHandleMap: [CBUUID: UInt16] = [:],
                securityManagerConfiguration: SecurityManager.Configuration = SecurityManager.Configuration(),
                lastCommsDate: Date? = nil)
    {
        self.identifier = identifier
        self.name = name
        self.feature = feature
        self.isAuthorizationControlRequired = isAuthorizationControlRequired
        self.uuidToHandleMap = uuidToHandleMap
        self.securityManagerConfiguration = securityManagerConfiguration
        self.lastCommsDate = lastCommsDate
    }

    public init?(rawValue: RawValue) {
        guard let isAuthorizationControlRequired = rawValue[Key.isAuthorizationControlRequired.rawValue] as? Bool,
              let rawSecurityManagerConfiguration = rawValue[Key.securityManagerConfiguration.rawValue] as? SecurityManager.Configuration.RawValue,
              let securityManagerConfiguration = SecurityManager.Configuration(rawValue: rawSecurityManagerConfiguration)
        else {
            return nil
        }
        identifier = (rawValue[Key.identifier.rawValue] as? String).flatMap(UUID.init(uuidString:))
        name = rawValue[Key.name.rawValue] as? String
        // Stored as the characteristic's own encoding; its E2E bit says whether the trailing CRC is live.
        feature = (rawValue[Key.feature.rawValue] as? Data).flatMap { try? CGMFeature(data: $0) }
        self.isAuthorizationControlRequired = isAuthorizationControlRequired
        let uuidStringToHandleMap = rawValue[Key.uuidStringToHandleMap.rawValue] as? [String: UInt16] ?? [:]
        uuidToHandleMap = Dictionary(uniqueKeysWithValues: uuidStringToHandleMap.map { (CBUUID(string: $0.key), $0.value) })
        self.securityManagerConfiguration = securityManagerConfiguration
        lastCommsDate = rawValue[Key.lastCommsDate.rawValue] as? Date
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            Key.isAuthorizationControlRequired.rawValue: isAuthorizationControlRequired,
            Key.uuidStringToHandleMap.rawValue: Dictionary(uniqueKeysWithValues: uuidToHandleMap.map { ($0.key.uuidString, $0.value) }),
            Key.securityManagerConfiguration.rawValue: securityManagerConfiguration.rawValue,
        ]
        raw[Key.identifier.rawValue] = identifier?.uuidString
        raw[Key.name.rawValue] = name
        raw[Key.feature.rawValue] = feature?.encoded()
        raw[Key.lastCommsDate.rawValue] = lastCommsDate
        return raw
    }
}
