//
//  ContinuousGlucoseMonitorServiceConfiguration.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-16.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import CoreBluetooth
import BluetoothCommonKit

extension PeripheralManager.Configuration {
    /// What a collector discovers and subscribes to once connected: every CGMS characteristic (CGMS §3.1),
    /// Device Information and Battery (mandatory alongside CGMS in the HYDRA design), and Authorization Control
    /// when the sensor offers it. BluetoothCommonKit subscribes to the notifying characteristics as part of
    /// configuration, so measurements and control point indications flow without a separate step. A
    /// measurement may therefore arrive before the Feature is read on a first connection; the service reads
    /// the Feature as soon as the link is up and keeps it per sensor, so this only happens once. Services
    /// listed under `notifyingCharacteristics` must exist on the peripheral, so a real sensor without ACS is
    /// connected with `includingAuthorizationControl: false`.
    public static func continuousGlucoseMonitorServiceConfiguration(includingAuthorizationControl: Bool = true) -> PeripheralManager.Configuration {
        var serviceCharacteristics: [CBUUID: [CBUUID]] = [
            CGMCharacteristicUUID.service.cbUUID: CGMCharacteristicUUID.allCases.filter { $0 != .service }.map(\.cbUUID),
            DeviceInfoCharacteristicUUID.service.cbUUID: [
                DeviceInfoCharacteristicUUID.manufacturerNameString.cbUUID,
                DeviceInfoCharacteristicUUID.modelNumberString.cbUUID,
                DeviceInfoCharacteristicUUID.serialNumberString.cbUUID,
                DeviceInfoCharacteristicUUID.systemID.cbUUID,
                DeviceInfoCharacteristicUUID.firmwareRevisionString.cbUUID,
                DeviceInfoCharacteristicUUID.hardwareRevisionString.cbUUID,
                DeviceInfoCharacteristicUUID.softwareRevisionString.cbUUID,
            ],
            BatteryCharacteristicUUID.service.cbUUID: [BatteryCharacteristicUUID.batteryLevel.cbUUID],
        ]
        var notifyingCharacteristics: [CBUUID: [CBUUID]] = [
            CGMCharacteristicUUID.service.cbUUID: [
                CGMCharacteristicUUID.measurement.cbUUID,
                CGMCharacteristicUUID.feature.cbUUID,
                CGMCharacteristicUUID.recordAccessControlPoint.cbUUID,
                CGMCharacteristicUUID.specificOpsControlPoint.cbUUID,
            ],
        ]
        if includingAuthorizationControl {
            serviceCharacteristics[ACCharacteristicUUID.service.cbUUID] = [
                ACCharacteristicUUID.status.cbUUID,
                ACCharacteristicUUID.controlPoint.cbUUID,
                ACCharacteristicUUID.dataIn.cbUUID,
                ACCharacteristicUUID.dataOutNotify.cbUUID,
                ACCharacteristicUUID.dataOutIndicate.cbUUID,
            ]
            notifyingCharacteristics[ACCharacteristicUUID.service.cbUUID] = [
                ACCharacteristicUUID.status.cbUUID,
                ACCharacteristicUUID.controlPoint.cbUUID,
                ACCharacteristicUUID.dataOutNotify.cbUUID,
                ACCharacteristicUUID.dataOutIndicate.cbUUID,
            ]
        }
        return PeripheralManager.Configuration(serviceCharacteristics: serviceCharacteristics,
                                               notifyingCharacteristics: notifyingCharacteristics,
                                               valueUpdateMacros: [:])
    }

    public static var continuousGlucoseMonitorServiceConfiguration: PeripheralManager.Configuration {
        continuousGlucoseMonitorServiceConfiguration()
    }
}
