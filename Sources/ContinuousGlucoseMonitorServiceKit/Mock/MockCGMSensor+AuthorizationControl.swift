//
//  MockCGMSensor+AuthorizationControl.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-13.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Authorization Control Service (ACS) for the simulated sensor, mirroring MockInsulinDeliveryPump: the
//  collector runs the ECDH key exchange over the AC Control Point, after which the CGMS characteristics are
//  protected resources reached through AC Data In / AC Data Out by resource handle. The descriptor payloads
//  below are the same ones the mock pump serves; they describe one restriction map, one security
//  configuration (nonce + MAC + authenticated encryption) and the ECDH / AES-GCM key pair.

import Foundation
import CoreBluetooth
import BluetoothCommonKit

/// Resource handles the sensor publishes for its protected CGMS characteristics (ACS Resource Handle to
/// UUID Map). The service itself takes handle 1; characteristics follow in CGMS Table 3.1 order.
public enum CGMResourceHandle {
    public static let service: ResourceHandle = 1

    private static let characteristics: [(uuid: CGMCharacteristicUUID, handle: ResourceHandle)] = [
        (.measurement, 2),
        (.feature, 3),
        (.status, 4),
        (.sessionStartTime, 5),
        (.sessionRunTime, 6),
        (.recordAccessControlPoint, 7),
        (.specificOpsControlPoint, 8)
    ]

    public static func handle(for uuid: CGMCharacteristicUUID) -> ResourceHandle {
        characteristics.first { $0.uuid == uuid }?.handle ?? service
    }

    public static func characteristic(for handle: ResourceHandle) -> CGMCharacteristicUUID? {
        characteristics.first { $0.handle == handle }?.uuid
    }

    /// Shape the AC Control Point expects: one dictionary per service, the service UUID first.
    static var map: [[CBUUID: ResourceHandle]] {
        var entry: [CBUUID: ResourceHandle] = [CGMCharacteristicUUID.service.cbUUID: service]
        for (uuid, handle) in characteristics {
            entry[uuid.cbUUID] = handle
        }
        return [entry]
    }
}

// MARK: - AC Control Point delegate

extension MockCGMSensor: ACControlPointDelegate {
    static let restrictionMapID: RestrictionMapID = 1
    static let securityConfigurationID: SecurityConfigurationID = 1
    /// Fixed part of the AES-GCM nonce this sensor encrypts with; published in the key descriptor.
    static let fixedIVField = Data(bigEndian: UInt32(0xcafeaffe))

    public var ecdhKeyID: KeyID { securityManager.configuration.ecdhKeyID }

    public var algorithmKeyID: KeyID { securityManager.configuration.algorithmKeyID }

    public var currentKeyID: KeyID? {
        isSecurityEstablished ? ecdhKeyID : nil
    }

    public func getAuthorizationFeatures() -> Data {
        let qualityOfProtection: QualityOfProtection = [.confidentiality, .integrity, .authentication]
        let flags: FeaturesFlag = [
            .descriptorsSupported, .resourceHandleToUUIDMapSupported, .initiatePairingSupported,
            .keyExchangeECDHSupported, .keyExchangeKDFSupported, .invalidateEstablishedSecuritySupported,
            .protectedResourceWriteSupported, .protectedResourceReadSupported,
            .protectedResourceNotificationSupported, .protectedResourceIndicationSupported,
            .keyFormatServerUncompressedPlainSupported, .keyFormatClientUncompressedPlainSupported
        ]
        let oobKeyExchangeCapabilities: OOBCapability = [.string, .onPaper]
        let confirmationStaticOOBNumberCapabilities: OOBCapability = [.string, .onPaper]
        let confirmationInputNumberMaxValue: UInt32 = 0
        let confirmationInputCapabilities: ConfirmationInputCapability = []
        let confirmationOutputNumberMaxValue: UInt32 = 1000
        let confirmationOutputCapabilities: ConfirmationOutputCapability = [.outputNumeric]

        var features = Data(flags.rawValue)
        features.append(qualityOfProtection.rawValue)
        features.append(oobKeyExchangeCapabilities.rawValue)
        features.append(confirmationStaticOOBNumberCapabilities.rawValue)
        features.append(confirmationInputNumberMaxValue)
        features.append(confirmationInputCapabilities.rawValue)
        features.append(confirmationOutputNumberMaxValue)
        features.append(confirmationOutputCapabilities.rawValue)
        return features
    }

    public func getRestrictionMap(for restrictionMapID: RestrictionMapID, handleFilter: ResourceHandle) -> Data {
        let dataSizeZero: UInt8 = 0

        var restrictionMap = Data(RecordTypeRestrictionMap.restrictionMapID.rawValue)
        restrictionMap.append(restrictionMapID)
        restrictionMap.append(dataSizeZero)

        restrictionMap.append(RecordTypeRestrictionMap.defaultInformationSecurityConfiguration.rawValue)
        restrictionMap.append(Self.securityConfigurationID)
        restrictionMap.append(dataSizeZero)
        return restrictionMap
    }

    public func getRestrictionMapIDList() -> Data {
        var list = Data(Self.restrictionMapID)
        list.append(Self.securityConfigurationID)
        return list
    }

    public func resourceHandleToUUIDMap() -> [[CBUUID: ResourceHandle]] {
        CGMResourceHandle.map
    }

    public func getInformationSecurityConfiguration(filter: SecurityConfigurationID) -> Data {
        let dataSize: UInt8 = 6
        let numberOfControls: UInt8 = 3

        var configuration = Data(RecordTypeSecurityConfiguration.informationSecurityConfigurationID.rawValue)
        configuration.append(Self.securityConfigurationID)
        configuration.append(dataSize)
        configuration.append(numberOfControls)
        configuration.append(SecurityControlType.nonce.rawValue)
        configuration.append(SecurityControlType.mac.rawValue)
        configuration.append(SecurityControlType.authenticatedEncryptedATTPacket.rawValue)
        configuration.append(ecdhKeyID)
        return configuration
    }

    public func getKeyDescriptor(filter: KeyID) -> Data {
        // ECDH record
        let ecdhRecordDataSize: UInt8 = 4
        var descriptor = Data(KeyType.ecdh.rawValue)
        descriptor.append(ecdhKeyID)
        descriptor.append(ecdhRecordDataSize)
        descriptor.append(KeyFormat.plain.rawValue)
        descriptor.append(KeyFormat.plain.rawValue)
        descriptor.append(EllipticCurve.p256.rawValue)
        descriptor.append(KeyDerivationFunction.hkdfSHA256.rawValue)

        // AES-GCM record; reports the fixed IV field configured at init (a getter must not mutate state).
        let ivFixedField = securityManager.configuration.generatedIVFixedField ?? Self.fixedIVField
        let ivFixedFieldLittleEndian = Data(ivFixedField.reversed())
        let gcmRecordDataSize: UInt8 = 11
        let gcmRecordMACSize: UInt8 = 8
        let gcmRecordNonceSizeVariable: UInt8 = 8
        let gcmRecordNonceSizeFixed = UInt8(ivFixedField.count)
        let gcmRecordIVFixedField: UInt32 = ivFixedFieldLittleEndian[ivFixedFieldLittleEndian.startIndex...].to(UInt32.self)

        descriptor.append(KeyType.aesGCM.rawValue)
        descriptor.append(algorithmKeyID)
        descriptor.append(gcmRecordDataSize)
        descriptor.append(ecdhKeyID)
        descriptor.append(MessageType.protectedResourceValue.rawValue)
        descriptor.append(gcmRecordMACSize)
        descriptor.append(NonceType.sequenceNumberDifferentFixedParts.rawValue)
        descriptor.append(gcmRecordNonceSizeVariable)
        descriptor.append(gcmRecordNonceSizeFixed)
        descriptor.append(gcmRecordIVFixedField)
        return descriptor
    }

    public func invalidateKey() {
        // Drops the key and resets the nonce sequence, matching the client's deleteStoredKey().
        securityManager.prepareForDeactivation()
        setSecurityEstablished(false)
    }
}

// MARK: - AC Data delegate (protected resource access)

extension MockCGMSensor: ACDataCharacteristicDelegate {
    /// A decrypted request addressed to a resource handle. An empty payload reads the characteristic; a
    /// payload writes it. Values come back as secure indications; control point responses travel through
    /// `indicate`. The returned code is the ATT response to the AC Data In write, so refusals and write
    /// errors reach the collector exactly as they would on the plain characteristic.
    public func processRequest(_ request: Data, for resourceHandle: ResourceHandle) -> CBATTError.Code {
        guard let uuid = CGMResourceHandle.characteristic(for: resourceHandle) else {
            ConsoleOut.shared.logMessage(message: "\(#function): unknown resource handle \(resourceHandle)")
            return .attributeNotFound
        }
        ConsoleOut.shared.logMessage(message: "\(#function) \(uuid.name): \(request.hexadecimalString)")

        let value: Data
        switch uuid {
        case .feature, .status, .sessionRunTime:
            guard request.isEmpty else { return .writeNotPermitted }
            switch uuid {
            case .feature: value = readFeature().1
            case .status: value = readStatus().1
            default: value = readSessionRunTime().1
            }
        case .sessionStartTime:
            if !request.isEmpty {
                let code = writeSessionStartTime(request)
                guard code == .success else { return code }
            }
            value = readSessionStartTime().1
        case .recordAccessControlPoint:
            guard !request.isEmpty else { return .readNotPermitted }
            return writeRecordAccessControlPoint(request)
        case .specificOpsControlPoint:
            guard !request.isEmpty else { return .readNotPermitted }
            return writeSpecificOpsControlPoint(request)
        case .measurement:
            // Notify-only: values arrive on AC Data Out Notify as they are taken.
            return request.isEmpty ? .readNotPermitted : .writeNotPermitted
        case .service:
            return .attributeNotFound
        }

        authorizationDataCharacteristic.sendSecureIndication(value, to: resourceHandle)
        return .success
    }
}

// MARK: - Security manager delegate

extension MockCGMSensor: SecurityManagerDelegate {
    /// Called by the AC Control Point once the collector's confirmation random number validates, i.e. the
    /// OOB numbers matched; a failed confirmation discards the shared secret instead.
    public func securityManagerDidEstablishedSecurity(_ securityManager: SecurityManager) {
        setSecurityEstablished(true)
    }

    public func securityManagerDidUpdateConfiguration(_ securityManager: SecurityManager) {
        // Nothing to persist yet; session state is in-memory until the persistence phase.
    }

    /// Updates AC Status (indicated when subscribed) and observers; no-op when unchanged.
    private func setSecurityEstablished(_ established: Bool) {
        guard authorizationStatusCharacteristic.isSecurityEstablished != established else { return }
        authorizationStatusCharacteristic.isSecurityEstablished = established
        authorizationStatusCharacteristic.triggerIndication()
        ConsoleOut.shared.logMessage(message: "secure session \(established ? "established" : "invalidated")")
        notifyDelegate()
    }
}
