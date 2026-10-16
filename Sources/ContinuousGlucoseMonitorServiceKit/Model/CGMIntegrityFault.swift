//
//  CGMIntegrityFault.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-16.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//

import Foundation

/// A one-shot corruption of the next payload the sensor sends (HYD-C-009, HYD-F-008/009): the way a tester
/// proves the collector rejects a tampered message instead of acting on it. Toggling the E2E-CRC Feature bit
/// cannot do that, because both sides re-read the Feature and agree; the fault keeps the Feature claiming
/// E2E-CRC and breaks one message. Armed on the sensor, consumed by the next read response, notification or
/// indication of a CGMS characteristic, then cleared.
public enum CGMIntegrityFault: String, CaseIterable, Sendable, CustomStringConvertible {
    /// Send the payload without its E2E-CRC trailer (CGMS §1.8: Missing CRC). No-op when the Feature does
    /// not advertise E2E-CRC, since there is no trailer to drop.
    case omitCRC
    /// Flip a bit in the E2E-CRC so it no longer matches the payload (Invalid CRC). No-op without E2E-CRC.
    case corruptCRC
    /// Cut the payload short by one octet, after dropping any CRC, so its length no longer matches the fields
    /// its flags promise (malformed characteristic value).
    case truncate

    public var description: String {
        switch self {
        case .omitCRC: return "Omit CRC"
        case .corruptCRC: return "Corrupt CRC"
        case .truncate: return "Truncate"
        }
    }

    /// `data` with the fault applied, or unchanged when the fault does not apply to this payload.
    /// `hasCRC` says whether the payload ends in an E2E-CRC trailer.
    func applied(to data: Data, hasCRC: Bool) -> Data {
        switch self {
        case .omitCRC:
            guard hasCRC, data.count > CGME2ECRC.size else { return data }
            return data.dropLast(CGME2ECRC.size)
        case .corruptCRC:
            guard hasCRC, !data.isEmpty else { return data }
            var corrupted = data
            corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
            return corrupted
        case .truncate:
            let trailer = hasCRC ? CGME2ECRC.size : 0
            guard data.count > trailer + 1 else { return data }
            return data.dropLast(trailer + 1)
        }
    }
}

/// What the last armed fault did, for the tester UI.
public struct CGMInjectedFault: Equatable, Sendable {
    public let fault: CGMIntegrityFault
    public let characteristic: CGMCharacteristicUUID
    public let date: Date
    /// False when the fault did not apply (no CRC to omit or corrupt) and the payload went out intact.
    public let applied: Bool
}
