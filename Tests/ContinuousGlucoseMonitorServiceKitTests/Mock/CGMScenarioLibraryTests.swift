//
//  CGMScenarioLibraryTests.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-08.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation
import Testing
@testable import ContinuousGlucoseMonitorServiceKit

@Suite("CGM scenario library")
struct CGMScenarioLibraryTests {
    /// The two bundled traces: 181 values each, played one per measurement, wrapping at the end.
    @Test func bundledTracesLoad() throws {
        let scenarios = CGMScenarioLibrary.bundled
        #expect(scenarios.map(\.name) == ["Normal Trace", "Tight Trace"])
        for scenario in scenarios {
            #expect(scenario.values.count == 181)
            #expect(scenario.repeats)
            #expect(scenario.sampleInterval == 300)
        }
        let normal = try #require(scenarios.first)
        #expect(normal.value(at: 0) == 141)
        #expect(normal.value(at: 1) == 144)
        #expect(normal.trend(at: 1) == 0.6)   // +3 mg/dL over the recorded 5 min
        #expect(normal.value(at: 180) == 134)
        #expect(normal.value(at: 181) == 141)   // wrapped to the first value
        let tight = try #require(scenarios.last)
        #expect(tight.value(at: 0) == 103)
        #expect(tight.values.min() == 84)
        #expect(tight.values.max() == 119)
    }

    @Test func toleratesTrailingCommaAndTraceFormat() throws {
        let data = Data(#"{"glucoseValues": [{"mgdlValue":100,"dateOffset":0}, {"mgdlValue":110,"dateOffset":60},]}"#.utf8)
        let scenario = try CGMScenarioLibrary.scenario(from: data, fileName: "CGMScenario-flat.json")
        #expect(scenario.name == "Flat Trace")
        #expect(scenario.values == [100, 110])
        #expect(scenario.repeats)
        #expect(scenario.sampleInterval == 60)   // taken from the offsets
    }

    /// A malformed kit-form file reports its own decoding error, not a missing trace-form key.
    @Test func kitFormErrorsAreNotMaskedByTraceForm() {
        let data = Data(#"{"name":"Ramp","values":[90,"95"]}"#.utf8)
        #expect {
            try CGMScenarioLibrary.scenario(from: data, fileName: "CGMScenario-ramp.json")
        } throws: { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return false }
            return context.codingPath.map(\.stringValue) == ["values", "Index 1"]
        }

        #expect(throws: CGMScenarioLibraryError.unrecognizedShape("CGMScenario-x.json")) {
            try CGMScenarioLibrary.scenario(from: Data(#"{"foo":1}"#.utf8), fileName: "CGMScenario-x.json")
        }
        #expect(throws: CGMScenarioLibraryError.unrecognizedShape("CGMScenario-x.json")) {
            try CGMScenarioLibrary.scenario(from: Data(#"[1,2]"#.utf8), fileName: "CGMScenario-x.json")
        }
    }

    /// Dangling commas are removed only outside string literals.
    @Test func trailingCommaStrippingLeavesStringsAlone() throws {
        let data = Data(#"{"name": "Meals, [lunch,] \" ,}", "values": [1, 2,], }"#.utf8)
        let scenario = try CGMScenarioLibrary.scenario(from: data, fileName: "CGMScenario-meals.json")
        #expect(scenario.name == #"Meals, [lunch,] " ,}"#)
        #expect(scenario.values == [1, 2])
        #expect(CGMScenarioLibrary.stripTrailingCommas(Data("[1,\n  2 ,\n]".utf8)) == Data("[1,\n  2 \n]".utf8))
    }

    @Test func acceptsKitFormatToo() throws {
        let data = Data(#"{"name":"Ramp","repeats":false,"values":[90,95]}"#.utf8)
        let scenario = try CGMScenarioLibrary.scenario(from: data, fileName: "CGMScenario-ramp.json")
        #expect(scenario.name == "Ramp")
        #expect(scenario.values == [90, 95])
        #expect(!scenario.repeats)
    }
}
