//
//  ContinuousGlucoseMonitorService.swift
//  ContinuousGlucoseMonitorServiceKit
//
//  Created by Nathaniel Hamming on 2026-10-16.
//  Copyright © 2026 Tidepool Project. All rights reserved.
//
//  Collector side of CGMS, on BluetoothCommonKit's BluetoothManager / PeripheralManager, mirroring
//  `InsulinDeliveryService` in the pump kit so a Loop CGM plugin and the simulator's test client share it.
//  One pending completion per characteristic: a control point write is answered by an indication on that
//  characteristic, a read by its value, a secure request by AC Data Out carrying the characteristic's handle.
//  Callbacks arrive on two queues (the peripheral's and the central manager's), so the mutable fields sit
//  behind one lock and the delegate is never called while it is held.

import CoreBluetooth
import BluetoothCommonKit
import os.log

open class ContinuousGlucoseMonitorService: CGMSensorComms {
    public weak var delegate: CGMSensorDelegate?
    public weak var loggingDelegate: DeviceCommLoggingDelegate?

    private let log = OSLog(category: "ContinuousGlucoseMonitorService")

    public let bluetoothManager: BluetoothManager
    public let securityManager: SecurityManager
    public let acControlPoint: ACControlPointDataHandler
    public let acData: ACDataDataHandler

    /// Timeout for one read, write or secure request on the peripheral.
    public var requestTimeout: TimeInterval = 10

    /// Derived session key (SecurityManagerDelegate storage); nil until a key exchange completes. A host that
    /// persists pairing overrides this together with the nonce sequence number in `state`.
    open var sharedKeyData: Data?

    // MARK: Locked state

    private let lock = NSLock()
    private var _state: CGMSensorState
    private var _sessionStartTime: CGMSessionStartTime?
    private var _usesSecureChannel = false
    private var _isReady = false
    private var _linkLossReported = false
    private var _handshakeCompletion: ProcedureResultCompletion?
    /// One per characteristic, like the control points they answer: a second request to a busy
    /// characteristic is refused with Procedure In Progress rather than silently replacing the first.
    private var _pending: [CBUUID: ProcedureCompletion<Data>] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var state: CGMSensorState {
        get { locked { _state } }
        set { updateState { $0 = newValue } }
    }

    /// One locked read-modify-write, then the delegate outside the lock.
    private func updateState(_ body: (inout CGMSensorState) -> Void) {
        let changed: Bool = locked {
            let previous = _state
            body(&_state)
            return _state != previous
        }
        if changed { delegate?.sensorDidUpdateState(self) }
    }

    /// The Feature describes the sensor, not the link: read once per sensor, kept in `state`, replaced only
    /// by a Feature indication, dropped with the sensor in `forgetSensor()`.
    public var feature: CGMFeature? { locked { _state.feature } }

    public private(set) var sessionStartTime: CGMSessionStartTime? {
        get { locked { _sessionStartTime } }
        set { locked { _sessionStartTime = newValue } }
    }

    public var usesSecureChannel: Bool {
        get { locked { _usesSecureChannel } }
        set { locked { _usesSecureChannel = newValue } }
    }

    /// Set once configuration completed on the current link; cleared on every disconnect.
    private var isReady: Bool {
        get { locked { _isReady } }
        set { locked { _isReady = newValue } }
    }

    private var handshakeCompletion: ProcedureResultCompletion? {
        get { locked { _handshakeCompletion } }
        set { locked { _handshakeCompletion = newValue } }
    }

    /// Whether values and requests carry an E2E-CRC; false until the sensor's Feature has been read once.
    public var isE2EProtectionSupported: Bool {
        locked { _state.feature?.isE2ECRCSupported ?? false }
    }

    public var isSecurityEstablished: Bool { securityManager.applicationSecurityEstablished }

    public var peripheralManager: PeripheralManager? { bluetoothManager.peripheralManager }

    public var isConnected: Bool {
        if let isConnectedHandler { return isConnectedHandler() }
        return peripheralManager?.peripheral?.state == .connected
    }

    public var isAuthenticated: Bool {
        guard state.isAuthorizationControlRequired else { return true }
        return sharedKeyData != nil
    }

    // Test hooks, as in the pump kit.
    private let isConnectedHandler: (() -> Bool)?
    private let getCharacteristicForUUID: ((CBUUID) -> CBCharacteristic?)?

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - restoreOptions: nil for an app without the `bluetooth-central` background mode (the simulator).
    ///   - includingAuthorizationControl: false for a sensor that does not publish ACS; see the configuration.
    public convenience init(state: CGMSensorState = CGMSensorState(),
                            maxRequestSize: Int = 19,
                            restoreOptions: [String: Any]? = [CBCentralManagerOptionRestoreIdentifierKey: "org.tidepool.ContinuousGlucoseMonitorServiceKit"],
                            includingAuthorizationControl: Bool = true)
    {
        let bluetoothManager = BluetoothManager(
            peripheralIdentifier: state.identifier,
            peripheralConfiguration: .continuousGlucoseMonitorServiceConfiguration(includingAuthorizationControl: includingAuthorizationControl),
            servicesToDiscover: [CGMCharacteristicUUID.service.cbUUID],
            restoreOptions: restoreOptions
        )
        // Same construction as the proven test collector and the mock sensor: a fresh manager with the
        // stored configuration applied, so the first nonce is handled as the client side expects.
        let securityManager = SecurityManager()
        securityManager.configuration = state.securityManagerConfiguration
        let acControlPoint = ACControlPointDataHandler(securityManager: securityManager, maxRequestSize: maxRequestSize)
        let acData = ACDataDataHandler(securityManager: securityManager, maxRequestSize: maxRequestSize)
        self.init(bluetoothManager: bluetoothManager, securityManager: securityManager, acControlPoint: acControlPoint, acData: acData, state: state)
    }

    public init(bluetoothManager: BluetoothManager,
                securityManager: SecurityManager,
                acControlPoint: ACControlPointDataHandler,
                acData: ACDataDataHandler,
                state: CGMSensorState,
                isConnectedHandler: (() -> Bool)? = nil,
                getCharacteristicForUUID: ((CBUUID) -> CBCharacteristic?)? = nil)
    {
        self.bluetoothManager = bluetoothManager
        self.securityManager = securityManager
        self.acControlPoint = acControlPoint
        self.acData = acData
        self._state = state
        self.isConnectedHandler = isConnectedHandler
        self.getCharacteristicForUUID = getCharacteristicForUUID

        self.bluetoothManager.delegate = self
        self.securityManager.delegate = self
        self.acData.delegate = self
        self.acControlPoint.maxRequestSizeUpdatedHandler = { [weak self] newValue in
            self?.acData.updateMaxRequestSize(newValue)
            self?.acControlPoint.updateMaxRequestSize(newValue)
        }
    }

    open func setOOBString(_ oobString: String) {
        securityManager.configuration.oobRandomNumber = Data(oobString.utf8)
    }

    // MARK: - Connection

    public func scanForSensors() {
        loggingDelegate?.logConnectionEvent()
        // BluetoothManager reports each discovered peripheral once and forgets them only when its delegate is
        // assigned afresh; a new scan has to report everything again.
        bluetoothManager.delegate = nil
        bluetoothManager.delegate = self
        bluetoothManager.rescanForPeripheral()
    }

    public func connectToSensor(withIdentifier identifier: UUID) {
        loggingDelegate?.logConnectionEvent("identifier: \(identifier)")
        updateState { $0.identifier = identifier }
        bluetoothManager.connectToPeripheral(withIdentifier: identifier)
    }

    public func disconnect() {
        loggingDelegate?.logConnectionEvent()
        bluetoothManager.disconnect()
    }

    public func forgetSensor() {
        loggingDelegate?.logConnectionEvent()
        let wasReady = isReady
        isReady = false
        // Resetting the manager drops the peripheral before the disconnect callback, so BluetoothCommonKit
        // does not reconnect and no link-loss callback follows; the teardown and the delegate call happen here.
        bluetoothManager.reset()
        resetLinkState()
        updateState {
            $0.identifier = nil
            $0.name = nil
            $0.feature = nil
            $0.uuidToHandleMap = [:]
        }
        if wasReady { delegate?.sensorConnectionStatusChanged(self) }
    }

    public func prepareForDeactivation() {
        loggingDelegate?.logConnectionEvent()
        isReady = false
        resetLinkState()
        bluetoothManager.prepareForDeactivation()
    }

    // MARK: - Characteristic reads

    public func getFeature(completion: @escaping ProcedureCompletion<CGMFeature>) {
        read(.feature) { [weak self] result in
            completion(result.flatMap { data in Self.decode { try CGMFeature(data: data, e2eCRC: self?.isE2EProtectionSupported ?? false) } })
        }
    }

    public func getStatus(completion: @escaping ProcedureCompletion<CGMStatus>) {
        read(.status) { [weak self] result in
            completion(result.flatMap { data in Self.decode { try CGMStatus(data: data, e2eCRC: self?.isE2EProtectionSupported ?? false) } })
        }
    }

    public func getSessionStartTime(completion: @escaping ProcedureCompletion<CGMSessionStartTime>) {
        read(.sessionStartTime) { [weak self] result in
            completion(result.flatMap { data in Self.decode { try CGMSessionStartTime(data: data, e2eCRC: self?.isE2EProtectionSupported ?? false) } })
        }
    }

    public func getSessionRunTime(completion: @escaping ProcedureCompletion<CGMSessionRunTime>) {
        read(.sessionRunTime) { [weak self] result in
            completion(result.flatMap { data in Self.decode { try CGMSessionRunTime(data: data, e2eCRC: self?.isE2EProtectionSupported ?? false) } })
        }
    }

    public func setSessionStartTime(_ date: Date = Date(), timeZone: TimeZone = .current, completion: @escaping ProcedureResultCompletion) {
        let startTime = CGMSessionStartTime(date: date, timeZone: timeZone)
        write(startTime.encoded(e2eCRC: isE2EProtectionSupported), to: .sessionStartTime, answeredByIndication: false) { result in
            completion(result.map { _ in () })
        }
    }

    public func getBatteryLevel(completion: @escaping ProcedureCompletion<Int>) {
        let uuid = BatteryCharacteristicUUID.batteryLevel.cbUUID
        read(uuid, in: BatteryCharacteristicUUID.service.cbUUID) { result in
            completion(result.flatMap { data in
                data.isEmpty ? .failure(.invalidFormat) : .success(BatteryCharacteristicUUID.batteryLevel.toPercent(data))
            })
        }
    }

    public func getDeviceInformation(_ characteristic: DeviceInfoCharacteristicUUID, completion: @escaping ProcedureCompletion<String>) {
        read(characteristic.cbUUID, in: DeviceInfoCharacteristicUUID.service.cbUUID) { result in
            completion(result.flatMap { data in
                if characteristic == .systemID { return .success(data.hexadecimalString) }
                guard let text = characteristic.toString(data) else { return .failure(.invalidFormat) }
                return .success(text)
            })
        }
    }

    public func setNotifications(_ characteristic: CGMCharacteristicUUID, enabled: Bool, completion: @escaping ProcedureResultCompletion) {
        guard let peripheralManager, let cbCharacteristic = cgmCharacteristic(characteristic) else {
            completion(.failure(.deviceNotReady))
            return
        }
        peripheralManager.perform { [weak self] peripheralManager in
            self?.loggingDelegate?.logSendEvent("\(characteristic.name) notifications \(enabled ? "on" : "off")")
            do {
                try peripheralManager.setNotifyValue(enabled, for: cbCharacteristic, timeout: self?.requestTimeout ?? 10)
                completion(.success)
            } catch {
                completion(.failure(Self.commError(from: error)))
            }
        }
    }

    public func isNotifying(_ characteristic: CGMCharacteristicUUID) -> Bool {
        cgmCharacteristic(characteristic)?.isNotifying ?? false
    }

    // MARK: - Control points

    public func sendSpecificOpsRequest(_ opcode: CGMSpecificOpsOpcode, operand: Data, completion: @escaping CGMSpecificOpsCompletion) {
        let request = CGMSpecificOpsRequest.encode(opcode, operand: operand, e2eCRC: isE2EProtectionSupported)
        write(request, to: .specificOpsControlPoint, answeredByIndication: true) { [weak self] result in
            completion(result.flatMap { data in
                Self.decode { try CGMSpecificOpsResponse(data: data, e2eCRC: self?.isE2EProtectionSupported ?? false) }
                    .flatMap { response in
                        // A Response Code other than Success is the procedure failing, not a value.
                        if case let .responseCode(_, code) = response, let error = CGMSpecificOpsResponseCode(rawValue: code)?.deviceCommError {
                            return .failure(error)
                        }
                        return .success(response)
                    }
            })
        }
    }

    public func sendRACPRequest(_ request: CGMRACPRequest, completion: @escaping CGMRACPCompletion) {
        write(request.encoded(), to: .recordAccessControlPoint, answeredByIndication: true) { result in
            completion(result.flatMap { data in
                Self.decode { try CGMRACPResponse(data: data) }
                    .flatMap { response in
                        if case let .responseCode(_, code) = response, let error = CGMRACPResponseCode(rawValue: code)?.deviceCommError {
                            return .failure(error)
                        }
                        return .success(response)
                    }
            })
        }
    }

    // MARK: - Requests

    private func read(_ characteristic: CGMCharacteristicUUID, completion: @escaping ProcedureCompletion<Data>) {
        read(characteristic.cbUUID, in: CGMCharacteristicUUID.service.cbUUID, completion: completion)
    }

    /// A plain read, or a secure one when the channel is up and the characteristic is a protected CGMS
    /// resource; DIS and Battery stay plain.
    private func read(_ uuid: CBUUID, in serviceUUID: CBUUID, completion: @escaping ProcedureCompletion<Data>) {
        if usesSecureChannel, let cgmUUID = CGMCharacteristicUUID(cbUUID: uuid) {
            sendSecureRequest(nil, to: cgmUUID, completion: completion)
            return
        }
        guard let peripheralManager else {
            completion(.failure(.deviceNotReady))
            return
        }
        guard let characteristic = characteristic(uuid, in: serviceUUID) else {
            completion(.failure(.commandFailed("characteristic \(uuid) not available")))
            return
        }
        peripheralManager.perform { [weak self] peripheralManager in
            guard let self else { return }
            loggingDelegate?.logSendEvent("read \(uuid)")
            do {
                guard let value = try peripheralManager.readValue(for: characteristic, timeout: requestTimeout) else {
                    completion(.failure(.commandFailed("no value for \(uuid)")))
                    return
                }
                // A read consumes the update inside PeripheralManager, so the caches are fed here.
                handleValue(value, for: uuid, completesPending: false)
                completion(.success(value))
            } catch {
                completion(.failure(Self.commError(from: error)))
            }
        }
    }

    /// A plain write, or a secure one when the channel is up. A control point write is answered by an
    /// indication, which completes the pending completion; the write response itself only reports refusals.
    private func write(_ request: Data, to characteristic: CGMCharacteristicUUID, answeredByIndication: Bool, completion: @escaping ProcedureCompletion<Data>) {
        if usesSecureChannel {
            sendSecureRequest(request, to: characteristic, completion: completion)
            return
        }
        guard let peripheralManager else {
            completion(.failure(.deviceNotReady))
            return
        }
        guard let cbCharacteristic = cgmCharacteristic(characteristic) else {
            completion(.failure(.commandFailed("characteristic \(characteristic.name) not available")))
            return
        }
        let uuid = characteristic.cbUUID
        if answeredByIndication, !setPending(uuid, completion) {
            completion(.failure(.procedureInProgress))
            return
        }
        peripheralManager.perform { [weak self] peripheralManager in
            guard let self else { return }
            loggingDelegate?.logSendEvent("write \(characteristic.name): \(request.hexadecimalString)")
            do {
                try peripheralManager.writeValue(request, for: cbCharacteristic, type: .withResponse, timeout: requestTimeout)
                if !answeredByIndication { completion(.success(Data())) }
            } catch {
                let commError = Self.commError(from: error)
                // The indication may already have answered; only a completion still waiting hears the refusal.
                if answeredByIndication {
                    takePending(uuid)?(.failure(commError))
                } else {
                    completion(.failure(commError))
                }
            }
        }
    }

    /// Sends `request` (nil = read) to the protected characteristic through BluetoothCommonKit's AC Data
    /// handler, as the pump kit does: it encrypts on the peripheral's serial queue right before the write (the
    /// nonce sequence number is consumed in send order), and it classifies the ACS write errors (E2E counter
    /// and segment counter errors reach the `ACDataDataHandlerDelegate`, which reconnects; Procedure Already
    /// In Progress fails the request). The answer arrives on AC Data Out and is delivered under the
    /// characteristic's own UUID.
    private func sendSecureRequest(_ request: Data?, to characteristic: CGMCharacteristicUUID, completion: @escaping ProcedureCompletion<Data>) {
        guard let handle = resourceHandle(for: characteristic.cbUUID) else {
            completion(.failure(.deviceNotReady))
            return
        }
        guard let peripheralManager, peripheralManager.peripheral?.getACSCharacteristicWithUUID(.dataIn) != nil else {
            completion(.failure(.deviceNotReady))
            return
        }
        let uuid = characteristic.cbUUID
        guard setPending(uuid, completion) else {
            completion(.failure(.procedureInProgress))
            return
        }
        peripheralManager.perform { [weak self] peripheralManager in
            guard let self else { return }
            loggingDelegate?.logSendEvent("secure \(request == nil ? "read" : "write") \(characteristic.name) via handle \(handle)")
            if case .failure(let error) = acData.sendRequest(request, resourceHandle: handle, peripherialManager: peripheralManager, timeout: requestTimeout) {
                takePending(uuid)?(.failure(error))
            }
        }
    }

    private func resourceHandle(for uuid: CBUUID) -> ResourceHandle? {
        acControlPoint.uuidToHandleMap[uuid] ?? state.uuidToHandleMap[uuid]
    }

    private func characteristicUUID(for handle: ResourceHandle) -> CBUUID? {
        (acControlPoint.uuidToHandleMap.first { $0.value == handle } ?? state.uuidToHandleMap.first { $0.value == handle })?.key
    }

    private func cgmCharacteristic(_ characteristic: CGMCharacteristicUUID) -> CBCharacteristic? {
        self.characteristic(characteristic.cbUUID, in: CGMCharacteristicUUID.service.cbUUID)
    }

    private func characteristic(_ uuid: CBUUID, in serviceUUID: CBUUID) -> CBCharacteristic? {
        if let getCharacteristicForUUID { return getCharacteristicForUUID(uuid) }
        guard let service = peripheralManager?.peripheral?.services?.itemWithUUID(serviceUUID) else { return nil }
        return service.characteristics?.itemWithUUID(uuid)
    }

    // MARK: - Pending completions

    private func setPending(_ uuid: CBUUID, _ completion: @escaping ProcedureCompletion<Data>) -> Bool {
        locked {
            guard _pending[uuid] == nil else { return false }
            _pending[uuid] = completion
            return true
        }
    }

    private func takePending(_ uuid: CBUUID) -> ProcedureCompletion<Data>? {
        locked { _pending.removeValue(forKey: uuid) }
    }

    /// Fails the waiting completions that `matching` selects (all of them by default), outside the lock.
    private func failPending(_ error: DeviceCommError, where matching: (CBUUID) -> Bool = { _ in true }) {
        let failed: [ProcedureCompletion<Data>] = locked {
            let selected = _pending.filter { matching($0.key) }
            for key in selected.keys { _pending.removeValue(forKey: key) }
            return Array(selected.values)
        }
        for completion in failed {
            completion(.failure(error))
        }
    }

    // MARK: - Inbound values

    /// Decodes what can be cached or broadcast (Feature, Session Start Time, measurements, control point
    /// indications), then hands the raw value to whichever request was waiting on the characteristic.
    private func handleValue(_ data: Data, for uuid: CBUUID, completesPending: Bool = true) {
        loggingDelegate?.logReceiveEvent("\(uuid): \(data.hexadecimalString)")
        updateState { $0.lastCommsDate = Date() }

        switch uuid {
        case CGMCharacteristicUUID.feature.cbUUID:
            // Once E2E is known to be on, a corrupted E2E bit cannot switch the CRC check off.
            switch Self.decode({ try CGMFeature(data: data, e2eCRC: isE2EProtectionSupported) }) {
            case .success(let decoded):
                updateState { $0.feature = decoded }
                delegate?.sensor(self, didUpdateFeature: decoded)
            case .failure(let error):
                delegate?.sensor(self, didEncounterError: error, forCharacteristic: uuid)
            }
        case CGMCharacteristicUUID.sessionStartTime.cbUUID:
            if case .success(let startTime) = Self.decode({ try CGMSessionStartTime(data: data, e2eCRC: isE2EProtectionSupported) }) {
                sessionStartTime = startTime
            }
        case CGMCharacteristicUUID.measurement.cbUUID:
            switch Self.decode({ try CGMMeasurementRecord.decodeRecords(data, e2eCRC: isE2EProtectionSupported) }) {
            case .success(let records):
                delegate?.sensor(self, didReceiveMeasurements: records)
            case .failure(let error):
                delegate?.sensor(self, didEncounterError: error, forCharacteristic: uuid)
            }
        case CGMCharacteristicUUID.recordAccessControlPoint.cbUUID:
            if case .success(let response) = Self.decode({ try CGMRACPResponse(data: data) }) {
                delegate?.sensor(self, didReceiveRACPResponse: response)
            }
        case CGMCharacteristicUUID.specificOpsControlPoint.cbUUID:
            if case .success(let response) = Self.decode({ try CGMSpecificOpsResponse(data: data, e2eCRC: isE2EProtectionSupported) }) {
                delegate?.sensor(self, didReceiveSpecificOpsResponse: response)
            }
        default:
            break
        }

        if completesPending {
            takePending(uuid)?(.success(data))
        }
    }

    // MARK: - Errors

    /// A thrown codec or peripheral error as the `DeviceCommError` a completion reports.
    static func commError(from error: Error) -> DeviceCommError {
        switch error {
        case let codecError as CGMCodecError:
            switch codecError {
            case .invalidCRC, .missingCRC: return .invalidCRC
            default: return .invalidFormat
            }
        case let managerError as PeripheralManagerError:
            switch managerError {
            case .timeout: return .procedureTimeout
            case .notReady: return .deviceNotReady
            case .unknownCharacteristic, .unknownService: return .commandFailed(managerError.localizedDescription)
            case .invalidResponse: return .invalidFormat
            case .cbPeripheralError(let underlying): return commError(from: underlying)
            }
        case let attError as CBATTError:
            return commError(fromATT: attError)
        case let commError as DeviceCommError:
            return commError
        default:
            return .commandFailed(error.localizedDescription)
        }
    }

    /// ATT errors a CGM sensor returns on writes: the CGMS application codes (§1.8) and the common ones.
    static func commError(fromATT error: CBATTError) -> DeviceCommError {
        switch UInt8(truncatingIfNeeded: error.code.rawValue) {
        case CGMApplicationErrorCode.missingCRC.rawValue, CGMApplicationErrorCode.invalidCRC.rawValue:
            return .invalidCRC
        case 0xFD:
            return .commandFailed("Client Characteristic Configuration Descriptor Improperly Configured")
        case 0xFE:
            return .procedureInProgress
        case 0xFF:
            return .parameterOutOfRange
        default:
            if error.code == .insufficientAuthorization || error.code == .insufficientAuthentication || error.code == .insufficientEncryption {
                return .authenticationFailed
            }
            return .commandFailed(error.localizedDescription)
        }
    }

    static func decode<T>(_ body: () throws -> T) -> DeviceCommResult<T> {
        do {
            return .success(try body())
        } catch {
            return .failure(commError(from: error))
        }
    }

    // MARK: - Connection state

    /// Configuration done (BluetoothCommonKit has subscribed to Measurement, Feature and the control points).
    /// As in the pump kit, the ACS key exchange comes first when the sensor requires it, because a protected
    /// sensor refuses every plain CGMS read until then. Then the Feature is read if this sensor's is not known
    /// yet (CGMS §3.1; it decides E2E-CRC handling, and it is a property of the device, so once is enough),
    /// then the Session Start Time for calibration stamping, then ready is reported. A measurement that lands
    /// before a first-ever Feature read is decoded without the CRC check; that window closes within the first
    /// second of pairing.
    private func handleConnected() {
        let alreadyReady: Bool = locked {
            defer { _isReady = true; _linkLossReported = false }
            return _isReady   // configuration can complete more than once on one link
        }
        guard !alreadyReady else { return }
        if let peripheral = peripheralManager?.peripheral {
            updateState {
                $0.identifier = peripheral.identifier
                $0.name = peripheral.name
            }
        }
        delegate?.sensorConnectionStatusChanged(self)
        authenticateIfRequired { [weak self] in
            guard let self else { return }
            readFeatureIfUnknown { [weak self] in
                guard let self else { return }
                getSessionStartTime { [weak self] _ in
                    guard let self else { return }
                    delegate?.sensorIsReady(self)
                }
            }
        }
    }

    /// Runs the key exchange when the sensor requires Authorization Control and no session key is held, as the
    /// pump kit checks `applicationSecurityEstablished` before its first status read. A failed exchange is
    /// reported through `sensorDidCompleteAuthentication`; the reads that follow are then refused by the sensor.
    private func authenticateIfRequired(then: @escaping () -> Void) {
        guard state.isAuthorizationControlRequired, !isSecurityEstablished else {
            then()
            return
        }
        establishSecureSession { _ in then() }
    }

    private func readFeatureIfUnknown(then: @escaping () -> Void) {
        guard feature == nil else {
            loggingDelegate?.logConnectionEvent("feature already known for this sensor")
            then()
            return
        }
        getFeature { [weak self] result in
            if case .failure(let error) = result { self?.loggingDelegate?.logErrorEvent("feature read: \(error)") }
            then()
        }
    }

    /// The link is gone, or never came up. Reported to the delegate once per loss; BluetoothCommonKit can
    /// deliver the same disconnect through two paths.
    private func handleLinkLost(_ error: Error?) {
        let (wasReady, shouldReport): (Bool, Bool) = locked {
            let wasReady = _isReady
            _isReady = false
            let shouldReport = (wasReady || error != nil) && !_linkLossReported
            _linkLossReported = true
            return (wasReady, shouldReport)
        }
        _ = wasReady
        resetLinkState()
        if shouldReport { delegate?.sensorConnectionStatusChanged(self) }
    }

    /// Everything a lost or abandoned link invalidates: the session cache, the secure session (the key and
    /// nonce sequence cannot be trusted across a link loss), a key exchange in flight, and every waiting
    /// request. The Feature stays: it belongs to the sensor, not the link.
    private func resetLinkState() {
        sessionStartTime = nil
        let hadSecureSession = isSecurityEstablished || usesSecureChannel
        deleteStoredKey()
        usesSecureChannel = false
        _ = acControlPoint.getPendingProceduresAndReset()   // also clears procedureRunning
        acControlPoint.resetSegmentation()
        acData.resetSegmentation()
        failPending(.disconnected)
        if let completion = takeHandshakeCompletion() {
            completion(.failure(.disconnected))
        }
        if hadSecureSession {
            delegate?.sensorDidCompleteAuthentication(self, error: .disconnected)
        }
    }

    private func takeHandshakeCompletion() -> ProcedureResultCompletion? {
        locked {
            defer { _handshakeCompletion = nil }
            return _handshakeCompletion
        }
    }

    /// Drops the session key through the security manager so it also resets the sequence number and its
    /// first-nonce flag; resetting the sequence number alone leaves the even/odd nonce scheme on the wrong
    /// parity for the next exchange.
    public func deleteStoredKey() {
        securityManager.prepareForDeactivation()
    }
}

// MARK: - BluetoothManagerDelegate

extension ContinuousGlucoseMonitorService: BluetoothManagerDelegate {
    public func updatePeripheralConfigurationIfNeeded(_ manager: BluetoothManager, peripheralManager: PeripheralManager) { }

    public func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, isReadyWithError error: Error?) {
        loggingDelegate?.logConnectionEvent("error: \(String(describing: error))")
        if error == nil, isConnected {
            handleConnected()
        } else {
            handleLinkLost(error)
        }
    }

    public func bluetoothManager(_ manager: BluetoothManager, didDiscoverPeripheralWithName peripheralName: String?, identifier: UUID, advertisementData: [String: Any], signalStrength: NSNumber) {
        loggingDelegate?.logConnectionEvent("discovered \(peripheralName ?? "unnamed") \(identifier)")
        delegate?.sensor(self, didDiscoverSensorWithName: peripheralName, identifier: identifier, advertisementData: advertisementData, signalStrength: signalStrength)
    }

    /// Only the remembered sensor connects by itself; anything else is offered through the delegate.
    public func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any]?) -> Bool {
        let known = state.identifier == peripheral.identifier
        loggingDelegate?.logConnectionEvent("\(peripheral.identifier): \(known ? "known sensor, connecting" : "not the remembered sensor")")
        return known
    }

    public func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, didReceiveValue value: Data, fromCharactistic uuid: CBUUID) {
        switch uuid {
        case ACCharacteristicUUID.status.cbUUID:
            loggingDelegate?.logReceiveEvent("ACS status: \(String(describing: ACStatusDataHandler.handleData(value)))")
        case ACCharacteristicUUID.controlPoint.cbUUID:
            handleAuthorizationControlPointResponse(value)
        case ACCharacteristicUUID.dataOutIndicate.cbUUID, ACCharacteristicUUID.dataOutNotify.cbUUID:
            handleSecureResponse(value, from: uuid)
        default:
            handleValue(value, for: uuid)
        }
    }

    public func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, didEncounterError error: Error) {
        loggingDelegate?.logErrorEvent("\(error)")
        if let cbError = error as? CBError,
           [.peripheralDisconnected, .connectionTimeout, .connectionFailed].contains(cbError.code)
        {
            handleLinkLost(error)
        } else {
            delegate?.sensor(self, didEncounterError: Self.commError(from: error), forCharacteristic: nil)
        }
    }
}

// MARK: - Authorization Control

extension ContinuousGlucoseMonitorService: SecurityManagerDelegate, ACDataDataHandlerDelegate {
    /// Runs the ACS configuration reads and the ECDH key exchange over the AC Control Point. The ACS
    /// characteristics were subscribed during configuration; BluetoothCommonKit queues the requests and this
    /// feeds them one at a time.
    public func establishSecureSession(completion: @escaping ProcedureResultCompletion) {
        guard isConnected, let peripheralManager else {
            completion(.failure(.deviceNotReady))
            return
        }
        guard peripheralManager.peripheral?.getACSCharacteristicWithUUID(.controlPoint) != nil else {
            completion(.failure(.commandFailed("sensor does not offer the Authorization Control service")))
            return
        }
        guard beginHandshake(completion) else {
            completion(.failure(.procedureInProgress))
            return
        }
        loggingDelegate?.logSendEvent("starting key exchange")
        acControlPoint.queueConfigurationRequests()
        sendNextAuthorizationRequest()
    }

    /// Asks the sensor to drop the current key; the client forgets it when the response is Success.
    public func invalidateKey(completion: @escaping ProcedureResultCompletion) {
        guard isSecurityEstablished else {
            completion(.failure(.commandFailed("no secure session to invalidate")))
            return
        }
        guard beginHandshake(completion) else {
            completion(.failure(.procedureInProgress))
            return
        }
        acControlPoint.queueInvalidateKeyRequest()
        sendNextAuthorizationRequest()
    }

    /// Stores the completion unless an exchange is already running.
    private func beginHandshake(_ completion: @escaping ProcedureResultCompletion) -> Bool {
        locked {
            guard _handshakeCompletion == nil else { return false }
            _handshakeCompletion = completion
            return true
        }
    }

    /// Writes the next queued ACS request itself (the handler's own send keeps `procedureRunning` set after a
    /// failed write, which would leave the exchange hung), so a refusal or timeout fails the handshake.
    private func sendNextAuthorizationRequest() {
        guard !acControlPoint.procedureRunning else { return }
        guard let (request, _) = acControlPoint.nextRequestToSend() else {
            finishHandshake()
            return
        }
        guard let peripheralManager, let controlPoint = peripheralManager.peripheral?.getACSCharacteristicWithUUID(.controlPoint) else {
            failHandshake(.deviceNotReady)
            return
        }
        loggingDelegate?.logSendEvent("procedure \(String(describing: acControlPoint.procedureIDForNextRequest()))")
        acControlPoint.procedureRunning = true
        let segments = acControlPoint.segmentPayload(request)
        peripheralManager.perform { [weak self] peripheralManager in
            guard let self else { return }
            for segment in segments {
                do {
                    try peripheralManager.writeValue(segment, for: controlPoint, type: .withResponse, timeout: requestTimeout)
                } catch {
                    failHandshake(Self.commError(from: error))
                    return
                }
            }
        }
    }

    private func handleAuthorizationControlPointResponse(_ data: Data) {
        let (result, completion) = acControlPoint.handleSegmentedResponse(data)
        switch result {
        case .success:
            loggingDelegate?.logReceiveEvent("ACCP response: \(result)")
            (completion as? ProcedureResultCompletion)?(.success)
            sendNextAuthorizationRequest()
        case .failure(let error):
            if case .partialResponse = error { return }
            (completion as? ProcedureResultCompletion)?(.failure(error))
            failHandshake(error)
        }
    }

    private func finishHandshake() {
        guard let completion = takeHandshakeCompletion() else { return }
        if isSecurityEstablished {
            usesSecureChannel = true
            updateState { $0.uuidToHandleMap = acControlPoint.uuidToHandleMap }
            loggingDelegate?.logConnectionEvent("secure session established; CGM traffic now uses the secure channel")
            delegate?.sensorDidCompleteAuthentication(self, error: nil)
        } else {
            usesSecureChannel = false
            loggingDelegate?.logConnectionEvent("no secure session (key invalidated or exchange incomplete)")
        }
        completion(.success)
    }

    private func failHandshake(_ error: DeviceCommError) {
        loggingDelegate?.logErrorEvent("key exchange failed: \(error)")
        _ = acControlPoint.getPendingProceduresAndReset()
        deleteStoredKey()
        usesSecureChannel = false
        let completion = takeHandshakeCompletion()
        delegate?.sensorDidCompleteAuthentication(self, error: .authenticationFailed)
        completion?(.failure(error))
    }

    private func handleSecureResponse(_ data: Data, from source: CBUUID) {
        switch acData.handleSecureResponse(data) {
        case .success(let resource):
            guard let uuid = characteristicUUID(for: resource.resourceHandle) else {
                loggingDelegate?.logErrorEvent("secure response for unknown resource handle \(resource.resourceHandle)")
                return
            }
            // Refusals arrive as ATT errors on the AC Data In write, so anything decrypted here is a value.
            handleValue(resource.response, for: uuid)
        case .failure(let error):
            if case .partialResponse = error { return }
            loggingDelegate?.logErrorEvent("secure response error: \(error)")
            // Only requests that went over the secure channel can be waiting on this frame; a plain control
            // point write is still owed its own indication.
            failPending(error) { [weak self] uuid in self?.resourceHandle(for: uuid) != nil }
        }
    }

    // MARK: SecurityManagerDelegate

    public func securityManagerDidEstablishedSecurity(_ securityManager: SecurityManager) {
        updateState { $0.uuidToHandleMap = acControlPoint.uuidToHandleMap }
    }

    public func securityManagerDidUpdateConfiguration(_ securityManager: SecurityManager) {
        updateState { $0.securityManagerConfiguration = securityManager.configuration }
    }

    // MARK: ACDataDataHandlerDelegate

    public func didEncounterE2ECounterError() {
        loggingDelegate?.logErrorEvent("E2E counter error on the secure channel")
        reconnectToResolveCounterError()
    }

    public func didEncounterSegmentCounterError() {
        loggingDelegate?.logErrorEvent("segment counter error on the secure channel")
        reconnectToResolveCounterError()
    }

    /// As the pump kit does: the counters cannot be resynchronised in place, so the link is dropped and
    /// BluetoothCommonKit reconnects; the key exchange runs again on the new link.
    private func reconnectToResolveCounterError() {
        loggingDelegate?.logConnectionEvent("reconnecting to resolve the counter error")
        failPending(.disconnected)
        bluetoothManager.disconnect()
        handleLinkLost(nil)
    }
}

extension CGMCharacteristicUUID {
    init?(cbUUID: CBUUID) {
        self.init(rawValue: cbUUID.uuidString.lowercased())
    }
}
