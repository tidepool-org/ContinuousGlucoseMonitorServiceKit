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
//  The RACP is the exception: its answers name the request op code they belong to, so a running procedure
//  and the Abort Operation that cancels it wait side by side. Callbacks arrive on two queues (the
//  peripheral's and the central manager's), so the mutable fields sit behind one lock and the delegate is
//  never called while it is held.

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

    /// How long a request waits for its answer (a control point indication or a secure response) after the
    /// write went out. BluetoothCommonKit's AC Data In send swallows ATT refusals, so without this a refused
    /// secure request would leave its characteristic busy forever. For RACP the clock restarts on every
    /// measurement notification, because a Report Stored Records transfer legitimately runs for minutes.
    public var responseTimeout: TimeInterval = 10

    /// Timers for pending answers; their own queue so a timeout cannot be starved by the peripheral's.
    private let timeoutQueue = DispatchQueue(label: "org.tidepool.ContinuousGlucoseMonitorServiceKit.timeouts")

    /// Derived session key (SecurityManagerDelegate storage); nil until a key exchange completes. A host that
    /// persists pairing overrides this together with the nonce sequence number in `state`.
    open var sharedKeyData: Data?

    // MARK: Locked state

    private let lock = NSLock()
    private var _state: CGMSensorState
    private var _sessionStartTime: CGMSessionStartTime?
    private var _usesSecureChannel = false
    /// From AC Status: restriction map ID 0 means the sensor serves CGMS plainly and AC Data In refuses
    /// requests; anything else means the CGMS characteristics are protected resources. nil until read.
    private var _resourcesAreProtected: Bool?
    private var _isReady = false
    private var _linkLossReported = false
    /// Bumped each time a link's setup starts, so a setup chain left over from an earlier link cannot report
    /// ready on the current one.
    private var _setupGeneration = 0
    private var _handshakeCompletion: ProcedureResultCompletion?
    private var _handshakeTimeout: DispatchWorkItem?
    /// One per characteristic, like the control points they answer: a second request to a busy
    /// characteristic is refused with Procedure In Progress rather than silently replacing the first.
    private var _pending: [PendingKey: PendingRequest] = [:]

    private struct PendingRequest {
        let completion: ProcedureCompletion<Data>
        var timeout: DispatchWorkItem
    }

    /// What a waiting completion is keyed on. Every characteristic has one slot, except the RACP, whose
    /// answers carry the request op code they belong to (a Response Code names it; Number of Stored Records
    /// answers Report Number of Stored Records), so an Abort Operation can wait next to the procedure it cancels.
    struct PendingKey: Hashable, CustomStringConvertible {
        let uuid: CBUUID
        /// The RACP request op code; nil for every other characteristic.
        let racpOpcode: UInt8?

        init(_ uuid: CBUUID, racpOpcode: UInt8? = nil) {
            self.uuid = uuid
            self.racpOpcode = racpOpcode
        }

        static func racp(_ opcode: CGMRACPOpcode) -> PendingKey {
            PendingKey(CGMCharacteristicUUID.recordAccessControlPoint.cbUUID, racpOpcode: opcode.rawValue)
        }

        /// An RACP request other than Abort: the sensor runs one of these at a time.
        var isRACPProcedure: Bool {
            guard let racpOpcode else { return false }
            return racpOpcode != CGMRACPOpcode.abortOperation.rawValue
        }

        var description: String {
            guard let racpOpcode else { return uuid.uuidString }
            return "\(uuid.uuidString) \(CGMRACPOpcode(rawValue: racpOpcode)?.name ?? "op code 0x\(String(racpOpcode, radix: 16))")"
        }
    }

    /// The RACP is keyed by the request's op code (its first octet); everything else by the characteristic.
    private func pendingKey(for characteristic: CGMCharacteristicUUID, request: Data?) -> PendingKey {
        guard characteristic == .recordAccessControlPoint, let opcode = request?.first else {
            return PendingKey(characteristic.cbUUID)
        }
        return PendingKey(characteristic.cbUUID, racpOpcode: opcode)
    }

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

    public var areResourcesProtected: Bool { locked { _resourcesAreProtected ?? false } }

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
        let key = pendingKey(for: characteristic, request: request)
        if answeredByIndication, !setPending(key, completion) {
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
                    takePending(key)?(.failure(commError))
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
        let key = pendingKey(for: characteristic, request: request)
        guard setPending(key, completion) else {
            completion(.failure(.procedureInProgress))
            return
        }
        peripheralManager.perform { [weak self] peripheralManager in
            guard let self else { return }
            loggingDelegate?.logSendEvent("secure \(request == nil ? "read" : "write") \(characteristic.name) via handle \(handle)")
            if case .failure(let error) = acData.sendRequest(request, resourceHandle: handle, peripherialManager: peripheralManager, timeout: requestTimeout) {
                takePending(key)?(.failure(error))
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

    /// Registers the completion and arms its response timer; false when the characteristic is already busy.
    /// On the RACP, busy means another procedure is running (the sensor would refuse a second one, CGMS
    /// §3.6.3.6); Abort Operation is exempt, since cancelling the running procedure is what it is for.
    func setPending(_ key: PendingKey, _ completion: @escaping ProcedureCompletion<Data>) -> Bool {
        let timeout = makeTimeout(for: key)
        let armed: Bool = locked {
            guard _pending[key] == nil else { return false }
            if key.isRACPProcedure, _pending.keys.contains(where: \.isRACPProcedure) { return false }
            _pending[key] = PendingRequest(completion: completion, timeout: timeout)
            return true
        }
        if armed {
            timeoutQueue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
        } else {
            timeout.cancel()
        }
        return armed
    }

    /// Removes the completion and disarms its timer; nil when nothing was waiting.
    func takePending(_ key: PendingKey) -> ProcedureCompletion<Data>? {
        let pending: PendingRequest? = locked { _pending.removeValue(forKey: key) }
        pending?.timeout.cancel()
        return pending?.completion
    }

    /// Restarts the response timer of a request that is still being answered (an RACP report in progress).
    private func touchPending(_ key: PendingKey) {
        let timeout = makeTimeout(for: key)
        let rearmed: Bool = locked {
            guard var pending = _pending[key] else { return false }
            pending.timeout.cancel()
            pending.timeout = timeout
            _pending[key] = pending
            return true
        }
        if rearmed {
            timeoutQueue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
        } else {
            timeout.cancel()
        }
    }

    private func makeTimeout(for key: PendingKey) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self, let completion = takePending(key) else { return }
            loggingDelegate?.logErrorEvent("no answer from \(key) within \(responseTimeout) s")
            completion(.failure(.procedureTimeout))
        }
    }

    /// Fails the waiting completions that `matching` selects (all of them by default), outside the lock.
    private func failPending(_ error: DeviceCommError, where matching: (PendingKey) -> Bool = { _ in true }) {
        let failed: [PendingRequest] = locked {
            let selected = _pending.filter { matching($0.key) }
            for key in selected.keys { _pending.removeValue(forKey: key) }
            return Array(selected.values)
        }
        for pending in failed {
            pending.timeout.cancel()
            pending.completion(.failure(error))
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
            // Records of an RACP report in progress keep that request alive until its Response Code arrives.
            touchPending(.racp(.reportStoredRecords))
            switch Self.decode({ try CGMMeasurementRecord.decodeRecords(data, e2eCRC: isE2EProtectionSupported) }) {
            case .success(let records):
                delegate?.sensor(self, didReceiveMeasurements: records)
            case .failure(let error):
                delegate?.sensor(self, didEncounterError: error, forCharacteristic: uuid)
            }
        case CGMCharacteristicUUID.recordAccessControlPoint.cbUUID:
            handleRACPIndication(data, completesPending: completesPending)
            return
        case CGMCharacteristicUUID.specificOpsControlPoint.cbUUID:
            if case .success(let response) = Self.decode({ try CGMSpecificOpsResponse(data: data, e2eCRC: isE2EProtectionSupported) }) {
                delegate?.sensor(self, didReceiveSpecificOpsResponse: response)
            }
        default:
            break
        }

        if completesPending {
            takePending(PendingKey(uuid))?(.success(data))
        }
    }

    /// An RACP indication completes the request whose op code it names. An Abort Operation that succeeded
    /// also ends the procedure it cancelled: the sensor sends no Response Code for an aborted procedure (GLS
    /// RACP), so that request completes with Procedure Not Completed instead of waiting for its timeout.
    private func handleRACPIndication(_ data: Data, completesPending: Bool) {
        let uuid = CGMCharacteristicUUID.recordAccessControlPoint.cbUUID
        switch Self.decode({ try CGMRACPResponse(data: data) }) {
        case .success(let response):
            delegate?.sensor(self, didReceiveRACPResponse: response)
            guard completesPending else { return }
            takePending(PendingKey(uuid, racpOpcode: response.requestOpcode))?(.success(data))
            if case let .responseCode(request, code) = response,
               request == CGMRACPOpcode.abortOperation.rawValue, code == CGMRACPResponseCode.success.rawValue
            {
                failPending(.procedureNotCompleted) { $0.uuid == uuid }
            }
        case .failure(let error):
            // An indication that cannot be decoded names no request, so everything waiting on the RACP hears it.
            if completesPending { failPending(error) { $0.uuid == uuid } }
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
    /// then the Session Start Time for calibration stamping, then ready is reported. Ready means every step
    /// succeeded on the link it started on: a failed step ends the setup (reported through
    /// `sensor(_:didEncounterError:forCharacteristic:)`, or as the connection change when the link itself went),
    /// and a chain outlived by its link stops where it is. A measurement that lands before a first-ever Feature
    /// read is decoded without the CRC check; that window closes within the first second of pairing.
    private func handleConnected() {
        let (alreadyReady, generation): (Bool, Int) = locked {
            defer { _isReady = true; _linkLossReported = false }
            if !_isReady { _setupGeneration += 1 }
            return (_isReady, _setupGeneration)   // configuration can complete more than once on one link
        }
        guard !alreadyReady else { return }
        if let peripheral = peripheralManager?.peripheral {
            updateState {
                $0.identifier = peripheral.identifier
                $0.name = peripheral.name
            }
        }
        delegate?.sensorConnectionStatusChanged(self)
        readAuthorizationStatus { [weak self] result in
            self?.continueSetup(onLink: generation, step: "AC Status read", result) {
                self?.authenticateIfRequired { result in
                    self?.continueSetup(onLink: generation, step: "key exchange", result) {
                        self?.readFeatureIfUnknown { result in
                            self?.continueSetup(onLink: generation, step: "Feature read", result) {
                                self?.getSessionStartTime { result in
                                    self?.continueSetup(onLink: generation, step: "Session Start Time read", result.map { _ in () }) {
                                        guard let self else { return }
                                        self.loggingDelegate?.logConnectionEvent("sensor ready")
                                        self.delegate?.sensorIsReady(self)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Runs `next` when the step succeeded and the link that started the setup is still the current one.
    private func continueSetup(onLink generation: Int, step: String, _ result: DeviceCommResult<Void>, next: () -> Void) {
        let isCurrentLink: Bool = locked { _isReady && _setupGeneration == generation }
        guard isCurrentLink else {
            loggingDelegate?.logConnectionEvent("\(step) finished after its link went; setup abandoned")
            return
        }
        switch result {
        case .success:
            next()
        case .failure(let error):
            loggingDelegate?.logErrorEvent("\(step) failed: \(error); the sensor will not be reported ready")
            // A lost link was already reported as a connection change.
            if error != .disconnected {
                delegate?.sensor(self, didEncounterError: error, forCharacteristic: nil)
            }
        }
    }

    /// AC Status says whether the sensor protects its CGMS characteristics right now, so it is read before
    /// anything else and decides both the key exchange and the channel. A sensor without ACS leaves the
    /// stored answer alone.
    private func readAuthorizationStatus(then: @escaping ProcedureResultCompletion) {
        guard let peripheralManager, peripheralManager.peripheral?.getACSCharacteristicWithUUID(.status) != nil else {
            then(.success)
            return
        }
        peripheralManager.perform { [weak self] peripheralManager in
            guard let self else { return }
            do {
                let status = try peripheralManager.readACSStatus(timeout: requestTimeout)
                handleAuthorizationStatus(restrictionMapID: status.currentRestrictionMapID, flags: status.status)
                then(.success)
            } catch {
                then(.failure(Self.commError(from: error)))
            }
        }
    }

    /// Runs the key exchange when the sensor protects its resources and no session key is held, as the pump
    /// kit checks `applicationSecurityEstablished` before its first status read. A failed exchange is also
    /// reported through `sensorDidCompleteAuthentication`.
    private func authenticateIfRequired(then: @escaping ProcedureResultCompletion) {
        guard state.isAuthorizationControlRequired, !isSecurityEstablished else {
            then(.success)
            return
        }
        establishSecureSession(completion: then)
    }

    /// Read at connection and indicated whenever the sensor flips protection. Protection decides whether the
    /// exchange is required; protection plus a held key decides the channel, because AC Data In answers
    /// Request Not Supported while the restriction map ID is 0, even to a collector that holds the key.
    private func handleAuthorizationStatus(restrictionMapID: Int, flags: StatusFlag) {
        let protected = restrictionMapID != 0
        loggingDelegate?.logReceiveEvent("ACS status: restriction map \(restrictionMapID), flags \(flags); resources \(protected ? "protected" : "open")")
        locked { _resourcesAreProtected = protected }
        updateState { $0.isAuthorizationControlRequired = protected }
        applySecureChannelPolicy()
    }

    /// Secure channel on exactly when the sensor protects its resources and this collector holds the key. A
    /// tester can still flip `usesSecureChannel` by hand afterwards to watch the sensor refuse the other path.
    private func applySecureChannelPolicy() {
        let shouldUse = isSecurityEstablished && areResourcesProtected
        let changed: Bool = locked {
            guard _usesSecureChannel != shouldUse else { return false }
            _usesSecureChannel = shouldUse
            return true
        }
        guard changed else { return }
        loggingDelegate?.logConnectionEvent("CGM traffic now uses the \(shouldUse ? "secure channel" : "plain characteristics")")
        delegate?.sensorDidUpdateSecurity(self)
    }

    private func readFeatureIfUnknown(then: @escaping ProcedureResultCompletion) {
        guard feature == nil else {
            loggingDelegate?.logConnectionEvent("feature already known for this sensor")
            then(.success)
            return
        }
        getFeature { result in then(result.map { _ in () }) }
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
        let (completion, timeout): (ProcedureResultCompletion?, DispatchWorkItem?) = locked {
            defer { _handshakeCompletion = nil; _handshakeTimeout = nil }
            return (_handshakeCompletion, _handshakeTimeout)
        }
        timeout?.cancel()
        return completion
    }

    /// Every key-exchange step is a write answered by an AC Control Point indication; each one gets its own
    /// wait, so a sensor that stops answering mid-exchange fails the handshake instead of hanging it.
    private func armHandshakeTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, handshakeCompletion != nil else { return }
            failHandshake(.procedureTimeout)
        }
        let previous: DispatchWorkItem? = locked {
            defer { _handshakeTimeout = timeout }
            return _handshakeTimeout
        }
        previous?.cancel()
        timeoutQueue.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
    }

    /// Drops the session key through the security manager so it also resets the sequence number and its
    /// first-nonce flag; resetting the sequence number alone leaves the even/odd nonce scheme on the wrong
    /// parity for the next exchange. With no key held, the next exchange has to derive one: BluetoothCommonKit
    /// only queues the ECDH steps while `willExchangeParentKey` is set, and clears it after the first exchange.
    public func deleteStoredKey() {
        securityManager.prepareForDeactivation()
        acControlPoint.willExchangeParentKey = true
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
            if let status = ACStatusDataHandler.handleData(value) {
                handleAuthorizationStatus(restrictionMapID: status.currentRestrictionMapID, flags: status.status)
            } else {
                loggingDelegate?.logErrorEvent("ACS status: unexpected value \(value.hexadecimalString)")
            }
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
        // A full exchange every time this is asked for, also when a key is still held (a tester re-pairing
        // with a new sensor key); the handler would otherwise only re-sync the nonce after its first run.
        acControlPoint.willExchangeParentKey = true
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
        armHandshakeTimeout()
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
            updateState { $0.uuidToHandleMap = acControlPoint.uuidToHandleMap }
            loggingDelegate?.logConnectionEvent("secure session established")
            delegate?.sensorDidCompleteAuthentication(self, error: nil)
        } else {
            loggingDelegate?.logConnectionEvent("no secure session (key invalidated or exchange incomplete)")
        }
        applySecureChannelPolicy()
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
            failPending(error) { [weak self] key in self?.resourceHandle(for: key.uuid) != nil }
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
