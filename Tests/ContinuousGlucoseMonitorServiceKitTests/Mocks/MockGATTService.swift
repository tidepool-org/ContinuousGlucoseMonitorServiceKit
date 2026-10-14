//
//  MockGATTService.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-01.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import CoreBluetooth
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

/// Records service construction and lets a test flip CCCD state without CoreBluetooth.
final class MockGATTService: GATTService {
    var delegate: GATTServiceDelegate?
    var observers: GATTServiceObservers?

    private(set) var services: [(uuid: CBUUID, primary: Bool, characteristics: [CallbackCharacteristic])] = []
    private(set) var updates: [(data: Data?, uuid: CBUUID)] = []
    private(set) var addServiceCount = 0
    private(set) var startAdvertisingCount = 0
    var subscribed: Set<CBUUID> = []

    func preWriteConstrain(_ preWriteConstrain: @escaping ([CallbackCharacteristic]) -> CBATTError.Code) { }

    func createService(_ serviceUUID: CBUUID, primary: Bool, withCharacteristics characteristics: [CallbackCharacteristic]) {
        services.append((serviceUUID, primary, characteristics))
    }

    func addService() {
        addServiceCount += 1
    }

    func update(_ data: Data?, forUUID: CBUUID, onSubscribedCentrals: [CBCentral]?) {
        updates.append((data, forUUID))
    }

    func startAdvertising(advertisementDataHandler: @escaping () -> [String: Any]?) {
        startAdvertisingCount += 1
    }

    func isCharacteristicSubscribed(_ forUUID: CBUUID) -> Bool? {
        subscribed.contains(forUUID)
    }

    func characteristic(_ uuid: CGMCharacteristicUUID) -> CallbackCharacteristic? {
        characteristic(uuid.cbUUID)
    }

    func characteristic(_ uuid: CBUUID) -> CallbackCharacteristic? {
        services.flatMap(\.characteristics).first { $0.uuid == uuid }
    }
}

/// Captures queued indications/notifications instead of sending them.
final class MockMessageQueue: MessagingQueue {
    var gattServer: GATTService!
    private(set) var items: [UUIDValuePair] = []

    init(gattServer: GATTService) {
        self.gattServer = gattServer
    }

    var hasMessagesInQueue: Bool { !items.isEmpty }

    func addQueueItem(_ update: UUIDValuePair) {
        items.append(update)
    }

    func emptyQueue() {
        items.removeAll()
    }

    /// Drops only the items for one characteristic, leaving the rest for later assertions.
    func removeItems(for uuid: CBUUID) {
        items.removeAll { $0.uuid == uuid }
    }
}
