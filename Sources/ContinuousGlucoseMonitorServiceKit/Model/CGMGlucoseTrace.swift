//
//  CGMGlucoseTrace.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-07.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation

/// A scripted glucose trace (HYD-C-017): an ordered list of mg/dL values. Each measurement takes the next
/// value regardless of wall-clock time, so the trace plays at whatever cadence the tester picks. At the end
/// it either starts over or holds the final value.
public struct CGMGlucoseScenario: Equatable, Codable, Sendable {
    /// Spacing the values were recorded at; a faster measurement interval only speeds playback.
    public static let defaultSampleInterval: TimeInterval = 5 * 60

    public var name: String
    public var values: [Double]
    public var repeats: Bool
    /// Seconds between consecutive values as recorded. Trend is derived from this, not from the measurement
    /// interval, so a 5 s playback reports the same rates as a 5 min one.
    public var sampleInterval: TimeInterval

    public init(name: String, values: [Double], repeats: Bool = true, sampleInterval: TimeInterval = CGMGlucoseScenario.defaultSampleInterval) {
        self.name = name
        self.values = values
        self.repeats = repeats
        self.sampleInterval = sampleInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        values = try container.decode([Double].self, forKey: .values)
        repeats = try container.decodeIfPresent(Bool.self, forKey: .repeats) ?? true
        sampleInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .sampleInterval) ?? Self.defaultSampleInterval
    }

    /// Value for the `index`-th measurement of a session (0-based), honouring `repeats`.
    public func value(at index: Int) -> Double {
        guard !values.isEmpty, index >= 0 else { return .nan }
        if index < values.count { return values[index] }
        return repeats ? values[index % values.count] : values[values.count - 1]
    }

    /// (mg/dL)/min from the previous value to the `index`-th one over `sampleInterval`; the first value of a
    /// session has no slope.
    public func trend(at index: Int) -> Double {
        guard index > 0, sampleInterval > 0 else { return 0 }
        return (value(at: index) - value(at: index - 1)) / (sampleInterval / 60)
    }
}

/// Deterministic glucose source for the simulated sensor.
public enum CGMGlucoseTrace: Equatable, Sendable {
    case constant(mgdl: Double)
    /// `base` is also the value at session start, since the curve begins at sin(0).
    case sineCurve(base: Double, amplitude: Double, period: TimeInterval)
    /// Steps through its values one measurement at a time.
    case scenario(CGMGlucoseScenario)

    /// 120 ± 40 mg/dL over a six-hour cycle.
    public static let simulatorDefault = CGMGlucoseTrace.sineCurve(base: 120, amplitude: 40, period: 6 * 60 * 60)

    /// mg/dL for the `index`-th measurement taken `elapsed` seconds into the session. Time-driven traces
    /// use `elapsed`; scripted scenarios use `index`.
    public func glucose(elapsed: TimeInterval, index: Int) -> Double {
        switch self {
        case .constant(let mgdl):
            return mgdl
        case let .sineCurve(base, amplitude, period):
            return base + amplitude * sin(2 * .pi * elapsed / period)
        case .scenario(let scenario):
            return scenario.value(at: index)
        }
    }

    /// Rate of change in (mg/dL)/min. Scripted scenarios use their recorded sample spacing, so playback speed
    /// does not change the reported trend.
    public func trend(elapsed: TimeInterval, index: Int) -> Double {
        switch self {
        case .constant:
            return 0
        case let .sineCurve(_, amplitude, period):
            let perSecond = amplitude * 2 * .pi / period * cos(2 * .pi * elapsed / period)
            return perSecond * 60
        case .scenario(let scenario):
            return scenario.trend(at: index)
        }
    }
}
