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
        self.noiseStandardDeviation = Self.finiteNonNegative(noiseStandardDeviation)
        self.outlierProbability = Self.unit(outlierProbability)
        self.outlierMagnitude = Self.finiteNonNegative(outlierMagnitude)
        self.errorProbability = Self.unit(errorProbability)
        self.seed = seed
    }

    /// False when every setting is inert and readings pass through unchanged.
    public var isActive: Bool {
        Self.finiteNonNegative(noiseStandardDeviation) > 0 || Self.unit(outlierProbability) > 0 || Self.unit(errorProbability) > 0
    }

    /// One reading after the effects; nil when the reading fails. Always consumes the same number of draws
    /// (five), so the position in the stream depends only on how many readings were taken. The settings are
    /// sanitised here as well as in `init`, since the properties and `Decodable` can bypass the initialiser.
    public func apply(to glucose: Double, using generator: inout CGMSeededGenerator) -> Double? {
        let failed = generator.nextUnit() < Self.unit(errorProbability)
        let isOutlier = generator.nextUnit() < Self.unit(outlierProbability)
        let outlierUp = generator.nextUnit() < 0.5
        let noise = generator.nextGaussian() * Self.finiteNonNegative(noiseStandardDeviation)
        if failed { return nil }
        guard glucose.isFinite else { return glucose }
        var value = glucose + noise
        if isOutlier {
            let magnitude = Self.finiteNonNegative(outlierMagnitude)
            value += outlierUp ? magnitude : -magnitude
        }
        return max(0, value)
    }

    /// A probability: NaN and infinities count as 0, everything else is clamped to 0...1.
    private static func unit(_ probability: Double) -> Double {
        probability.isFinite ? min(max(probability, 0), 1) : 0
    }

    /// A magnitude in mg/dL: NaN, infinities and negatives count as 0.
    private static func finiteNonNegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
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
