//
//  CGMRecordStore.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-13.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation

/// The sensor's measurement database (CGMS §3.6.1: a record is a CGM Measurement value). Records are kept
/// oldest first; when full, the oldest is dropped. Time Offset is the only RACP filter key (Table 3.5).
public struct CGMRecordStore: Equatable, Sendable {
    /// 10 days at 5 minutes; CGMS §3.9 only asks for "several hundred".
    public static let defaultCapacity = 2880

    public var capacity: Int {
        didSet {
            capacity = max(1, capacity)
            trim()
        }
    }

    public private(set) var records: [CGMMeasurementRecord] = []

    public init(capacity: Int = CGMRecordStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }
    public var first: CGMMeasurementRecord? { records.first }
    public var last: CGMMeasurementRecord? { records.last }

    public mutating func append(_ record: CGMMeasurementRecord) {
        records.append(record)
        trim()
    }

    public mutating func removeAll() {
        records.removeAll()
    }

    /// Records matching an RACP operator and Time Offset bounds (CGMS Table 3.4), oldest first.
    public func select(_ racpOperator: CGMRACPOperator, minimum: UInt16 = 0, maximum: UInt16 = 0) -> [CGMMeasurementRecord] {
        switch racpOperator {
        case .allRecords: return records
        case .lessThanOrEqualTo: return records.filter { $0.timeOffset <= maximum }
        case .greaterThanOrEqualTo: return records.filter { $0.timeOffset >= minimum }
        case .withinRangeOf: return records.filter { (minimum...max(minimum, maximum)).contains($0.timeOffset) }
        case .firstRecord: return records.first.map { [$0] } ?? []
        case .lastRecord: return records.last.map { [$0] } ?? []
        case .null: return []
        }
    }

    /// Removes the matching records and returns how many were deleted.
    @discardableResult
    public mutating func delete(_ racpOperator: CGMRACPOperator, minimum: UInt16 = 0, maximum: UInt16 = 0) -> Int {
        let doomed = select(racpOperator, minimum: minimum, maximum: maximum)
        guard !doomed.isEmpty else { return 0 }
        // Time Offsets can repeat (sub-minute intervals), so remove by identity within the selection.
        var remaining = doomed
        records.removeAll { record in
            if let index = remaining.firstIndex(of: record) {
                remaining.remove(at: index)
                return true
            }
            return false
        }
        return doomed.count
    }

    private mutating func trim() {
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements, in order.
    func chunked(by size: Int) -> [[Element]] {
        let size = Swift.max(1, size)
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
