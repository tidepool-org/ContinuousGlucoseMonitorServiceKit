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
//  Scope so far: the full CGMS GATT layout, periodic measurements from a glucose trace notified at the CGM
//  Communication Interval, a record database served through the RACP, and every CGMCP procedure of Table 3.6
//  (communication interval, calibration, alert levels, device specific alert reset, session start/stop).
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
            // An alert family switched off must leave Status at once, not at the next reading.
            refreshAlertStatus()
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

    // MARK: Record database (CGMS §3.6)

    /// Every measurement of the current session, for RACP reports and backfill after a link loss (HYD-G-015).
    /// Cleared when a session starts (CGMS §3.4.5). Set `capacity` to change how much history is kept.
    public var recordStore = CGMRecordStore() {
        didSet {
            guard oldValue != recordStore else { return }
            notifyDelegate()
        }
    }

    /// Records packed into one CGM Measurement notification during an RACP report (HYD-G-013). The
    /// collector's ATT MTU must fit them; iOS negotiates well above the 23-octet default.
    public var recordsPerNotification = 1 {
        didSet { recordsPerNotification = max(1, recordsPerNotification) }
    }

    /// Set when a Report Stored Records transfer was queued; the procedure is in progress until the
    /// message queue has drained (CGMS §3.6.3.6 Procedure Already In Progress).
    private var racpReportQueued = false

    // MARK: CGM Specific Ops settings (CGMS §3.7)

    /// Fastest cadence the sensor offers; Set CGM Communication Interval 0xFF selects it (§3.7.2.1).
    public static let fastestMeasurementInterval: TimeInterval = 5

    /// Measurement and communication cadence are one setting (Nate, 2026-10-14): every reading is notified
    /// as it is taken, and the CGMCP Communication Interval changes `measurementInterval`. Off (operand 0x00)
    /// disables the notifications only (§3.7.2.1): the sensor keeps measuring at the current cadence and
    /// stores the readings for RACP, as a real sensor does while the collector is away.
    public var isPeriodicCommunicationEnabled = true {
        didSet {
            guard oldValue != isPeriodicCommunicationEnabled else { return }
            notifyDelegate()
        }
    }

    /// What Get CGM Communication Interval answers: 0x00 while off, 0xFF below one minute, else whole minutes.
    public var communicationInterval: UInt8 {
        guard isPeriodicCommunicationEnabled else { return CGMCommunicationInterval.periodicDisabled }
        guard measurementInterval >= 60 else { return CGMCommunicationInterval.fastestSupported }
        return UInt8(clamping: Int(measurementInterval / 60))
    }

    /// Applies a Set CGM Communication Interval operand (§3.7.2.1). Observers hear one consistent update.
    public func setCommunicationInterval(_ minutes: UInt8) {
        batchingDelegateUpdates {
            switch minutes {
            case CGMCommunicationInterval.periodicDisabled:
                isPeriodicCommunicationEnabled = false
            case CGMCommunicationInterval.fastestSupported:
                measurementInterval = Self.fastestMeasurementInterval
                isPeriodicCommunicationEnabled = true
            default:
                measurementInterval = TimeInterval(minutes) * 60
                isPeriodicCommunicationEnabled = true
            }
        }
    }

    /// Thresholds set through the CGMCP; every reading is compared against them (§3.7.2.3–3.7.2.6).
    public var alertLevels = CGMAlertLevels() {
        didSet {
            guard oldValue != alertLevels else { return }
            refreshAlertStatus()
            notifyDelegate()
        }
    }

    /// Calibration Data Records stored by Set Glucose Calibration Value; cleared when a session starts.
    public var calibrationStore = CGMCalibrationStore() {
        didSet {
            guard oldValue != calibrationStore else { return }
            notifyDelegate()
        }
    }

    /// How often the sensor asks for calibration; written into each stored record's Next Calibration Time
    /// (§3.7.2.2). Once per session by default (Nate, 2026-10-14).
    public var calibrationSchedule: CGMCalibrationSchedule = .oncePerSession {
        didSet {
            guard oldValue != calibrationSchedule else { return }
            notifyDelegate()
        }
    }

    /// Minutes before Next Calibration Time at which Calibration Recommended is raised (Nate, 2026-10-14:
    /// 20 min ahead). Calibration Required follows once the time itself has passed.
    public var calibrationRecommendedLeadMinutes: UInt16 = 20

    /// Session minutes a once-per-session recommendation may go unanswered before it becomes Calibration
    /// Required (Nate, 2026-10-14: 3 h). Periodic schedules use their own interval instead.
    public var calibrationRequiredAfterMinutes: UInt16 = 180

    /// Calibration Recommended or Required right now, derived from the schedule and the last stored
    /// calibration's Next Calibration Time against the current Time Offset. Clock-driven, so Status and each
    /// record pick it up without a timer.
    public var calibrationStatus: CGMSensorStatusAnnunciation {
        calibrationStatus(at: timeOffset)
    }

    /// The calibration bits that apply at `offset` minutes into the session, so a backfilled record carries
    /// the status of its own moment rather than of the clock. With nothing stored yet (fresh launch, new
    /// session) the schedule's initial status applies (recommended for most; revisit if QA or design object).
    /// Nothing when the Feature says calibration is unsupported.
    public func calibrationStatus(at offset: UInt16) -> CGMSensorStatusAnnunciation {
        guard feature.flags.contains(.calibration) else { return [] }
        guard let next = calibrationStore.last?.nextCalibrationTime else {
            // A recommendation ignored past the schedule's first due time becomes a requirement.
            if let due = calibrationSchedule.firstCalibrationRequiredAfter(graceMinutes: calibrationRequiredAfterMinutes), offset >= due {
                return .calibrationRequired
            }
            return calibrationSchedule.initialStatus
        }
        guard next != CGMCalibrationSchedule.noFurtherCalibration else { return [] }
        if Int(offset) >= Int(next) { return .calibrationRequired }
        if Int(offset) >= Int(next) - Int(calibrationSchedule.recommendedLead(calibrationRecommendedLeadMinutes)) { return .calibrationRecommended }
        return []
    }

    /// Annunciation bits the latest reading tripped against `alertLevels`; recomputed on every measurement.
    public private(set) var alertStatus: CGMSensorStatusAnnunciation = []

    // MARK: Lifecycle (CGM-DESIGN §Lifecycle)

    /// Seconds after Start Session before readings begin (TBD-03 warm-up). Editable while a warm-up is in
    /// progress: shortening it below the elapsed time ends the warm-up at once. Zero in the kit so tests run
    /// without waiting; the simulator app defaults to one minute.
    public var warmupDuration: TimeInterval = 0 {
        didSet {
            guard oldValue != warmupDuration else { return }
            // Entering or leaving the warm-up moves the cadence: it pauses while warming up and starts
            // fresh when the warm-up ends. A change that leaves the state alone keeps the running cadence.
            let wasWarmingUp = sessionState == .running && now().timeIntervalSince(sessionStartedAt) < oldValue
            if wasWarmingUp != isWarmingUp { scheduleMeasurementTimer() }
            scheduleWarmupTimer()
            notifyDelegate()
        }
    }

    /// One-shot timer for the end of the warm-up: the first reading goes out then, and the measurement
    /// cadence starts from that moment, so a 1 min warm-up on a 5 min cadence reads at 1:00, 6:00, 11:00.
    private var warmupTimer: Timer?

    private func scheduleWarmupTimer() {
        warmupTimer?.invalidate()
        warmupTimer = nil
        guard let end = warmupEndDate else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.warmupTimer = nil
            self.takeMeasurement()
            self.scheduleMeasurementTimer()
            self.notifyDelegate()
        }
        RunLoop.main.add(timer, forMode: .common)
        warmupTimer = timer
    }

    /// True while a running session is still inside its warm-up: the timer ticks but no reading is produced.
    public var isWarmingUp: Bool {
        sessionState == .running && now().timeIntervalSince(sessionStartedAt) < warmupDuration
    }

    /// When the current warm-up ends; nil when none is in progress.
    public var warmupEndDate: Date? {
        isWarmingUp ? sessionStartedAt.addingTimeInterval(warmupDuration) : nil
    }

    /// Physical condition the tester has inflicted; changes through `failSensor`, `beginTemporaryIssue`,
    /// `resolveTemporaryIssue` and `replaceSensor`.
    public private(set) var condition: CGMSensorCondition = .healthy

    /// Glucose the sensor can quantify (HYD-G-003). With Sensor Result High-Low Detection in the Feature, a
    /// reading outside is reported at the boundary with the matching Device Can Process bit.
    public var sensorRange: ClosedRange<Double> = 40...400 {
        didSet {
            guard oldValue != sensorRange else { return }
            notifyDelegate()
        }
    }

    /// Device Can Process bits of the latest reading.
    public private(set) var rangeStatus: CGMSensorStatusAnnunciation = []

    /// Lifecycle actions in order, newest last, capped at `lifecycleEventLimit`.
    public private(set) var lifecycleEvents: [CGMLifecycleEvent] = []
    public static let lifecycleEventLimit = 200

    public private(set) var lastMeasurement: CGMMeasurementRecord?

    /// Measurements taken in the current session; lets a tester see activity when the value barely moves.
    public private(set) var measurementCount = 0

    /// When the cadence next fires: a reading if the sensor can take one, a status-only notification otherwise.
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
        warmupTimer?.invalidate()
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
        sensorStatus(at: timeOffset)
    }

    /// Status as of `offset` minutes into the session: the tester's bits, the alert bits of the latest
    /// reading, and the calibration bits that applied at that moment.
    private func sensorStatus(at offset: UInt16) -> CGMSensorStatusAnnunciation {
        // Time Synchronization Required is tester-controlled: the sensor knows its own start time.
        var status = manualSensorStatus.union(alertStatus).union(rangeStatus).union(calibrationStatus(at: offset))
        if sessionState != .running { status.insert(.sessionStopped) }
        // The condition shows only through the fault bits the Feature advertises.
        switch condition {
        case .healthy: break
        case .impaired: if feature.flags.contains(.generalDeviceFault) { status.insert(.generalDeviceFault) }
        case .failed: if feature.flags.contains(.sensorMalfunctionDetection) { status.insert(.sensorMalfunction) }
        }
        return status
    }

    public var status: CGMStatus {
        CGMStatus(timeOffset: timeOffset, sensorStatus: sensorStatus)
    }

    /// What a read of 0x2AAA returns; before the first session it falls back to the power-on time.
    public var effectiveSessionStartTime: CGMSessionStartTime {
        sessionStartTime ?? CGMSessionStartTime(date: sessionStartedAt, timeZone: .current)
    }

    // MARK: - Session control (tester UI and CGMCP)

    /// Starts a new session: Time Offset restarts at 0, Session Start Time is taken from the device clock and
    /// the warm-up begins. Refused while the sensor has failed (HYD-G-006: terminal until replaced), which
    /// is recorded as a rejected lifecycle event. Returns whether the session started.
    @discardableResult
    public func startSession(source: CGMLifecycleEvent.Source = .tester) -> Bool {
        guard condition != .failed else {
            recordLifecycle(.sessionStarted, source: source, accepted: false, note: "sensor failed; replace it first")
            return false
        }
        batchingDelegateUpdates {
            sessionStartedAt = now()
            sessionStoppedAt = nil
            sessionStartTime = CGMSessionStartTime(date: sessionStartedAt, timeZone: .current)
            sessionStartTimeSetByCollector = false
            lastMeasurement = nil
            measurementCount = 0
            scenarioIndex = 0
            recordStore.removeAll()   // CGMS §3.4.5: a new session clears the measurement database
            racpReportQueued = false
            calibrationStore.removeAll()   // §3.7.2.8: all data from the previous session is deleted
            alertStatus = []
            rangeStatus = []
            sessionState = .running
            ConsoleOut.shared.logMessage(message: "\(#function): session started at \(sessionStartedAt)")
            scheduleMeasurementTimer()
            scheduleWarmupTimer()
            recordLifecycle(.sessionStarted, source: source)
        }
        return true
    }

    /// Stops the running session (CGMS §3.7.2.9; TBD-08). Returns false, and records the rejection, when no
    /// session is running.
    @discardableResult
    public func stopSession(source: CGMLifecycleEvent.Source = .tester) -> Bool {
        stopSession(source: source, kind: .sessionStopped)
    }

    private func stopSession(source: CGMLifecycleEvent.Source, kind: CGMLifecycleEvent.Kind) -> Bool {
        guard sessionState == .running else {
            recordLifecycle(kind, source: source, accepted: false, note: "no session running")
            return false
        }
        batchingDelegateUpdates {
            sessionStoppedAt = now()
            sessionState = .stopped
            // The cadence keeps ticking with status-only notifications (Session Stopped bit).
            warmupTimer?.invalidate()
            warmupTimer = nil
            ConsoleOut.shared.logMessage(message: "\(#function): session stopped at time offset \(timeOffset)")
            recordLifecycle(kind, source: source)
        }
        return true
    }

    // MARK: - Sensor condition (tester UI)

    /// HYD-G-006: a terminal failure. One final record with NaN glucose and Sensor Malfunction goes out so
    /// the collector learns of it, then readings stop; Status keeps the bit and only `replaceSensor()`
    /// recovers. The session stays as it was so RACP can still serve what was stored.
    public func failSensor() {
        guard condition != .failed else { return }
        batchingDelegateUpdates {
            condition = .failed
            recordLifecycle(.sensorFailed, source: .tester)
            reportConditionChange()
        }
    }

    /// TBD-05: a recoverable issue. Readings continue with NaN glucose, zero quality and General Device
    /// Fault, starting with one sent immediately.
    public func beginTemporaryIssue() {
        guard condition == .healthy else { return }
        batchingDelegateUpdates {
            condition = .impaired
            recordLifecycle(.temporaryIssueBegan, source: .tester)
            reportConditionChange()
        }
    }

    public func resolveTemporaryIssue() {
        guard condition == .impaired else { return }
        batchingDelegateUpdates {
            condition = .healthy
            recordLifecycle(.temporaryIssueResolved, source: .tester)
            reportConditionChange()
        }
    }

    /// TBD-07: a new sensor. Clears any failure or issue and starts a fresh session (new warm-up, empty
    /// record and calibration databases). A collector learns of it through Status and the measurements.
    public func replaceSensor() {
        batchingDelegateUpdates {
            condition = .healthy
            recordLifecycle(.sensorReplaced, source: .tester)
            startSession(source: .tester)
        }
    }

    private func recordLifecycle(_ kind: CGMLifecycleEvent.Kind, source: CGMLifecycleEvent.Source, accepted: Bool = true, note: String? = nil) {
        let event = CGMLifecycleEvent(date: now(), kind: kind, source: source, accepted: accepted, collectorSubscribed: isMeasurementNotificationConfigured, timeOffset: timeOffset, note: note)
        lifecycleEvents.append(event)
        if lifecycleEvents.count > Self.lifecycleEventLimit {
            lifecycleEvents.removeFirst(lifecycleEvents.count - Self.lifecycleEventLimit)
        }
        ConsoleOut.shared.logMessage(message: "lifecycle: \(event)")
        notifyDelegate()
    }

    // MARK: - Measurements

    /// Samples the trace, records the result and notifies a subscribed collector (CGMS §3.1.1 periodic
    /// notification). Also callable from the tester UI for an out-of-cadence reading.
    @discardableResult
    public func takeMeasurement() -> CGMMeasurementRecord? {
        guard sessionState == .running else { return nil }
        // HYD-G-009: the session ends by itself once its run time has elapsed.
        if Int(timeOffset) >= Int(sessionRunTime.hours) * 60 {
            _ = stopSession(source: .sensor, kind: .sessionExpired)
            return nil
        }
        // TBD-03: no reading during warm-up. HYD-G-006: a failed sensor produces no readings; the cadence
        // keeps sending status-only notifications in both cases.
        guard !isWarmingUp, condition != .failed else { return nil }
        return captureReading()
    }

    /// Takes one reading in the current condition, stores it and notifies it. CGM Status cannot be notified
    /// (read only in CGMS Table 3.1), so a record is the only way a condition change reaches the collector;
    /// `failSensor` and the temporary-issue transitions call this directly to report at once.
    @discardableResult
    private func captureReading() -> CGMMeasurementRecord {
        let record = makeRecord(elapsed: now().timeIntervalSince(sessionStartedAt), timeOffset: timeOffset)
        lastMeasurement = record
        measurementCount += 1
        ConsoleOut.shared.logMessage(message: "\(#function) #\(measurementCount): \(record)")

        recordStore.append(record)   // also notifies the delegate
        // §3.7.2.1: with periodic communication off the reading is stored for RACP only.
        if isPeriodicCommunicationEnabled { notifyMeasurements([record]) }
        return record
    }

    /// A condition change is reported to the collector at once rather than at the next tick: a reading when
    /// the sensor can still produce one, otherwise a status-only notification carrying the new bits.
    private func reportConditionChange() {
        if sessionState == .running, !isWarmingUp, condition != .failed {
            captureReading()
        } else {
            notifyStatusRecord()
        }
    }

    /// Re-evaluates the latest reading when the levels change, so Status reflects the new thresholds
    /// before the next measurement.
    private func refreshAlertStatus() {
        guard let last = lastMeasurement else {
            alertStatus = []
            return
        }
        alertStatus = alertLevels.annunciation(glucose: last.glucoseConcentration, trend: last.trend, feature: feature.flags)
    }

    /// Fills the database as if the sensor had been running unattended for `duration` (HYD-G-015 test aid):
    /// the session start moves back by that much, so Time Offset jumps, and one record per measurement
    /// interval is generated from the glucose source for the gap. Nothing is notified, exactly as when the
    /// collector is out of range; it learns about the records through RACP. Returns how many were added.
    @discardableResult
    public func backfill(duration: TimeInterval) -> Int {
        guard sessionState == .running, duration > 0 else { return 0 }
        let count = Int(duration / measurementInterval)
        guard count > 0 else { return 0 }

        let previousElapsed = now().timeIntervalSince(sessionStartedAt)
        sessionStartedAt = sessionStartedAt.addingTimeInterval(-duration)
        if let start = sessionStartTime {
            // Keep Session Start Time + Time Offset pointing at the same wall-clock instants.
            sessionStartTime = CGMSessionStartTime(date: start.date.addingTimeInterval(-duration), timeZoneOffset: start.timeZoneOffset, dstOffset: start.dstOffset)
        }

        // Build in a local copy so observers hear about the batch once, not per record.
        var store = recordStore
        for step in 1...count {
            let elapsed = previousElapsed + Double(step) * measurementInterval
            let record = makeRecord(elapsed: elapsed, timeOffset: UInt16(clamping: Int(elapsed / 60)))
            store.append(record)
            lastMeasurement = record
        }
        measurementCount += count
        recordStore = store
        ConsoleOut.shared.logMessage(message: "\(#function): \(count) records over \(Int(duration / 60)) min; time offset now \(timeOffset)")
        return count
    }

    /// One CGM Measurement from the glucose source at `elapsed` seconds into the session; consumes a
    /// scenario value when the source is scripted.
    private func makeRecord(elapsed: TimeInterval, timeOffset: UInt16) -> CGMMeasurementRecord {
        let index = scenarioIndex
        var glucose = trace.glucose(elapsed: elapsed, index: index).rounded()
        var trend = feature.flags.contains(.trendInformation) ? (trace.trend(elapsed: elapsed, index: index) * 10).rounded() / 10 : nil
        var quality: Double? = feature.flags.contains(.quality) ? 100 : nil

        rangeStatus = []
        if condition != .healthy {
            // TBD-05 / HYD-G-006: an impaired or failed sensor cannot quantify; the record carries the fault bit.
            glucose = .nan
            trend = nil
            quality = quality.map { _ in 0 }
        } else if feature.flags.contains(.sensorResultHighLowDetection) {
            // HYD-G-003: outside the sensor range the boundary is reported with the matching bit.
            if glucose > sensorRange.upperBound {
                glucose = sensorRange.upperBound
                rangeStatus = .resultHigherThanDeviceCanProcess
            } else if glucose < sensorRange.lowerBound {
                glucose = sensorRange.lowerBound
                rangeStatus = .resultLowerThanDeviceCanProcess
            }
        }

        // §3.7.2.3–3.7.2.6: the reading is compared against the alert levels and the record carries the result.
        alertStatus = alertLevels.annunciation(glucose: glucose, trend: trend, feature: feature.flags)
        let record = CGMMeasurementRecord(
            glucoseConcentration: glucose,
            timeOffset: timeOffset,
            sensorStatus: sensorStatus(at: timeOffset),   // a backfilled record carries its own moment's bits
            trend: trend,
            quality: quality
        )
        scenarioIndex += 1
        return record
    }

    /// One CGM Measurement notification carrying `records` back to back (CGMS §3.1: a value may hold
    /// several records). Plain path only when the collector subscribed; the secure path checks AC Data Out.
    private func notifyMeasurements(_ records: [CGMMeasurementRecord]) {
        let value = records.reduce(into: Data()) { $0.append($1.encoded(e2eCRC: isE2EProtectionSupported)) }
        if isAuthorizationControlEnabled {
            authorizationDataCharacteristic.sendSecureNotification(value, to: CGMResourceHandle.handle(for: .measurement))
        } else if gattServer.isCharacteristicSubscribed(CGMCharacteristicUUID.measurement.cbUUID) == true {
            messageQueue.addQueueItem(UUIDValuePair(uuid: CGMCharacteristicUUID.measurement.cbUUID, value: value))
        }
    }

    /// Whether record notifications can reach the collector on the active channel (CGMS §3.6.3.6).
    private var isMeasurementNotificationConfigured: Bool {
        let uuid = isAuthorizationControlEnabled ? ACCharacteristicUUID.dataOutNotify.cbUUID : CGMCharacteristicUUID.measurement.cbUUID
        return gattServer.isCharacteristicSubscribed(uuid) == true
    }

    /// The communication cadence runs from power-on regardless of session state (Nate, 2026-10-15): every
    /// tick notifies, and only a running, warmed-up, healthy sensor puts a glucose value in the record.
    /// Start Session and the end of a warm-up re-align the ticks to that moment.
    private func scheduleMeasurementTimer() {
        measurementTimer?.invalidate()
        measurementTimer = nil
        let timer = Timer(timeInterval: measurementInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common modes so the timer keeps firing while the tester scrolls the UI (default mode pauses then).
        RunLoop.main.add(timer, forMode: .common)
        measurementTimer = timer
    }

    /// One cadence tick: a reading when the sensor can produce one, otherwise a status-only notification.
    private func tick() {
        if sessionState == .running {
            // HYD-G-009: the session ends by itself once its run time has elapsed.
            if Int(timeOffset) >= Int(sessionRunTime.hours) * 60 {
                _ = stopSession(source: .sensor, kind: .sessionExpired)
            } else if !isWarmingUp, condition != .failed {
                captureReading()
                return
            }
        }
        notifyStatusRecord()
    }

    /// Most recent status-only notification (no glucose), for the UI.
    public private(set) var lastStatusRecord: CGMMeasurementRecord?

    /// A record carrying only Time Offset and the status bits: NaN glucose, no trend, zero quality. This is
    /// how a stopped, warming-up or failed sensor keeps talking to the collector, since CGM Status itself
    /// cannot be notified (CGMS Table 3.1). Notified, never stored: it is not a measurement.
    private func notifyStatusRecord() {
        let record = CGMMeasurementRecord(
            glucoseConcentration: .nan,
            timeOffset: timeOffset,
            sensorStatus: sensorStatus,
            trend: nil,
            quality: feature.flags.contains(.quality) ? 0 : nil
        )
        lastStatusRecord = record
        ConsoleOut.shared.logMessage(message: "status notification: \(record)")
        if isPeriodicCommunicationEnabled { notifyMeasurements([record]) }
        notifyDelegate()
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

    /// Record Access Control Point (CGMS §3.6): Report Number / Report / Delete Stored Records with the
    /// Time Offset filter, and Abort. Records go out as CGM Measurement notifications followed by a
    /// Response Code indication; the message queue preserves that order. RACP never carries an E2E-CRC.
    public func writeRecordAccessControlPoint(_ data: Data?) -> CBATTError.Code {
        guard let data, let requestOpcode = data.first else { return .invalidPdu }
        ConsoleOut.shared.logMessage(message: "\(#function): \(data.hexadecimalString)")

        let request: CGMRACPRequest
        do {
            request = try CGMRACPRequest(data: data)
        } catch let error as CGMRACPRequestError {
            switch error {
            case .opCodeNotSupported: respondRACP(requestOpcode, .opCodeNotSupported)
            case .invalidOperator: respondRACP(requestOpcode, .invalidOperator)
            case .operandNotSupported: respondRACP(requestOpcode, .operandNotSupported)
            case .invalidOperand: respondRACP(requestOpcode, .invalidOperand)
            }
            return .success
        } catch {
            return .invalidPdu
        }

        if request.opcode == .abortOperation {
            // Best effort (CGMS §3.6.3.5): drop whatever is still waiting to be sent.
            messageQueue.emptyQueue()
            racpReportQueued = false
            respondRACP(.abortOperation, .success)
            return .success
        }

        // CGMS §3.6.3.6: one procedure at a time, and record notifications need their CCCD configured.
        if racpReportQueued, messageQueue.hasMessagesInQueue {
            return .procedureAlreadyInProgress
        }
        racpReportQueued = false
        if request.opcode == .reportStoredRecords, !isMeasurementNotificationConfigured {
            return .improperlyConfigured
        }

        let selected = recordStore.select(request.racpOperator, minimum: request.minimum, maximum: request.maximum)
        switch request.opcode {
        case .reportNumberOfStoredRecords:
            let response = CGMRACPResponse.numberOfStoredRecords(UInt16(clamping: selected.count))
            indicate(response.encoded(), on: .recordAccessControlPoint)
        case .reportStoredRecords:
            guard !selected.isEmpty else {
                respondRACP(.reportStoredRecords, .noRecordsFound)
                break
            }
            for chunk in selected.chunked(by: recordsPerNotification) {
                notifyMeasurements(chunk)
            }
            racpReportQueued = true
            respondRACP(.reportStoredRecords, .success)
        case .deleteStoredRecords:
            let deleted = recordStore.delete(request.racpOperator, minimum: request.minimum, maximum: request.maximum)
            respondRACP(.deleteStoredRecords, deleted > 0 ? .success : .noRecordsFound)
        case .abortOperation, .numberOfStoredRecordsResponse, .responseCode:
            break
        }
        return .success
    }

    private func respondRACP(_ request: CGMRACPOpcode, _ code: CGMRACPResponseCode) {
        respondRACP(request.rawValue, code)
    }

    private func respondRACP(_ request: UInt8, _ code: CGMRACPResponseCode) {
        indicate(CGMRACPResponse.responseCode(request: request, code: code.rawValue).encoded(), on: .recordAccessControlPoint)
    }

    /// CGM Specific Ops Control Point (CGMS §3.7, Table 3.6). Op codes whose alert family or calibration the
    /// Feature does not advertise are excluded (C.1–C.9) and answer Op Code not supported; levels outside the
    /// sensor's range and calibration records it no longer holds answer Parameter out of range.
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

        if let required = opcode.requiredFeature, !feature.flags.contains(required) {
            indicateSpecificOpsResponse(request: requestOpcode, code: .opCodeNotSupported)
            return .success
        }

        // Size and CRC are verified, so the operand is exactly `encodedSize` octets after the op code.
        var reader = CGMDataReader(data.dropFirst().prefix(operand.encodedSize))
        let responseCode: CGMSpecificOpsResponseCode
        do {
            switch opcode {
            case .setCommunicationInterval:
                setCommunicationInterval(try reader.read(UInt8.self))
                responseCode = .success
            case .getCommunicationInterval:
                indicateSpecificOps(.communicationInterval(minutes: communicationInterval))
                return .success

            case .setGlucoseCalibrationValue:
                let submitted = try CGMCalibrationRecord(data: Data(try reader.readBytes(CGMCalibrationRecord.encodedSize)))
                guard CGMAlertLevels.glucoseRange.contains(submitted.glucoseConcentration) else {
                    responseCode = .parameterOutOfRange
                    break
                }
                let stored = calibrationStore.store(submitted, nextCalibrationTime: calibrationSchedule.nextCalibrationTime(after: submitted.calibrationTime))
                // The request for calibration (tester toggles) is satisfied by this calibration.
                manualSensorStatus.subtract([.calibrationRequired, .calibrationRecommended])
                ConsoleOut.shared.logMessage(message: "\(#function): stored calibration \(stored)")
                responseCode = .success
            case .getGlucoseCalibrationValue:
                let number = try reader.read(UInt16.self)
                guard let record = calibrationStore.record(number: number) else {
                    // §3.7.2.2: a record the sensor no longer holds.
                    responseCode = .parameterOutOfRange
                    break
                }
                indicateSpecificOps(.calibrationValue(record))
                return .success

            case .setPatientHighAlertLevel, .setPatientLowAlertLevel, .setHypoAlertLevel, .setHyperAlertLevel,
                 .setRateOfDecreaseAlertLevel, .setRateOfIncreaseAlertLevel:
                let value = try reader.readSFloat()
                guard CGMAlertLevels.isInRange(value, for: opcode) else {
                    responseCode = .parameterOutOfRange
                    break
                }
                alertLevels[keyPath: opcode.alertLevelKeyPath!] = value
                responseCode = .success
            case .getPatientHighAlertLevel, .getPatientLowAlertLevel, .getHypoAlertLevel, .getHyperAlertLevel,
                 .getRateOfDecreaseAlertLevel, .getRateOfIncreaseAlertLevel:
                indicateSpecificOps(.level(opcode: opcode.levelResponseOpcode!, value: alertLevels[keyPath: opcode.alertLevelKeyPath!]))
                return .success

            case .resetDeviceSpecificAlert:
                // §3.7.2.7: clears the bit in Status and in subsequent measurement records.
                manualSensorStatus.remove(.deviceSpecificAlert)
                responseCode = .success
            case .startSession:
                // Also restarts a running session: previous data is discarded (§3.7.2.8). A failed sensor
                // cannot start one until the tester replaces it (HYD-G-006).
                responseCode = startSession(source: .collector) ? .success : .procedureNotCompleted
            case .stopSession:
                // §3.7.2.9: stopping a session that is not running is Op Code not supported.
                responseCode = stopSession(source: .collector) ? .success : .opCodeNotSupported
            case .communicationIntervalResponse, .glucoseCalibrationValueResponse, .patientHighAlertLevelResponse,
                 .patientLowAlertLevelResponse, .hypoAlertLevelResponse, .hyperAlertLevelResponse,
                 .rateOfDecreaseAlertLevelResponse, .rateOfIncreaseAlertLevelResponse, .responseCode:
                responseCode = .opCodeNotSupported   // unreachable: requestOperand is nil for these
            }
        } catch {
            // Only field validation can fail here (calibration type or sample location nibble).
            ConsoleOut.shared.logMessage(message: "\(#function): rejected operand: \(error)")
            responseCode = .invalidOperand
        }
        indicateSpecificOpsResponse(request: requestOpcode, code: responseCode)
        return .success
    }

    private func indicateSpecificOpsResponse(request: UInt8, code: CGMSpecificOpsResponseCode) {
        indicateSpecificOps(.responseCode(request: request, code: code.rawValue))
    }

    private func indicateSpecificOps(_ response: CGMSpecificOpsResponse) {
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
        guard delegateBatchDepth == 0 else { return }
        delegate?.mockSensorDidUpdate(self)
    }

    private var delegateBatchDepth = 0

    /// Runs `changes`, which may touch several observed properties, and tells the delegate once at the end
    /// so it never sees a half-applied state. Nests: only the outermost batch notifies.
    private func batchingDelegateUpdates(_ changes: () -> Void) {
        delegateBatchDepth += 1
        changes()
        delegateBatchDepth -= 1
        notifyDelegate()
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
