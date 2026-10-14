//
//  MockCGMSensor.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-01.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Simulated CGM sensor. Owns the sensor state and wires it to a
//  GATT server: CGM Service (CGMS v1.0.2 Table 3.1), Device Information and Battery.
//
//  Scope so far: static GATT (Feature, Status, Session Start Time and Session Run Time readable, Session Start
//  Time writable, both control points answer "Op Code not supported") plus periodic measurements from a
//  glucose trace, notified on CGM Measurement. RACP and CGMCP procedures arrive in later phases.
//
//  Threading: CBPeripheralManager is created with a nil queue, so every GATT callback runs on the main
//  queue, and the UI drives the sensor from the main queue too. `@unchecked Sendable` records that contract.

import CoreBluetooth
import BluetoothCommonKit

public final class MockCGMSensor: @unchecked Sendable {
    /// Local name a host app advertises for this sensor unless the tester overrides it.
    public static let defaultAdvertisedName = "Tidepool-CGM-Simulator"

    let gattServer: GATTService
    let messageQueue: MessagingQueue
    private let now: () -> Date

    public weak var delegate: MockCGMSensorDelegate?

    /// CGMS requires authenticated links for every characteristic; `true` makes iOS pair and bond. Off by
    /// default so testing needs no bond (Nate, 2026-10-09); ACS will provide the application-layer channel.
    /// Fixed at creation because CoreBluetooth permissions cannot change after the service is published.
    public let requiresEncryption: Bool

    public var deviceInformation: CGMDeviceInformation

    public var feature: CGMFeature {
        didSet {
            guard oldValue != feature else { return }
            indicateFeatureIfSubscribed()
            notifyDelegate()
        }
    }

    /// Annunciation bits set by the tester. Bits derived from session state are added in `sensorStatus`.
    public var manualSensorStatus: CGMSensorStatusAnnunciation = [] {
        didSet {
            guard oldValue != manualSensorStatus else { return }
            notifyDelegate()
        }
    }

    public var sessionRunTime = CGMSessionRunTime(hours: 240) {
        didSet {
            guard oldValue != sessionRunTime else { return }
            notifyDelegate()
        }
    }

    public private(set) var sessionState: CGMSessionState

    /// Device-clock instant of Time Offset 0 for the current session.
    public private(set) var sessionStartedAt: Date

    /// Device-clock instant the session was stopped; Time Offset freezes here (CGMS §3.3.1: the offset of
    /// the most recent measurement) until a new session starts.
    public private(set) var sessionStoppedAt: Date?

    /// The simulator has a real clock, so this is set from the device time when a session starts (by the UI
    /// or by CGMCP Start Session). A collector write replaces it per CGMS §3.4.1. Nil until the first session.
    public private(set) var sessionStartTime: CGMSessionStartTime?

    /// True once the collector has written CGM Session Start Time in the current session.
    public private(set) var sessionStartTimeSetByCollector = false

    /// Seconds between measurements (HYD-G-001, default 5 min). Time Offset has one-minute resolution, so
    /// sub-minute intervals produce several records with the same offset. Non-positive values are ignored:
    /// Foundation would clamp them to 0.1 ms and flood the main run loop.
    public var measurementInterval: TimeInterval = 5 * 60 {
        didSet {
            guard measurementInterval > 0 else {
                measurementInterval = oldValue
                return
            }
            guard oldValue != measurementInterval else { return }
            scheduleMeasurementTimer()
            notifyDelegate()
        }
    }

    public var trace: CGMGlucoseTrace = .simulatorDefault {
        didSet {
            guard oldValue != trace else { return }
            // A scripted scenario starts from its first value when it becomes the source.
            scenarioIndex = 0
            notifyDelegate()
        }
    }

    /// Position in a scripted scenario; advances once per measurement.
    private var scenarioIndex = 0

    public private(set) var lastMeasurement: CGMMeasurementRecord?

    /// Measurements taken in the current session; lets a tester see activity when the value barely moves.
    public private(set) var measurementCount = 0

    /// When the timer will next sample the trace; nil while no session is running.
    public var nextMeasurementDate: Date? {
        guard let timer = measurementTimer else { return nil }
        // Inside the timer's own callback `fireDate` still holds the instant that just fired; the run loop
        // advances it only after the callback returns, and a busy loop can leave it more than one interval
        // behind. Step forward past now so observers never see a past date.
        let now = Date()
        var next = timer.fireDate
        while next <= now {
            next = next.addingTimeInterval(timer.timeInterval)
        }
        return next
    }

    private var measurementTimer: Timer?

    public let batteryLevelCharacteristic: BatteryLevelCharacteristic

    // MARK: Authorization Control

    /// Out-of-band confirmation number shared with the collector during key exchange; same default as the
    /// mock pump so one tester value works for both devices.
    public static let defaultOOBRandomNumber = "42"

    /// Holds the ECDH pair, the derived session key and the AES-GCM nonce state for the secure channel.
    public let securityManager: SecurityManager

    /// Shared key held for the security manager (SecurityManagerDelegate storage): the raw ECDH secret
    /// during the exchange, the derived session key once confirmed, nil when invalidated or rejected.
    /// "Established" is reported through `securityManagerDidEstablishedSecurity`, not from this value.
    public var sharedKeyData: Data?

    public let authorizationStatusCharacteristic: ACStatusCharacteristic
    public let authorizationControlPoint: ACControlPointCharacteristic
    public let authorizationDataCharacteristic: ACDataCharacteristic

    /// When on, the CGMS characteristics are protected resources: plain reads and writes answer
    /// Insufficient Authorization and the collector must go through AC Data In / Out after the key
    /// exchange. Measurement notifications and control point indications then travel the secure channel
    /// as well. Off by default so bring-up needs no handshake; flips live, no restart needed.
    public var isAuthorizationControlEnabled = false {
        didSet {
            guard oldValue != isAuthorizationControlEnabled else { return }
            // AC Status tells the collector whether resources are protected: restriction map 1 when gated,
            // 0 when open (AC Data In then refuses requests). Indicated so a connected collector learns of the flip.
            authorizationStatusCharacteristic.currentRestrictionMapID = isAuthorizationControlEnabled ? Self.restrictionMapID : 0
            authorizationStatusCharacteristic.triggerIndication()
            ConsoleOut.shared.logMessage(message: "Authorization Control \(isAuthorizationControlEnabled ? "enabled" : "disabled")")
            notifyDelegate()
        }
    }

    /// True once the collector has completed the ECDH key exchange and confirmation.
    public var isSecurityEstablished: Bool {
        authorizationStatusCharacteristic.isSecurityEstablished
    }

    public init(gattServer: GATTService,
                messageQueue: MessagingQueue,
                requiresEncryption: Bool = false,
                deviceInformation: CGMDeviceInformation = .simulatorDefault,
                feature: CGMFeature = .simulatorDefault,
                now: @escaping () -> Date = { Date() })
    {
        self.gattServer = gattServer
        self.messageQueue = messageQueue
        self.requiresEncryption = requiresEncryption
        self.deviceInformation = deviceInformation
        self.feature = feature
        self.now = now
        // A sensor powers on idle; Start Session comes from the tester UI or the collector (CGMS §3.7.2.8).
        self.sessionState = .notStarted
        self.sessionStartedAt = now()
        self.batteryLevelCharacteristic = BatteryLevelCharacteristic(messageQueue: messageQueue)

        // Same ACS wiring as MockInsulinDeliveryPump; 19-octet segments fit the default ATT MTU.
        let maxRequestSize = 19
        let securityManager = SecurityManager()
        securityManager.configuration.oobRandomNumber = Data(Self.defaultOOBRandomNumber.utf8)
        securityManager.configuration.generatedIVFixedField = Self.fixedIVField
        self.securityManager = securityManager
        authorizationStatusCharacteristic = ACStatusCharacteristic(messageQueue: messageQueue)
        authorizationStatusCharacteristic.currentRestrictionMapID = 0   // resources open until the toggle turns on
        authorizationControlPoint = ACControlPointCharacteristic(messageQueue: messageQueue)
        authorizationControlPoint.securityManager = securityManager
        authorizationControlPoint.maxRequestSize = maxRequestSize
        authorizationDataCharacteristic = ACDataCharacteristic(messageQueue: messageQueue)
        authorizationDataCharacteristic.status = authorizationStatusCharacteristic
        authorizationDataCharacteristic.securityManager = securityManager
        authorizationDataCharacteristic.maxRequestSize = maxRequestSize
        authorizationControlPoint.delegate = self
        authorizationDataCharacteristic.delegate = self
        securityManager.delegate = self

        createCGMService()
        createDeviceInformationService()
        createBatteryService()
        createAuthorizationControlService()

        gattServer.addService()
        gattServer.startAdvertising()
        scheduleMeasurementTimer()
    }

    deinit {
        measurementTimer?.invalidate()
    }

    // MARK: - Derived state

    public var isE2EProtectionSupported: Bool { feature.isE2ECRCSupported }

    /// Minutes from session start to now, or to the stop instant once stopped, clamped to the UINT16 wire range.
    /// Zero until the first session starts (CGMS §3.1.1.4 default initial value).
    public var timeOffset: UInt16 {
        guard sessionState != .notStarted else { return 0 }
        let reference = sessionStoppedAt ?? now()
        let minutes = reference.timeIntervalSince(sessionStartedAt) / 60
        return UInt16(clamping: Int(max(0, minutes)))
    }

    public var sensorStatus: CGMSensorStatusAnnunciation {
        // Time Synchronization Required is tester-controlled: the sensor knows its own start time.
        var status = manualSensorStatus
        if sessionState != .running { status.insert(.sessionStopped) }
        return status
    }

    public var status: CGMStatus {
        CGMStatus(timeOffset: timeOffset, sensorStatus: sensorStatus)
    }

    /// What a read of 0x2AAA returns; before the first session it falls back to the power-on time.
    public var effectiveSessionStartTime: CGMSessionStartTime {
        sessionStartTime ?? CGMSessionStartTime(date: sessionStartedAt, timeZone: .current)
    }

    // MARK: - Session control (tester UI)

    /// Starts a new session: Time Offset restarts at 0 and Session Start Time is taken from the device clock.
    public func startSession() {
        sessionStartedAt = now()
        sessionStoppedAt = nil
        sessionStartTime = CGMSessionStartTime(date: sessionStartedAt, timeZone: .current)
        sessionStartTimeSetByCollector = false
        lastMeasurement = nil
        measurementCount = 0
        scenarioIndex = 0
        sessionState = .running
        ConsoleOut.shared.logMessage(message: "\(#function): session started at \(sessionStartedAt)")
        scheduleMeasurementTimer()
        notifyDelegate()
    }

    public func stopSession() {
        guard sessionState == .running else { return }
        sessionStoppedAt = now()
        sessionState = .stopped
        measurementTimer?.invalidate()
        measurementTimer = nil
        ConsoleOut.shared.logMessage(message: "\(#function): session stopped at time offset \(timeOffset)")
        notifyDelegate()
    }

    // MARK: - Measurements

    /// Samples the trace, records the result and notifies a subscribed collector (CGMS §3.1.1 periodic
    /// notification). Also callable from the tester UI for an out-of-cadence reading.
    @discardableResult
    public func takeMeasurement() -> CGMMeasurementRecord? {
        guard sessionState == .running else { return nil }

        let elapsed = now().timeIntervalSince(sessionStartedAt)
        let index = scenarioIndex
        let trend = trace.trend(elapsed: elapsed, index: index)
        let record = CGMMeasurementRecord(
            glucoseConcentration: trace.glucose(elapsed: elapsed, index: index).rounded(),
            timeOffset: timeOffset,
            sensorStatus: sensorStatus,
            trend: feature.flags.contains(.trendInformation) ? (trend * 10).rounded() / 10 : nil,
            quality: feature.flags.contains(.quality) ? 100 : nil
        )
        scenarioIndex += 1
        lastMeasurement = record
        measurementCount += 1
        ConsoleOut.shared.logMessage(message: "\(#function) #\(measurementCount): \(record)")

        let encoded = record.encoded(e2eCRC: isE2EProtectionSupported)
        if isAuthorizationControlEnabled {
            // Protected resource: encrypted notification on AC Data Out Notify (checks its own subscription).
            authorizationDataCharacteristic.sendSecureNotification(encoded, to: CGMResourceHandle.handle(for: .measurement))
        } else if gattServer.isCharacteristicSubscribed(CGMCharacteristicUUID.measurement.cbUUID) == true {
            messageQueue.addQueueItem(UUIDValuePair(uuid: CGMCharacteristicUUID.measurement.cbUUID, value: encoded))
        }

        notifyDelegate()
        return record
    }

    private func scheduleMeasurementTimer() {
        measurementTimer?.invalidate()
        measurementTimer = nil
        guard sessionState == .running else { return }
        let timer = Timer(timeInterval: measurementInterval, repeats: true) { [weak self] _ in
            self?.takeMeasurement()
        }
        // Common modes so the timer keeps firing while the tester scrolls the UI (default mode pauses then).
        RunLoop.main.add(timer, forMode: .common)
        measurementTimer = timer
    }

    // MARK: - Read handlers

    public func readFeature() -> (CBATTError.Code, Data) {
        let data = feature.encoded()
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString) (\(feature))")
        return (.success, data)
    }

    public func readStatus() -> (CBATTError.Code, Data) {
        let status = self.status
        let data = status.encoded(e2eCRC: isE2EProtectionSupported)
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString) (\(status))")
        return (.success, data)
    }

    public func readSessionStartTime() -> (CBATTError.Code, Data) {
        let startTime = effectiveSessionStartTime
        let data = startTime.encoded(e2eCRC: isE2EProtectionSupported)
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString) (\(startTime))")
        return (.success, data)
    }

    public func readSessionRunTime() -> (CBATTError.Code, Data) {
        let data = sessionRunTime.encoded(e2eCRC: isE2EProtectionSupported)
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString) (\(sessionRunTime))")
        return (.success, data)
    }

    // MARK: - Write handlers

    /// CGMS §3.4.1: the collector writes its current time; the sensor stores
    /// session start = written time − current Time Offset.
    public func writeSessionStartTime(_ data: Data?) -> CBATTError.Code {
        guard let data else { return .invalidPdu }
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString)")

        switch checkWrite(data, payloadSize: CGMSessionStartTime.baseSize) {
        case .wrongSize: return .invalidAttributeValueLength
        case .missingCRC: return CGMApplicationErrorCode.missingCRC.attErrorCode
        case .invalidCRC: return CGMApplicationErrorCode.invalidCRC.attErrorCode
        case .ok: break
        }

        // Size and CRC are already verified, so decode just the payload.
        let written: CGMSessionStartTime
        do {
            written = try CGMSessionStartTime(data: data.prefix(CGMSessionStartTime.baseSize), e2eCRC: false)
        } catch {
            // Only field validation can fail here (time zone or DST out of range).
            ConsoleOut.shared.logMessage(message: "\(#function): rejected: \(error)")
            return .outOfRange
        }

        let offsetSeconds = TimeInterval(timeOffset) * 60
        sessionStartTime = CGMSessionStartTime(
            date: written.date.addingTimeInterval(-offsetSeconds),
            timeZoneOffset: written.timeZoneOffset,
            dstOffset: written.dstOffset
        )
        sessionStartTimeSetByCollector = true
        ConsoleOut.shared.logMessage(message: "\(#function): session start time set to \(sessionStartTime!)")
        notifyDelegate()
        return .success
    }

    /// Phase 1: every RACP op code is answered with Response Code / Op Code not supported (CGMS §3.8.2).
    /// RACP never carries an E2E-CRC (CGMS §3.6).
    public func writeRecordAccessControlPoint(_ data: Data?) -> CBATTError.Code {
        guard let data, let requestOpcode = data.first else { return .invalidPdu }
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString)")

        let response = Data([
            CGMRACPOpcode.responseCode.rawValue,
            CGMRACPOperator.null.rawValue,
            requestOpcode,
            CGMRACPResponseCode.opCodeNotSupported.rawValue
        ])
        indicate(response, on: .recordAccessControlPoint)
        return .success
    }

    /// Start Session and Stop Session are implemented (CGMS §3.7.2.8, §3.7.2.9); every other op code is
    /// answered with Response Code / Op Code not supported (CGMS §3.8.2) until its phase lands.
    ///
    /// Operand size is checked first, since the CRC can only be located once the operand length is known:
    /// wrong size → Invalid Operand response; right size without a CRC → Missing CRC; right size with a bad
    /// CRC → Invalid CRC (Nate, 2026-10-09).
    public func writeSpecificOpsControlPoint(_ data: Data?) -> CBATTError.Code {
        guard let data, let requestOpcode = data.first else { return .invalidPdu }
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString)")

        guard let opcode = CGMSpecificOpsOpcode(rawValue: requestOpcode), let operand = opcode.requestOperand else {
            // Unknown or response op codes have no defined operand, so the CRC cannot be located.
            indicateSpecificOpsResponse(request: requestOpcode, code: .opCodeNotSupported)
            return .success
        }

        switch checkWrite(data, payloadSize: 1 + operand.encodedSize) {
        case .wrongSize:
            indicateSpecificOpsResponse(request: requestOpcode, code: .invalidOperand)
            return .success
        case .missingCRC: return CGMApplicationErrorCode.missingCRC.attErrorCode
        case .invalidCRC: return CGMApplicationErrorCode.invalidCRC.attErrorCode
        case .ok: break
        }

        let responseCode: CGMSpecificOpsResponseCode
        switch opcode {
        case .startSession:
            // Also restarts a running session: previous data is discarded (§3.7.2.8).
            startSession()
            responseCode = .success
        case .stopSession:
            if sessionState == .running {
                stopSession()
                responseCode = .success
            } else {
                // §3.7.2.9: stopping a session that is not running is Op Code not supported.
                responseCode = .opCodeNotSupported
            }
        default:
            responseCode = .opCodeNotSupported
        }
        indicateSpecificOpsResponse(request: requestOpcode, code: responseCode)
        return .success
    }

    private func indicateSpecificOpsResponse(request: UInt8, code: CGMSpecificOpsResponseCode) {
        let response = CGMSpecificOpsResponse.responseCode(request: request, code: code.rawValue)
        indicate(response.encoded(e2eCRC: isE2EProtectionSupported), on: .specificOpsControlPoint)
    }

    // MARK: - Helpers

    private enum WriteCheck {
        case ok, wrongSize, missingCRC, invalidCRC
    }

    /// Size first, then CRC (Nate, 2026-10-09): the CRC can only be located once the payload size matches.
    /// With E2E-CRC on, exactly the payload means the CRC was never sent (CGMS §1.8 Missing CRC); the right
    /// total with a CRC that does not compute is Invalid CRC. Callers map `wrongSize` to their own response.
    private func checkWrite(_ data: Data, payloadSize: Int) -> WriteCheck {
        guard isE2EProtectionSupported else {
            return data.count == payloadSize ? .ok : .wrongSize
        }
        if data.count == payloadSize { return .missingCRC }
        guard data.count == payloadSize + CGME2ECRC.size else { return .wrongSize }
        return data.isCRCValid ? .ok : .invalidCRC
    }

    /// Plain indication, or an encrypted one on AC Data Out Indicate while Authorization Control is on.
    private func indicate(_ response: Data, on characteristic: CGMCharacteristicUUID) {
        ConsoleOut.shared.logMessage(message: "\(#function) \(characteristic.name): \(response.hexadecimalString)")
        if isAuthorizationControlEnabled {
            authorizationDataCharacteristic.sendSecureIndication(response, to: CGMResourceHandle.handle(for: characteristic))
        } else {
            messageQueue.addQueueItem(UUIDValuePair(uuid: characteristic.cbUUID, value: response))
        }
    }

    /// Plain path: only when the Feature CCCD is on. Secure path: `sendSecureIndication` checks AC Data Out itself.
    private func indicateFeatureIfSubscribed() {
        guard isAuthorizationControlEnabled || gattServer.isCharacteristicSubscribed(CGMCharacteristicUUID.feature.cbUUID) == true else { return }
        indicate(feature.encoded(), on: .feature)
    }

    // While Authorization Control is on, the plain CGMS characteristics are protected resources (ACS):
    // they answer Insufficient Authorization and are served through AC Data In instead.
    private func guardedRead(_ read: () -> (CBATTError.Code, Data)) -> (CBATTError.Code, Data) {
        isAuthorizationControlEnabled ? (.insufficientAuthorization, Data()) : read()
    }

    private func guardedWrite(_ write: () -> CBATTError.Code) -> CBATTError.Code {
        isAuthorizationControlEnabled ? .insufficientAuthorization : write()
    }

    func notifyDelegate() {
        delegate?.mockSensorDidUpdate(self)
    }

    private var readPermissions: CBAttributePermissions {
        requiresEncryption ? .readEncryptionRequired : .readable
    }

    private var writePermissions: CBAttributePermissions {
        requiresEncryption ? .writeEncryptionRequired : .writeable
    }

    // MARK: - Service construction
    //
    // The characteristics outlive nothing but the GATT server, which this sensor owns, so every handler
    // captures `self` weakly to avoid a sensor -> server -> characteristic -> closure -> sensor cycle.
    // A handler that outlives its sensor answers Unlikely Error.

    private static let goneRead: (CBATTError.Code, Data) = (.unlikelyError, Data())

    private func createCGMService() {
        let charMeasurement = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.measurement.cbUUID,
            properties: .notify,
            permissions: readPermissions,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { (.readNotPermitted, Data()) }
        )

        let charFeature = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.feature.cbUUID,
            properties: [.read, .indicate],
            permissions: readPermissions,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { [weak self] in
                guard let self else { return Self.goneRead }
                return self.guardedRead(self.readFeature)
            }
        )

        let charStatus = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.status.cbUUID,
            properties: .read,
            permissions: readPermissions,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { [weak self] in
                guard let self else { return Self.goneRead }
                return self.guardedRead(self.readStatus)
            }
        )

        let charSessionStartTime = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.sessionStartTime.cbUUID,
            properties: [.read, .write],
            permissions: readPermissions.union(writePermissions),
            _onWrite: { [weak self] data, _ in
                guard let self else { return .unlikelyError }
                return self.guardedWrite { self.writeSessionStartTime(data) }
            },
            _onRead: { [weak self] in
                guard let self else { return Self.goneRead }
                return self.guardedRead(self.readSessionStartTime)
            }
        )

        let charSessionRunTime = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.sessionRunTime.cbUUID,
            properties: .read,
            permissions: readPermissions,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { [weak self] in
                guard let self else { return Self.goneRead }
                return self.guardedRead(self.readSessionRunTime)
            }
        )

        let charRACP = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.recordAccessControlPoint.cbUUID,
            properties: [.write, .indicate],
            permissions: writePermissions,
            _onWrite: { [weak self] data, _ in
                guard let self else { return .unlikelyError }
                return self.guardedWrite { self.writeRecordAccessControlPoint(data) }
            },
            _onRead: { (.readNotPermitted, Data()) }
        )

        let charCGMCP = CallbackCharacteristic(
            uuid: CGMCharacteristicUUID.specificOpsControlPoint.cbUUID,
            properties: [.write, .indicate],
            permissions: writePermissions,
            _onWrite: { [weak self] data, _ in
                guard let self else { return .unlikelyError }
                return self.guardedWrite { self.writeSpecificOpsControlPoint(data) }
            },
            _onRead: { (.readNotPermitted, Data()) }
        )

        gattServer.createService(CGMCharacteristicUUID.service.cbUUID, primary: true, withCharacteristics: [
            charMeasurement,
            charFeature,
            charStatus,
            charSessionStartTime,
            charSessionRunTime,
            charRACP,
            charCGMCP
        ])
    }

    private func createDeviceInformationService() {
        func readable(_ uuid: DeviceInfoCharacteristicUUID, _ value: @escaping () -> Data) -> CallbackCharacteristic {
            CallbackCharacteristic(
                uuid: uuid.cbUUID,
                properties: .read,
                permissions: .readable,
                _onWrite: { _, _ in .writeNotPermitted },
                _onRead: { (.success, value()) }
            )
        }

        func utf8(_ keyPath: KeyPath<CGMDeviceInformation, String>) -> () -> Data {
            { [weak self] in self?.deviceInformation[keyPath: keyPath].data(using: .utf8) ?? Data() }
        }

        gattServer.createService(DeviceInfoCharacteristicUUID.service.cbUUID, primary: true, withCharacteristics: [
            readable(.manufacturerNameString, utf8(\.manufacturerName)),
            readable(.modelNumberString, utf8(\.modelNumber)),
            readable(.serialNumberString, utf8(\.serialNumber)),
            readable(.firmwareRevisionString, utf8(\.firmwareRevision)),
            readable(.hardwareRevisionString, utf8(\.hardwareRevision)),
            readable(.softwareRevisionString, utf8(\.softwareRevision)),
            readable(.systemID, { [weak self] in self?.deviceInformation.systemID ?? Data() })
        ])
    }

    private func createBatteryService() {
        let charBatteryLevel = CallbackCharacteristic(
            uuid: BatteryCharacteristicUUID.batteryLevel.cbUUID,
            properties: [.read, .notify],
            permissions: .readable,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { [weak self] in self?.batteryLevelCharacteristic.onRead() ?? Self.goneRead }
        )
        gattServer.createService(BatteryCharacteristicUUID.service.cbUUID, primary: true, withCharacteristics: [charBatteryLevel])
    }

    /// ACS 0x183D, always published (as on the mock pump); `isAuthorizationControlEnabled` decides whether
    /// the CGMS characteristics are gated behind it. Never link-encrypted: ACS is the application layer.
    private func createAuthorizationControlService() {
        let charStatus = CallbackCharacteristic(
            uuid: ACCharacteristicUUID.status.cbUUID,
            properties: [.read, .indicate],
            permissions: .readable,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { [weak self] in self?.authorizationStatusCharacteristic.onRead() ?? Self.goneRead }
        )

        let charControlPoint = CallbackCharacteristic(
            uuid: ACCharacteristicUUID.controlPoint.cbUUID,
            properties: [.write, .indicate],
            permissions: .writeable,
            _onWrite: { [weak self] data, _ in self?.authorizationControlPoint.onWrite(data) ?? .unlikelyError },
            _onRead: { (.readNotPermitted, Data()) }
        )

        let charDataIn = CallbackCharacteristic(
            uuid: ACCharacteristicUUID.dataIn.cbUUID,
            properties: .write,
            permissions: .writeable,
            _onWrite: { [weak self] data, _ in self?.authorizationDataCharacteristic.onWrite(data) ?? .unlikelyError },
            _onRead: { (.readNotPermitted, Data()) }
        )

        let charDataOutNotify = CallbackCharacteristic(
            uuid: ACCharacteristicUUID.dataOutNotify.cbUUID,
            properties: .notify,
            permissions: .readable,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { (.readNotPermitted, Data()) }
        )

        let charDataOutIndicate = CallbackCharacteristic(
            uuid: ACCharacteristicUUID.dataOutIndicate.cbUUID,
            properties: .indicate,
            permissions: .readable,
            _onWrite: { _, _ in .writeNotPermitted },
            _onRead: { (.readNotPermitted, Data()) }
        )

        gattServer.createService(ACCharacteristicUUID.service.cbUUID, primary: true, withCharacteristics: [
            charStatus,
            charControlPoint,
            charDataIn,
            charDataOutNotify,
            charDataOutIndicate
        ])
    }
}

public extension CGMFeature {
    /// What the simulator advertises out of the box. E2E-CRC is off so bring-up traffic is easy to read.
    static let simulatorDefault = CGMFeature(
        flags: [
            .calibration,
            .patientHighLowAlerts,
            .hypoAlerts,
            .hyperAlerts,
            .rateOfIncreaseDecreaseAlerts,
            .deviceSpecificAlert,
            .sensorMalfunctionDetection,
            .generalDeviceFault,
            .multipleSessions,
            .trendInformation,
            .quality
        ]
    )
}
