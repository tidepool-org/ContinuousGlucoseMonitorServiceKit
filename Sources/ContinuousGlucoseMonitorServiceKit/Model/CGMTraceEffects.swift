//
//  CGMTraceEffects.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-15.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation

/// Perturbations layered on any glucose source (CGM-DESIGN §Glucose trace): gaussian noise, occasional
/// outliers, and a chance of a reading failing outright. Every draw comes from a generator seeded from
/// `seed` and re-seeded at Start Session, so a session replays identically (HYD-C-018).
public struct CGMTraceEffects: Equatable, Codable, Sendable {
    /// Standard deviation of the noise added to every reading, mg/dL. 0 = none.
    public var noiseStandardDeviation: Double
    /// Chance (0...1) that a reading is pushed by `outlierMagnitude`, up or down at random.
    public var outlierProbability: Double
    /// Size of an outlier, mg/dL.
    public var outlierMagnitude: Double
    /// Chance (0...1) that a reading fails: NaN glucose and zero quality, as a sensor reports a bad sample.
    public var errorProbability: Double
    /// Generator seed; the same seed and settings reproduce the same perturbations.
    public var seed: UInt64

    public static let none = CGMTraceEffects()

    public init(noiseStandardDeviation: Double = 0,
                outlierProbability: Double = 0,
                outlierMagnitude: Double = 60,
                errorProbability: Double = 0,
                seed: UInt64 = 1)
    {
        self.noiseStandardDeviation = max(0, noiseStandardDeviation)
        self.outlierProbability = min(max(0, outlierProbability), 1)
        self.outlierMagnitude = outlierMagnitude
        self.errorProbability = min(max(0, errorProbability), 1)
        self.seed = seed
    }

    /// False when every setting is inert and readings pass through unchanged.
    public var isActive: Bool {
        noiseStandardDeviation > 0 || outlierProbability > 0 || errorProbability > 0
    }

    /// One reading after the effects; nil when the reading fails. Always consumes the same number of draws
    /// (five), so the position in the stream depends only on how many readings were taken.
    public func apply(to glucose: Double, using generator: inout CGMSeededGenerator) -> Double? {
        let failed = generator.nextUnit() < errorProbability
        let isOutlier = generator.nextUnit() < outlierProbability
        let outlierUp = generator.nextUnit() < 0.5
        let noise = generator.nextGaussian() * noiseStandardDeviation
        if failed || !glucose.isFinite { return failed ? nil : glucose }
        var value = glucose + noise
        if isOutlier { value += outlierUp ? outlierMagnitude : -outlierMagnitude }
        return max(0, value)
    }
}

/// SplitMix64: a small, fast generator whose whole state is one seed, so a replay needs nothing but that
/// number. Not for cryptography.
public struct CGMSeededGenerator: RandomNumberGenerator, Equatable, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Standard normal via Box–Muller; two uniform draws.
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUnit(), .leastNonzeroMagnitude)
        let u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
