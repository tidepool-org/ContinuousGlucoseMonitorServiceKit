//
//  CGMTraceEffectsTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-15.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import Testing
import BluetoothCommonKit
@testable import ContinuousGlucoseMonitorServiceKit

@Suite("CGM trace effects")
struct CGMTraceEffectsTests {
    @Test func generatorIsDeterministicAndUniform() {
        var a = CGMSeededGenerator(seed: 42)
        var b = CGMSeededGenerator(seed: 42)
        let fromA = (0..<8).map { _ in a.next() }
        let fromB = (0..<8).map { _ in b.next() }
        #expect(fromA == fromB)
        #expect(Set(fromA).count == 8)

        var c = CGMSeededGenerator(seed: 7)
        let units = (0..<2000).map { _ in c.nextUnit() }
        #expect(units.allSatisfy { $0 >= 0 && $0 < 1 })
        let mean = units.reduce(0, +) / Double(units.count)
        #expect(abs(mean - 0.5) < 0.03)
    }

    @Test func inertEffectsPassReadingsThrough() {
        var generator = CGMSeededGenerator(seed: 1)
        #expect(!CGMTraceEffects.none.isActive)
        #expect(CGMTraceEffects.none.apply(to: 120, using: &generator) == 120)
        // Even inert effects consume their five draws, so the stream position tracks the reading count.
        var untouched = CGMSeededGenerator(seed: 1)
        for _ in 0..<5 { _ = untouched.next() }
        #expect(generator == untouched)
    }

    @Test func noiseHasTheRequestedSpread() {
        let effects = CGMTraceEffects(noiseStandardDeviation: 10, seed: 3)
        var generator = CGMSeededGenerator(seed: effects.seed)
        let samples = (0..<2000).compactMap { _ in effects.apply(to: 120, using: &generator) }
        #expect(samples.count == 2000)
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
        #expect(abs(mean - 120) < 1)
        #expect(variance.squareRoot() > 9 && variance.squareRoot() < 11)
    }

    @Test func outliersAndFailuresFollowTheirProbabilities() {
        let always = CGMTraceEffects(outlierProbability: 1, outlierMagnitude: 60, seed: 5)
        var generator = CGMSeededGenerator(seed: always.seed)
        let shifted = (0..<50).compactMap { _ in always.apply(to: 120, using: &generator) }
        #expect(shifted.allSatisfy { abs($0 - 120) == 60 })
        #expect(shifted.contains(180) && shifted.contains(60))   // both directions over 50 draws

        let failing = CGMTraceEffects(errorProbability: 1)
        #expect(failing.apply(to: 120, using: &generator) == nil)

        // Nothing goes below zero however large the noise.
        let wild = CGMTraceEffects(noiseStandardDeviation: 1000, seed: 9)
        var wildGenerator = CGMSeededGenerator(seed: wild.seed)
        #expect((0..<200).compactMap { _ in wild.apply(to: 50, using: &wildGenerator) }.allSatisfy { $0 >= 0 })
    }

    @Test func probabilitiesAreClampedToUnitRange() {
        let effects = CGMTraceEffects(noiseStandardDeviation: -5, outlierProbability: 7, errorProbability: -1)
        #expect(effects.noiseStandardDeviation == 0)
        #expect(effects.outlierProbability == 1)
        #expect(effects.errorProbability == 0)
    }

    // MARK: On the sensor

    private func makeSensor() -> (MockCGMSensor, MockMessageQueue) {
        let server = MockGATTService()
        let queue = MockMessageQueue(gattServer: server)
        let sensor = MockCGMSensor(gattServer: server, messageQueue: queue)
        sensor.trace = .constant(mgdl: 120)
        return (sensor, queue)
    }

    /// Two sensors with the same seed produce the same readings, and a new session replays them.
    @Test func sessionsReplayIdenticallyFromTheSeed() throws {
        let effects = CGMTraceEffects(noiseStandardDeviation: 15, outlierProbability: 0.2, seed: 11)
        let (first, _) = makeSensor()
        let (second, _) = makeSensor()
        first.traceEffects = effects
        second.traceEffects = effects
        first.startSession()
        second.startSession()
        let fromFirst = (0..<6).map { _ in first.takeMeasurement()?.glucoseConcentration }
        let fromSecond = (0..<6).map { _ in second.takeMeasurement()?.glucoseConcentration }
        #expect(fromFirst == fromSecond)
        #expect(Set(fromFirst.compactMap { $0 }).count > 1)   // the noise did something

        first.startSession()
        let replayed = (0..<6).map { _ in first.takeMeasurement()?.glucoseConcentration }
        #expect(replayed == fromFirst)

        // A different seed is a different session.
        second.traceEffects.seed = 12
        second.startSession()
        #expect((0..<6).map { _ in second.takeMeasurement()?.glucoseConcentration } != fromFirst)
    }

    /// A failed sample is a record without a value or confidence, and no fault bit.
    @Test func failedSampleIsReportedWithoutAValueOrAFaultBit() throws {
        let (sensor, _) = makeSensor()
        sensor.traceEffects = CGMTraceEffects(errorProbability: 1)
        sensor.startSession()
        let record = try #require(sensor.takeMeasurement())
        #expect(record.glucoseConcentration.isNaN)
        #expect(record.trend == nil)
        #expect(record.quality == 0)
        #expect(record.sensorStatus.isDisjoint(with: [.generalDeviceFault, .sensorMalfunction]))
        #expect(sensor.alertStatus == [])

        sensor.traceEffects = .none
        #expect(sensor.takeMeasurement()?.glucoseConcentration == 120)
    }
}
