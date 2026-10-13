//
//  CGMSessionState.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-01.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation

/// Lifecycle of a simulated CGM session. Only `running` produces measurements; anything else sets the
/// "session stopped" bit in the Sensor Status Annunciation (CGMS §3.3.2). Warm-up and failure states
/// arrive with the lifecycle phase.
public enum CGMSessionState: String, Codable, Sendable, CustomStringConvertible {
    /// Powered on, waiting for Start Session from the tester UI or the collector (CGMCP §3.7.2.8).
    case notStarted
    case running
    case stopped

    public var description: String {
        switch self {
        case .notStarted: return "not started"
        case .running: return "running"
        case .stopped: return "stopped"
        }
    }
}

/// Device Information Service values a CGM sensor exposes (CGMP §3.2: Manufacturer Name, Model Number and
/// System ID are mandatory).
public struct CGMDeviceInformation: Equatable, Sendable {
    public var manufacturerName: String
    public var modelNumber: String
    public var serialNumber: String
    public var firmwareRevision: String
    public var hardwareRevision: String
    public var softwareRevision: String

    /// 8 octets: 40-bit manufacturer-defined identifier followed by the 24-bit OUI (GSS System ID).
    public var systemID: Data

    public init(manufacturerName: String,
                modelNumber: String,
                serialNumber: String,
                firmwareRevision: String,
                hardwareRevision: String,
                softwareRevision: String,
                systemID: Data)
    {
        self.manufacturerName = manufacturerName
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.softwareRevision = softwareRevision
        self.systemID = systemID
    }

    public static let simulatorDefault = CGMDeviceInformation(
        manufacturerName: "Tidepool",
        modelNumber: "CGM-SIM",
        serialNumber: "00000001",
        firmwareRevision: "0.1.0",
        hardwareRevision: "1.0",
        softwareRevision: "0.1.0",
        systemID: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0x00])
    )
}
