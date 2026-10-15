//
//  CGMSensorLifecycle.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-14.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Sensor lifecycle beyond the CGMS session state (CGM-DESIGN §Lifecycle): the physical condition a tester
//  can inflict on the simulated sensor, and the history of lifecycle actions a controller test needs.

import Foundation

/// Physical condition of the simulated sensor, independent of whether a session is running.
public enum CGMSensorCondition: String, Codable, Sendable, CustomStringConvertible {
    case healthy
    /// Temporary issue (TBD-05): readings carry NaN glucose, zero quality and the General Device Fault
    /// bit until the tester resolves it.
    case impaired
    /// Sensor failure (HYD-G-006): no readings and the Sensor Malfunction bit; terminal until the sensor is
    /// replaced from the tester UI.
    case failed

    public var description: String {
        switch self {
        case .healthy: return "healthy"
        case .impaired: return "temporary issue"
        case .failed: return "failed"
        }
    }
}

/// One lifecycle action and how the sensor took it (TBD-07/08 ask for a historical record of replacement
/// and STOP including connection state, timestamp and acceptance).
public struct CGMLifecycleEvent: Equatable, Sendable, Identifiable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case sessionStarted
        case sessionStopped
        case sessionExpired
        case sensorReplaced
        case sensorFailed
        case temporaryIssueBegan
        case temporaryIssueResolved
    }

    public enum Source: String, Sendable {
        /// The HYDRA UI.
        case tester
        /// A CGMCP procedure from the collector.
        case collector
        /// The sensor itself, e.g. the session run time elapsing.
        case sensor
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let source: Source
    public let accepted: Bool
    /// Whether a collector was subscribed to measurements at the time.
    public let collectorSubscribed: Bool
    public let timeOffset: UInt16
    public let note: String?

    public init(date: Date, kind: Kind, source: Source, accepted: Bool, collectorSubscribed: Bool, timeOffset: UInt16, note: String? = nil) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.source = source
        self.accepted = accepted
        self.collectorSubscribed = collectorSubscribed
        self.timeOffset = timeOffset
        self.note = note
    }

    public var description: String {
        let outcome = accepted ? "" : " (rejected)"
        let link = collectorSubscribed ? "collector subscribed" : "no collector"
        let detail = note.map { ", \($0)" } ?? ""
        return "\(date.formatted(date: .omitted, time: .standard)) \(kind.rawValue) by \(source.rawValue)\(outcome) at offset \(timeOffset) min, \(link)\(detail)"
    }
}
