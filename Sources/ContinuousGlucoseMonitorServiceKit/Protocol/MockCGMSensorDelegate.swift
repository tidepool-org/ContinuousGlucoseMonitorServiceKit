//
//  MockCGMSensorDelegate.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-01.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation

public protocol MockCGMSensorDelegate: AnyObject {
    /// Called on the main queue whenever sensor state visible to a collector changes.
    func mockSensorDidUpdate(_ sensor: MockCGMSensor)
}
