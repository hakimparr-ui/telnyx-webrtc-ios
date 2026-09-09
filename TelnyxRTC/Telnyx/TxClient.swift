//
//  TxClient.swift
//  TelnyxRTC
//
//  Created by Guillermo Battistel on 01/03/2021.
//  Copyright © 2021 Telnyx LLC. All rights reserved.
//

import Foundation
import AVFoundation
import WebRTC
import CallKit

// MARK: - Notification Names
public extension Notification.Name {
    static let telnyxWebSocketMessageReceived = Notification.Name("TelnyxWebSocketMessageReceived")
}

/// The `TelnyxRTC` client connects your application to the Telnyx backend,
/// enabling you to make outgoing calls and handle incoming calls.
///
/// ## Examples
/// ### Connect and login:
///
/// ```
/// // Initialize the client
/// let telnyxClient = TxClient()
///
/// // Register to get SDK events
/// telnyxClient.delegate = self
///
/// // Setup yor connection parameters.
///
/// // Set the login credentials and the ringtone/ringback configurations if required.
/// // Ringtone / ringback tone files are not mandatory.
/// // You can user your sipUser and password
/// let txConfigUserAndPassowrd = TxConfig(sipUser: sipUser,
///                                        password: password,
///                                        ringtone: "incoming_call.mp3",
///                                        ringBackTone: "ringback_tone.mp3",
///                                        //You can choose the appropriate verbosity level of the SDK.
///                                        //Logs are disabled by default
///                                        logLevel: .all)
///
/// // Use a JWT Telnyx Token to authenticate (recommended)
/// let txConfigToken = TxConfig(token: "MY_JWT_TELNYX_TOKEN",
///                              ringtone: "incoming_call.mp3",
///                              ringBackTone: "ringback_tone.mp3",
///                              //You can choose the appropriate verbosity level of the SDK. Logs are disabled by default
///                              logLevel: .all)
///
/// do {
///    // Connect and login
///    // Use `txConfigUserAndPassowrd` or `txConfigToken`
///    try telnyxClient.connect(txConfig: txConfigToken)
/// } catch let error {
///    print("ViewController:: connect Error \(error)")
/// }
///
/// // You can call client.disconnect() when you're done.
/// Note: you need to relese the delegate manually when you are done.
///
/// // Disconnecting and Removing listeners.
/// telnyxClient.disconnect();
///
/// // Release the delegate
/// telnyxClient.delegate = nil
///
/// ```
///
/// ### Listen TxClient delegate events.
///
/// ```
/// extension ViewController: TxClientDelegate {
///
///     func onRemoteCallEnded(callId: UUID) {
///         // Call has been removed internally.
///     }
///
///     func onSocketConnected() {
///        // When the client has successfully connected to the Telnyx Backend.
///     }
///
///     func onSocketDisconnected() {
///        // When the client from the Telnyx backend
///     }
///
///     func onClientError(error: Error)  {
///         // Something went wrong.
///     }
///
///     func onClientReady()  {
///        // You can start receiving incoming calls or
///        // start making calls once the client was fully initialized.
///     }
///
///     func onSessionUpdated(sessionId: String)  {
///        // This function will be executed when a sessionId is received.
///     }
///
///     func onIncomingCall(call: Call)  {
///        // Someone is calling you.
///     }
///
///     // You can update your UI from here base on the call states.
///     // Check that the callId is the same as your current call.
///     func onCallStateUpdated(callState: CallState, callId: UUID) {
///         DispatchQueue.main.async {
///             switch (callState) {
///             case .CONNECTING:
///                 break
///             case .RINGING:
///                 break
///             case .NEW:
///                 break
///             case .ACTIVE:
///                 break
///             case .DONE:
///                 break
///             case .HELD:
///                 break
///             }
///         }
///     }
/// }
/// ```
public class TxClient {

    internal var peerFactory: RTCPeerConnectionFactory = Peer.factory
    private struct PendingDisablePush {
        let messageId: String
        let generation: UInt
        let socket: Socket
        var timeoutWorkItem: DispatchWorkItem?
    }

    private struct PendingActiveCallTermination {
        let callId: UUID
        let generation: UInt
        var completions: [(Bool) -> Void]
        var timeoutWorkItem: DispatchWorkItem?
        var byeMessageId: String?
        var byeSocket: Socket?
    }

    /// Tracks the internal VoIP push handoff before a real incoming `Call` may exist.
    ///
    /// This state is intentionally separate from `CallState`: it coordinates socket/login/INVITE
    /// ordering for CallKit push flows, not the lifecycle of an established call object.
    /// - `loginSent` prevents `answerFromCallkit` from sending a duplicate login after the
    ///   socket-connected push path has already logged in.
    /// - `inviteReceived` prevents the post-answer INVITE timeout from firing when INVITE has
    ///   arrived but downstream call creation is still pending or delayed.
    private enum PushCallState {
        case idle
        case loginSent
        case inviteReceived
    }

    // MARK: - Properties
    private static let DEFAULT_REGISTER_INTERVAL = 3.0 // In seconds
    private static let MAX_REGISTER_RETRY = 3 // Number of retry
    //re_connect buffer in secondds
    private static let RECONNECT_BUFFER = 1.0
    /// Keeps track of all the created calls by theirs UUIDs
    public internal(set) var calls: [UUID: Call] = [UUID: Call]()
    /// Subscribe to TxClient delegate to receive Telnyx SDK events
    public weak var delegate: TxClientDelegate?
    private var socket : Socket?
    /// True while the socket created for a VoIP push is still opening. CallKit
    /// can deliver an answer before WebSocket reports connected; in that case
    /// answer on this socket instead of replacing it with a second one.
    private var pushSocketConnectionPending = false

    private var answerCallAction: CXAnswerCallAction? = nil
    private var endCallAction: CXEndCallAction? = nil
    private var sessionId : String?
    internal var txConfig: TxConfig?
    internal var serverConfiguration: TxServerConfiguration
    private var voiceSdkId: String? = nil

    private var registerRetryCount: Int = MAX_REGISTER_RETRY
    private var registerTimer: Timer = Timer()
    private var gatewayState: GatewayStates = .NOREG
    private weak var gatewayRegisteredSocket: Socket?
    private var isCallFromPush: Bool = false
    private var currentCallId: UUID = UUID()
    private var pendingAnswerHeaders = [String:String]()
    private var pendingAnswerPreferredCodecs: [TxCodecCapability]?
    internal var sendFileLogs: Bool = false
    private var attachCallId: String?
    private var pushMetaData: [String:Any]?
    private let AUTH_ERROR_CODE = "-32001"
    private var reconnectTimeoutTimer: DispatchSourceTimer?
    private let reconnectQueue = DispatchQueue(label: "TelnyxClient.ReconnectQueue")
    private var _isSpeakerEnabled: Bool = false
    private var enableQualityMetrics: Bool = false
    private var isACMResetInProgress: Bool = false
    private var pendingAnonymousLoginMessage: AnonymousLoginMessage?
    // External notifications can synchronously reenter a client delegate. Keep
    // this ownership lock separate from WebRTC's nonrecursive configuration lock.
    private let callKitAudioLock = NSRecursiveLock()
    private var callKitAudioSession: AVAudioSession?
    
    /// AI Assistant Manager for handling AI-related functionality
    public let aiAssistantManager = AIAssistantManager()

    
    // New properties for improved push flow
    private var storedTxConfig: TxConfig?
    private var storedServerConfiguration: TxServerConfiguration?
    private var pendingCallDecline: Bool = false
    private var pendingDeclineLoginMessageId: String?
    private var pendingDeclineLoginAccepted: Bool = false
    private var pendingDeclineClientReadySeen: Bool = false
    private var pendingDeclineGatewayMessageId: String?
    private var isReconnectPendingForCallKitDecline: Bool = false
    private var pendingDeclineReconnectGeneration: UInt = 0
    private var pendingActiveCallTerminations: [UUID: PendingActiveCallTermination] = [:]
    private var activeCallTerminationGeneration: UInt = 0
    private var activeCallTerminationReconnectGeneration: UInt = 0
    private var activeCallTerminationReconnectAttempts: Int = 0
    private var isActiveCallTerminationReconnectScheduled: Bool = false
    private var activeCallTerminationAuthenticationGeneration: UInt = 0
    private var activeCallTerminationGatewayRetryCount: Int = TxClient.MAX_REGISTER_RETRY
    private var activeCallTerminationLoginMessageId: String?
    private var activeCallTerminationLoginAccepted: Bool = false
    private var activeCallTerminationClientReadySeen: Bool = false
    private var activeCallTerminationGatewayMessageId: String?
    private var activeCallTerminationAuthenticationSocket: Socket?
    private var activeCallTerminationAuthenticatedSocket: Socket?
    private let disablePushLock = NSLock()
    private var pendingDisablePush: PendingDisablePush?
    private var disablePushGeneration: UInt = 0
    internal var disablePushTimeoutInterval: TimeInterval = 10.0
    internal var activeCallTerminationRetryInterval: TimeInterval = 4.0
    internal var activeCallTerminationGatewayPollInterval: TimeInterval = TxClient.DEFAULT_REGISTER_INTERVAL
    internal var activeCallTerminationMaxReconnectAttempts: Int = 3
    internal var socketFactory: () -> Socket = { Socket() }
    
    // Timeout mechanism for VoIP push calls
    private var inviteTimeoutTimer: Timer?
    private var isWaitingForInviteAfterPush: Bool = false
    private var pushCallState: PushCallState = .idle
    /// Maps socket callID -> app-facing callID for push-originated calls
    /// where the two UUIDs differ.
    private var socketToAppCallId: [UUID: UUID] = [:]
    private static let INVITE_TIMEOUT_SECONDS: TimeInterval = 10.0
    internal var inviteTimeoutInterval: TimeInterval = TxClient.INVITE_TIMEOUT_SECONDS
    
    public private(set) var isSpeakerEnabled: Bool {
        get {
            return _isSpeakerEnabled
        }
        set {
            _isSpeakerEnabled = newValue
        }
    }

    /// Controls the audio device state when using CallKit integration.
    /// This property manages the WebRTC audio session activation and deactivation.
    ///
    /// When implementing CallKit, you must manually handle the audio session state:
    /// - Set to `true` in `provider(_:didActivate:)` to enable audio
    /// - Set to `false` in `provider(_:didDeactivate:)` to disable audio
    ///
    /// Example usage with CallKit:
    /// ```swift
    /// extension CallKitProvider: CXProviderDelegate {
    ///     func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    ///         telnyxClient.isAudioDeviceEnabled = true
    ///     }
    ///
    ///     func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    ///         telnyxClient.isAudioDeviceEnabled = false
    ///     }
    /// }
    /// ```
    public var isAudioDeviceEnabled : Bool {
        get {
            return RTCAudioSession.sharedInstance().isAudioEnabled
        }
        set {
            updateCallKitAudioSession(
                AVAudioSession.sharedInstance(),
                active: newValue
            )
        }
    }

    /// Prepares recording and playback before a CallKit answer or start action
    /// can be fulfilled. This does not activate the session or enable audio.
    /// CallKit remains responsible for activation through `provider(_:didActivate:)`.
    /// Configuration errors are returned to the caller before it accepts the call.
    public func prepareAudioSessionForCallKit() throws {
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.categoryOptions = [.duckOthers, .allowBluetooth]
        try rtcAudioSession.setConfiguration(configuration)
    }
    
    /// Reports CallKit's external activation and enables the audio device.
    /// Prepare the session with `prepareAudioSessionForCallKit()` before fulfilling
    /// the answer or start action. Configuration here also supports existing callers.
    ///
    /// - Parameter audioSession: The AVAudioSession instance to configure
    /// - Important: This method MUST be called from the CXProviderDelegate's `provider(_:didActivate:)` callback
    ///             to properly handle audio routing when using CallKit integration.
    ///
    /// Example usage:
    /// ```swift
    /// func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    ///     print("provider:didActivateAudioSession:")
    ///     self.telnyxClient.enableAudioSession(audioSession: audioSession)
    /// }
    /// ```
    public func enableAudioSession(audioSession: AVAudioSession) {
        setupCorrectAudioConfiguration()
        updateCallKitAudioSession(audioSession, active: true)
    }
    
    /// Reports CallKit's external deactivation and disables the audio device.
    /// Repeated calls do not release another owner's activation contribution.
    ///
    /// - Parameter audioSession: The AVAudioSession instance to reset
    /// - Important: This method MUST be called from the CXProviderDelegate's `provider(_:didDeactivate:)` callback
    ///             to properly clean up audio resources when using CallKit integration.
    ///
    /// Example usage:
    /// ```swift
    /// func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    ///     print("provider:didDeactivateAudioSession:")
    ///     self.telnyxClient.disableAudioSession(audioSession: audioSession)
    /// }
    /// ```
    public func disableAudioSession(audioSession: AVAudioSession) {
        updateCallKitAudioSession(audioSession, active: false)
    }

    private func updateCallKitAudioSession(_ audioSession: AVAudioSession, active: Bool) {
        callKitAudioLock.lock()
        defer { callKitAudioLock.unlock() }
        let rtcAudioSession = RTCAudioSession.sharedInstance()

        if active {
            // CallKit can reactivate after an interruption without first sending
            // didDeactivate. WebRTC must receive the new interruption end even
            // when its enabled flag is already true. Replace only our previous
            // external activation count, without stopping the device or asking
            // AVAudioSession to activate or deactivate itself.
            if let previousSession = callKitAudioSession {
                rtcAudioSession.audioSessionDidDeactivate(previousSession)
            }
            callKitAudioSession = audioSession
            rtcAudioSession.audioSessionDidActivate(audioSession)
            // A synchronous delegate can revoke ownership during notification.
            guard callKitAudioSession === audioSession else { return }
            rtcAudioSession.isAudioEnabled = true
        } else {
            guard let ownedSession = callKitAudioSession else { return }
            callKitAudioSession = nil
            rtcAudioSession.audioSessionDidDeactivate(ownedSession)
            rtcAudioSession.isAudioEnabled = false
        }
    }
    
    /// The current audio route configuration.
    /// This provides information about the active input and output ports.
    let currentRoute = AVAudioSession.sharedInstance().currentRoute
    
    /// Client must be registered in order to receive or place calls.
    public var isRegistered: Bool {
        get {
            gatewayState == .REGED &&
                socket?.isConnected == true &&
                gatewayRegisteredSocket === socket
        }
    }

    // MARK: - Initializers
    /// TxClient has to be instantiated.
    public init() {
        self.serverConfiguration = TxServerConfiguration()
        self.configure()
        sessionId = UUID().uuidString.lowercased()
        // Start monitoring audio route changes
        setupAudioRouteChangeMonitoring()

        NetworkMonitor.shared.startMonitoring()
        
        // Set up a closure to handle network state changes
        NetworkMonitor.shared.onNetworkStateChange = { [weak self] state in
            guard let self = self else { return }

            DispatchQueue.main.async {
                switch state {
                case .wifi:
                    Logger.log.i(message: "Connected to Wi-Fi")
                    self.reconnectClient()
                case .cellular, .vpn:
                    Logger.log.i(message: "Connected to Cellular")
                    self.reconnectClient()
                case .noConnection:
                    if(!self.isCallsActive){
                        self.delegate?.onSocketDisconnected()
                    }
                    Logger.log.e(message: "No network connection")
                    self.socket?.isConnected = false
                    self.updateActiveCallsState(callState: CallState.DROPPED(reason: .networkLost))
                    // Only start reconnect timeout if there are active calls
                    if self.isCallsActive {
                        self.startReconnectTimeout()
                    }
                }
            }
        }
    }
    
    /// Deinitializer to ensure proper cleanup of resources
    deinit {
        completeAllActiveCallTerminations(success: false)

        // Cancel reconnect timeout timer if it exists
        reconnectTimeoutTimer?.cancel()
        reconnectTimeoutTimer = nil
        
        // Stop network monitoring
        NetworkMonitor.shared.stopMonitoring()
        
        // Remove audio route change observer
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        
        // Remove ACM reset observers
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(InternalConfig.NotificationNames.acmResetStarted), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(InternalConfig.NotificationNames.acmResetCompleted), object: nil)
        
        Logger.log.i(message: "TxClient deinitialized")
    }
    
    /// Sets up monitoring for audio route changes (e.g., headphones connected/disconnected, 
    /// Bluetooth device connected/disconnected).
    ///
    /// This method registers for AVAudioSession route change notifications to:
    /// - Track when audio devices are connected or disconnected
    /// - Monitor changes in the active audio output
    /// - Update the speaker state accordingly
    private func setupAudioRouteChangeMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil)
        
        // Add observer for ACM reset start to ignore audio route changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleACMResetStarted),
            name: NSNotification.Name(InternalConfig.NotificationNames.acmResetStarted),
            object: nil)

        // Add observer for ACM reset completion to restore speakerphone state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleACMResetCompleted),
            name: NSNotification.Name(InternalConfig.NotificationNames.acmResetCompleted),
            object: nil)
    }
    
    /// Handles audio route change notifications from the system.
    ///
    /// This method processes audio route changes and:
    /// - Updates the internal speaker state
    /// - Notifies observers about audio route changes
    /// - Manages audio routing between available outputs
    ///
    /// The method posts an AudioRouteChanged notification with:
    /// - isSpeakerEnabled: Whether the built-in speaker is active
    /// - outputPortType: The type of the current audio output port
    ///
    /// Common route change reasons handled:
    /// - .categoryChange: Audio session category was changed
    /// - .override: Route was overridden by the system or user
    /// - .routeConfigurationChange: Available routes were changed
    ///
    /// @objc attribute is required for NotificationCenter selector
    @objc private func handleAudioRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute

        // Ensure we have at least one output port
        guard let output = currentRoute.outputs.first else {
            return
        }

        Logger.log.i(message: "[ACM_RESET] TxClient:: Audio route changed: \(output.portType), reason: \(reason), isACMResetInProgress: \(isACMResetInProgress)")

        // Ignore audio route changes during ACM reset to prevent state desynchronization
        if isACMResetInProgress {
            Logger.log.i(message: "[ACM_RESET] TxClient:: Ignoring audio route change during ACM reset")
            return
        }

        switch reason {
            case .categoryChange, .override, .routeConfigurationChange:
                // Update internal speaker state based on current output
                let isSpeaker = output.portType == .builtInSpeaker
                _isSpeakerEnabled = isSpeaker

                // Notify observers about the route change
                NotificationCenter.default.post(
                    name: NSNotification.Name(InternalConfig.NotificationNames.audioRouteChanged),
                    object: nil,
                    userInfo: [
                        "isSpeakerEnabled": isSpeaker,
                        "outputPortType": output.portType
                    ]
                )
            default:
                break
        }
    }
    
    /// Handles ACM reset started notification to prevent audio route change interference.
    ///
    /// This method sets a flag to ignore audio route changes during the ACM reset process
    /// to prevent the internal speaker state from being incorrectly updated.
    ///
    /// - Parameter notification: The notification indicating ACM reset has started
    @objc private func handleACMResetStarted(_ notification: Notification) {
        Logger.log.i(message: "[ACM_RESET] TxClient:: ACM reset started - will ignore audio route changes")
        isACMResetInProgress = true
    }

    /// Handles ACM reset completion notifications and restores speakerphone state if needed.
    ///
    /// This method is called when the AudioDeviceModule reset is completed and the speakerphone
    /// state needs to be restored to prevent the ACM reset from disabling speakerphone mode.
    ///
    /// - Parameter notification: The notification containing restoration information
    @objc private func handleACMResetCompleted(_ notification: Notification) {
        Logger.log.i(message: "[ACM_RESET] TxClient:: Received ACM reset completion notification")

        guard let userInfo = notification.userInfo,
              let restoreSpeakerphone = userInfo["restoreSpeakerphone"] as? Bool else {
            Logger.log.w(message: "[ACM_RESET] TxClient:: Notification missing userInfo or restoreSpeakerphone flag")
            // Re-enable audio route monitoring even if notification is malformed
            isACMResetInProgress = false
            return
        }

        Logger.log.i(message: "[ACM_RESET] TxClient:: Should restore speaker: \(restoreSpeakerphone)")

        // Re-enable audio route change monitoring first
        isACMResetInProgress = false
        Logger.log.i(message: "[ACM_RESET] TxClient:: Audio route change monitoring re-enabled")

        // Restore speaker if it was active before the reset
        if restoreSpeakerphone {
            Logger.log.i(message: "[ACM_RESET] TxClient:: Starting speaker restoration with verification")
            restoreSpeakerWithVerification(maxAttempts: 5)
        } else {
            Logger.log.i(message: "[ACM_RESET] TxClient:: Speaker was not active before reset, no restoration needed")
        }
    }

    /// Restores speaker with verification and retry logic
    /// This ensures the speaker is actually active after ACM reset, even if iOS tries to revert it
    /// - Parameter maxAttempts: Maximum number of attempts to restore speaker (default: 5)
    /// - Parameter attempt: Current attempt number (used internally for recursion)
    private func restoreSpeakerWithVerification(maxAttempts: Int = 5, attempt: Int = 1) {
        // Manual audio routes belong to the application. Check again for each
        // retry because ownership may change while its callback is queued.
        guard !RTCAudioSession.sharedInstance().useManualAudio else { return }

        Logger.log.i(message: "[ACM_RESET] TxClient:: Speaker restoration attempt \(attempt)/\(maxAttempts)")

        // Call setSpeaker to activate speaker
        setSpeaker()

        // Wait a bit for iOS to process the change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self,
                  !RTCAudioSession.sharedInstance().useManualAudio else { return }

            // Verify if speaker is actually active
            let currentRoute = AVAudioSession.sharedInstance().currentRoute
            let isSpeakerActive = currentRoute.outputs.contains { $0.portType == .builtInSpeaker }

            if isSpeakerActive {
                Logger.log.i(message: "[ACM_RESET] TxClient:: Speaker successfully restored and verified on attempt \(attempt)")
            } else if attempt < maxAttempts {
                Logger.log.w(message: "[ACM_RESET] TxClient:: Speaker not active after attempt \(attempt), retrying...")
                // Retry with next attempt
                self.restoreSpeakerWithVerification(maxAttempts: maxAttempts, attempt: attempt + 1)
            } else {
                Logger.log.e(message: "[ACM_RESET] TxClient:: Failed to restore speaker after \(maxAttempts) attempts")
            }
        }
    }

    /// Public method to restore speaker after reconnection with verification and retry
    /// This is called from Call.swift after attach/reconnect to ensure speaker state is preserved
    internal func restoreSpeakerAfterReconnect() {
        Logger.log.i(message: "[ACM_RESET] TxClient:: restoreSpeakerAfterReconnect() - Starting speaker restoration")
        restoreSpeakerWithVerification(maxAttempts: 5)
    }

    // MARK: - Connection handling
    /// Connects to the iOS cloglient to the Telnyx signaling server using the desired login credentials.
    /// - Parameters:
    ///   - txConfig: The desired login credentials. See TxConfig docummentation for more information.
    ///   - serverConfiguration: (Optional) To define a custom `signaling server` and `TURN/ STUN servers`. As default we use the internal Telnyx Production servers.
    /// - Throws: TxConfig parameters errors
    public func connect(txConfig: TxConfig,
                        serverConfiguration: TxServerConfiguration = TxServerConfiguration()) throws {
        Logger.log.i(message: "TxClient:: connect()")
        //Check connetion parameters
        try txConfig.validateParams()
        self.registerRetryCount = TxClient.MAX_REGISTER_RETRY
        self.gatewayState = .NOREG
        self.gatewayRegisteredSocket = nil
        self.txConfig = txConfig

        if(self.voiceSdkId != nil){
            Logger.log.i(message: "with_id")
            self.serverConfiguration = TxServerConfiguration(signalingServer: serverConfiguration.signalingServer,
                                                             webRTCIceServers: serverConfiguration.webRTCIceServers,
                                                             environment: serverConfiguration.environment,
                                                             pushMetaData: [
                                                                "voice_sdk_id":self.voiceSdkId!
                                                             ])
        } else {
            self.serverConfiguration = serverConfiguration
        }
        failPendingDisablePushForSocketReplacement()
        self.socket = socketFactory()
        self.socket?.delegate = self
        self.aiAssistantManager.setSocket(self.socket)
        self.socket?.connect(signalingServer: self.serverConfiguration.signalingServer)
    }
    
    
    private func connectFromPush(txConfig: TxConfig,
                                 serverConfiguration: TxServerConfiguration = TxServerConfiguration()) throws {
        Logger.log.i(message: "TxClient:: connect from_push")
        //Check connetion parameters
        try txConfig.validateParams()
        self.registerRetryCount = TxClient.MAX_REGISTER_RETRY
        self.gatewayState = .NOREG
        self.gatewayRegisteredSocket = nil
        self.txConfig = txConfig


        self.serverConfiguration = TxServerConfiguration(signalingServer: serverConfiguration.signalingServer,
                                                         webRTCIceServers: serverConfiguration.webRTCIceServers,
                                                         environment: serverConfiguration.environment,
                                                         pushMetaData: self.pushMetaData)

        Logger.log.i(message: "TxClient:: serverConfiguration server: [\(self.serverConfiguration.signalingServer)] ICE Servers [\(self.serverConfiguration.webRTCIceServers)]")
        failPendingDisablePushForSocketReplacement()
        self.socket = socketFactory()
        self.socket?.delegate = self
        self.aiAssistantManager.setSocket(self.socket)
        self.socket?.connect(signalingServer: self.serverConfiguration.signalingServer)
    }
    
    /// Connects only the socket without performing login - used for improved push flow
    private func connectSocketOnly(serverConfiguration: TxServerConfiguration) throws {
        Logger.log.i(message: "TxClient:: connectSocketOnly - connecting socket without login")
        self.registerRetryCount = TxClient.MAX_REGISTER_RETRY
        self.gatewayState = .NOREG
        self.gatewayRegisteredSocket = nil
        if self.txConfig == nil {
            self.txConfig = storedTxConfig
        }
        self.serverConfiguration = serverConfiguration

        Logger.log.i(message: "TxClient:: serverConfiguration server: [\(self.serverConfiguration.signalingServer)] ICE Servers [\(self.serverConfiguration.webRTCIceServers)]")
        failPendingDisablePushForSocketReplacement()
        self.socket = socketFactory()
        self.socket?.delegate = self
        self.pushSocketConnectionPending = true
        self.socket?.connect(signalingServer: self.serverConfiguration.signalingServer)
    }
    
    /// Performs login with stored configuration and optional decline_push parameter
    private func performLogin(declinePush: Bool = false) {
        guard let storedConfig = storedTxConfig else {
            Logger.log.e(message: "TxClient:: performLogin - No stored config available")
            if declinePush {
                cleanupPendingCallKitDecline(reason: "missing stored config during decline_push login")
            }
            return
        }
        
        // Set the stored config as current config
        self.txConfig = storedConfig
        
        // Get push token and push provider if available
        let pushToken = storedConfig.pushNotificationConfig?.pushDeviceToken
        let pushProvider = storedConfig.pushNotificationConfig?.pushNotificationProvider

        //Login into the signaling server
        if let token = storedConfig.token {
            Logger.log.i(message: "TxClient:: performLogin with Token, declinePush: \(declinePush)")
            let vertoLogin = LoginMessage(token: token,
                                        pushDeviceToken: pushToken,
                                        pushNotificationProvider: pushProvider,
                                        startFromPush: self.isCallFromPush,
                                        pushEnvironment: storedConfig.pushEnvironment,
                                        sessionId: self.sessionId!,
                                        declinePush: declinePush,
                                        enableMissedCallNotifications: storedConfig.enableMissedCallNotifications,
                                        pushWhenActive: storedConfig.pushWhenActive)
            sendLoginMessage(vertoLogin, declinePush: declinePush)
        } else {
            Logger.log.i(message: "TxClient:: performLogin with SIP User and Password, declinePush: \(declinePush)")
            guard let sipUser = storedConfig.sipUser else {
                if declinePush {
                    cleanupPendingCallKitDecline(reason: "missing SIP user during decline_push login")
                }
                return
            }
            guard let password = storedConfig.password else {
                if declinePush {
                    cleanupPendingCallKitDecline(reason: "missing SIP password during decline_push login")
                }
                return
            }
            let vertoLogin = LoginMessage(user: sipUser,
                                        password: password,
                                        pushDeviceToken: pushToken,
                                        pushNotificationProvider: pushProvider,
                                        startFromPush: self.isCallFromPush,
                                        pushEnvironment: storedConfig.pushEnvironment,
                                        sessionId: self.sessionId!,
                                        declinePush: declinePush,
                                        enableMissedCallNotifications: storedConfig.enableMissedCallNotifications,
                                        pushWhenActive: storedConfig.pushWhenActive)
            sendLoginMessage(vertoLogin, declinePush: declinePush)
        }
        
    }

    private func sendLoginMessage(
        _ loginMessage: LoginMessage,
        declinePush: Bool
    ) {
        if declinePush {
            pendingDeclineLoginMessageId = loginMessage.id
            pendingDeclineLoginAccepted = false
            pendingDeclineClientReadySeen = false
            pendingDeclineGatewayMessageId = nil
        }
        self.socket?.sendMessage(message: loginMessage.encode())
    }

    /// Disconnects the TxClient from the Telnyx signaling server.
    public func disconnect() {
        Logger.log.i(message: "TxClient:: disconnect()")
        _ = finishPendingDisablePush(
            socket: socket,
            success: false,
            message: "socket disconnected before push notifications were disabled"
        )
        completeAllActiveCallTerminations(success: false)
        cleanupPendingCallKitDecline(
            reason: "client disconnected before decline_push was accepted"
        )
        self.registerRetryCount = TxClient.MAX_REGISTER_RETRY
        self.gatewayState = .NOREG
        self.gatewayRegisteredSocket = nil

        // Let's cancell all the current calls
        for (_ ,call) in self.calls {
            call.hangup()
        }
        self.calls.removeAll()
        self.socketToAppCallId.removeAll()
        self.stopReconnectTimeout()
        self.stopInviteTimeout()

        // Clear AI Assistant Manager data
        self.aiAssistantManager.clearAllData()

        // Remove audio route change observer
        NotificationCenter.default.removeObserver(self,
                                                  name: AVAudioSession.routeChangeNotification,
                                                  object: nil)
        socket?.disconnect(reconnect: false)
        delegate?.onSocketDisconnected()
    }

    private var isCallsActive: Bool {
        !self.calls.filter { 
            if case .DONE = $0.value.callState {
                return false
            }
            return $0.value.callState != .NEW
        }.isEmpty
    }

    /// To check if TxClient is connected to Telnyx server.
    /// - Returns: `true` if TxClient socket is connected, `false` otherwise.
    public func isConnected() -> Bool {
        guard let isConnected = socket?.isConnected else { return false }
        return isConnected
    }

    /// Ends an active call after the exact `BYE` transaction is acknowledged on the
    /// currently authenticated signalling socket.
    /// If signalling is unavailable, the client performs up to three bounded recovery attempts.
    /// An exact remote `BYE` received while the request is pending also completes the request successfully.
    /// - Parameters:
    ///   - callId: The app-facing UUID of the call to end.
    ///   - timeout: The maximum time to retain and recover the termination request.
    ///   - completion: Called exactly once with `true` after the exact `BYE` response or exact remote termination is observed.
    public func endCallWhenSignalingReady(
        callId: UUID,
        timeout: TimeInterval = 12.0,
        completion: @escaping (Bool) -> Void
    ) {
        let start = { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            self.startActiveCallTermination(
                callId: callId,
                timeout: timeout,
                completion: completion
            )
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }

    internal func acceptRemoteTerminationEvidence(callId: UUID?) {
        guard let callId else { return }
        performOnActiveCallTerminationQueue { [weak self] in
            self?.completeActiveCallTermination(callId: callId, success: true)
        }
    }

    private func startActiveCallTermination(
        callId: UUID,
        timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        guard let call = call(forSocketCallId: callId),
              let exactCallId = call.callInfo?.callId else {
            completion(false)
            return
        }
        if case .DONE = call.callState {
            completion(false)
            return
        }

        if var pending = pendingActiveCallTerminations[exactCallId] {
            pending.completions.append(completion)
            pendingActiveCallTerminations[exactCallId] = pending
            return
        }

        activeCallTerminationGeneration &+= 1
        let generation = activeCallTerminationGeneration
        var pending = PendingActiveCallTermination(
            callId: exactCallId,
            generation: generation,
            completions: [completion],
            timeoutWorkItem: nil,
            byeMessageId: nil,
            byeSocket: nil
        )
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.timeoutActiveCallTermination(
                callId: exactCallId,
                generation: generation
            )
        }
        pending.timeoutWorkItem = timeoutWorkItem
        pendingActiveCallTerminations[exactCallId] = pending
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.0, timeout),
            execute: timeoutWorkItem
        )

        // A live Call bound to the current registered socket is already exact
        // authentication evidence. Queue BYE on that owning socket immediately
        // instead of replacing its REGED state with a gateway re-verification.
        // The response is still correlated by both message id and socket before
        // local teardown, while disconnected or replaced sockets continue down
        // the bounded recovery path below.
        if queueActiveCallTerminationOnOwningSocketIfReady(
            callId: exactCallId
        ) {
            return
        }
        if !isActiveCallTerminationSignalingReady {
            if isRegistered,
               let currentSocket = socket,
               gatewayRegisteredSocket === currentSocket {
                beginActiveCallTerminationGatewayVerification(on: currentSocket)
            } else if let currentSocket = socket,
                      currentSocket.isConnected,
                      let currentConfig = txConfig ?? storedTxConfig {
                _ = beginActiveCallTerminationAuthentication(
                    on: currentSocket,
                    txConfig: currentConfig
                )
            }
        }
        drainActiveCallTerminationsIfReady()
    }

    private func queueActiveCallTerminationOnOwningSocketIfReady(
        callId: UUID
    ) -> Bool {
        guard gatewayState == .REGED,
              let currentSocket = socket,
              currentSocket.isConnected,
              gatewayRegisteredSocket === currentSocket,
              let currentSessionId = sessionId,
              let call = call(forSocketCallId: callId),
              call.socket === currentSocket,
              var pending = pendingActiveCallTerminations[callId],
              pending.byeMessageId == nil,
              let byeMessageId = call.queueHangup(
                using: currentSocket,
                sessionId: currentSessionId
              ) else {
            return false
        }
        pending.byeMessageId = byeMessageId
        pending.byeSocket = currentSocket
        pendingActiveCallTerminations[callId] = pending
        return true
    }

    private func timeoutActiveCallTermination(callId: UUID, generation: UInt) {
        guard pendingActiveCallTerminations[callId]?.generation == generation else {
            return
        }
        completeActiveCallTermination(callId: callId, success: false)
    }

    private func drainActiveCallTerminationsIfReady() {
        guard !pendingActiveCallTerminations.isEmpty else { return }
        guard gatewayState == .REGED,
              let currentSocket = socket,
              let currentSessionId = sessionId,
              currentSocket.isConnected,
              gatewayRegisteredSocket === currentSocket,
              activeCallTerminationAuthenticatedSocket === currentSocket else {
            scheduleActiveCallTerminationRecovery()
            return
        }

        invalidateActiveCallTerminationRecovery(resetAttempts: false)
        for callId in Array(pendingActiveCallTerminations.keys) {
            guard var pending = pendingActiveCallTerminations[callId] else {
                continue
            }
            guard pending.byeMessageId == nil else {
                continue
            }
            guard let call = call(forSocketCallId: callId) else {
                completeActiveCallTermination(callId: callId, success: false)
                continue
            }
            guard let byeMessageId = call.queueHangup(
                using: currentSocket,
                sessionId: currentSessionId
            ) else {
                clearActiveCallTerminationByeTransactions(sentOn: currentSocket)
                gatewayState = .NOREG
                gatewayRegisteredSocket = nil
                resetActiveCallTerminationAuthentication()
                scheduleActiveCallTerminationRecovery(delay: 0.0)
                return
            }
            pending.byeMessageId = byeMessageId
            pending.byeSocket = currentSocket
            pendingActiveCallTerminations[callId] = pending
        }
    }

    private func scheduleActiveCallTerminationRecovery(delay: TimeInterval? = nil) {
        performOnActiveCallTerminationQueue { [weak self] in
            guard let self,
                  !self.pendingActiveCallTerminations.isEmpty,
                  !self.isActiveCallTerminationReconnectScheduled,
                  self.activeCallTerminationReconnectAttempts < self.activeCallTerminationMaxReconnectAttempts else {
                return
            }
            if self.isActiveCallTerminationSignalingReady {
                self.drainActiveCallTerminationsIfReady()
                return
            }

            self.isActiveCallTerminationReconnectScheduled = true
            self.activeCallTerminationReconnectGeneration &+= 1
            let generation = self.activeCallTerminationReconnectGeneration
            let recoveryDelay = delay ?? (self.socket?.isConnected == true
                ? self.activeCallTerminationRetryInterval
                : 0.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + recoveryDelay) { [weak self] in
                guard let self,
                      self.isActiveCallTerminationReconnectScheduled,
                      self.activeCallTerminationReconnectGeneration == generation,
                      !self.pendingActiveCallTerminations.isEmpty else {
                    return
                }
                self.isActiveCallTerminationReconnectScheduled = false
                self.attemptActiveCallTerminationRecovery()
            }
        }
    }

    private func attemptActiveCallTerminationRecovery() {
        guard !pendingActiveCallTerminations.isEmpty else { return }
        if isActiveCallTerminationSignalingReady {
            drainActiveCallTerminationsIfReady()
            return
        }
        guard activeCallTerminationReconnectAttempts < activeCallTerminationMaxReconnectAttempts else {
            return
        }
        guard let reconnectConfig = txConfig ?? storedTxConfig else {
            completeAllActiveCallTerminations(success: false)
            return
        }

        activeCallTerminationReconnectAttempts += 1
        if let currentSocket = socket,
           currentSocket.isConnected {
            _ = beginActiveCallTerminationAuthentication(
                on: currentSocket,
                txConfig: reconnectConfig
            )
        } else {
            resetActiveCallTerminationAuthentication()
            do {
                try connect(
                    txConfig: reconnectConfig,
                    serverConfiguration: storedServerConfiguration ?? serverConfiguration
                )
            } catch {
                Logger.log.e(message: "TxClient:: active call termination reconnect failed: \(error.localizedDescription)")
            }
        }
        scheduleActiveCallTerminationRecovery(delay: activeCallTerminationRetryInterval)
    }

    private var isActiveCallTerminationSignalingReady: Bool {
        gatewayState == .REGED &&
            socket?.isConnected == true &&
            gatewayRegisteredSocket === socket &&
            activeCallTerminationAuthenticatedSocket === socket
    }

    private func beginActiveCallTerminationAuthentication(
        on socket: Socket,
        txConfig: TxConfig
    ) -> Bool {
        guard let sessionId else { return false }
        let pushToken = txConfig.pushNotificationConfig?.pushDeviceToken
        let pushProvider = txConfig.pushNotificationConfig?.pushNotificationProvider
        let loginMessage: LoginMessage
        if let token = txConfig.token {
            loginMessage = LoginMessage(
                token: token,
                pushDeviceToken: pushToken,
                pushNotificationProvider: pushProvider,
                startFromPush: false,
                pushEnvironment: txConfig.pushEnvironment,
                sessionId: sessionId,
                declinePush: false,
                enableMissedCallNotifications: txConfig.enableMissedCallNotifications,
                pushWhenActive: txConfig.pushWhenActive
            )
        } else {
            guard let sipUser = txConfig.sipUser,
                  let password = txConfig.password else {
                return false
            }
            loginMessage = LoginMessage(
                user: sipUser,
                password: password,
                pushDeviceToken: pushToken,
                pushNotificationProvider: pushProvider,
                startFromPush: false,
                pushEnvironment: txConfig.pushEnvironment,
                sessionId: sessionId,
                declinePush: false,
                enableMissedCallNotifications: txConfig.enableMissedCallNotifications,
                pushWhenActive: txConfig.pushWhenActive
            )
        }

        activeCallTerminationAuthenticationGeneration &+= 1
        registerTimer.invalidate()
        activeCallTerminationGatewayRetryCount = TxClient.MAX_REGISTER_RETRY
        activeCallTerminationLoginMessageId = loginMessage.id
        activeCallTerminationLoginAccepted = false
        activeCallTerminationClientReadySeen = false
        activeCallTerminationGatewayMessageId = nil
        activeCallTerminationAuthenticationSocket = socket
        activeCallTerminationAuthenticatedSocket = nil
        gatewayState = .NOREG
        gatewayRegisteredSocket = nil
        guard socket.sendMessage(message: loginMessage.encode()) else {
            resetActiveCallTerminationAuthentication()
            return false
        }
        return true
    }

    private func beginActiveCallTerminationGatewayVerification(on socket: Socket) {
        activeCallTerminationAuthenticationGeneration &+= 1
        registerTimer.invalidate()
        activeCallTerminationGatewayRetryCount = TxClient.MAX_REGISTER_RETRY
        activeCallTerminationLoginMessageId = nil
        activeCallTerminationLoginAccepted = true
        activeCallTerminationClientReadySeen = true
        activeCallTerminationGatewayMessageId = nil
        activeCallTerminationAuthenticationSocket = socket
        activeCallTerminationAuthenticatedSocket = nil
        gatewayState = .NOREG
        gatewayRegisteredSocket = nil
        _ = requestActiveCallTerminationGatewayState(on: socket)
    }

    private func advanceActiveCallTerminationAuthenticationIfReady() {
        guard !pendingActiveCallTerminations.isEmpty,
              activeCallTerminationLoginAccepted,
              activeCallTerminationClientReadySeen,
              activeCallTerminationGatewayMessageId == nil,
              let authenticationSocket = activeCallTerminationAuthenticationSocket,
              authenticationSocket === socket else {
            return
        }
        _ = requestActiveCallTerminationGatewayState(on: authenticationSocket)
    }

    @discardableResult
    private func requestActiveCallTerminationGatewayState(on authenticationSocket: Socket) -> String? {
        guard !pendingActiveCallTerminations.isEmpty,
              activeCallTerminationLoginAccepted,
              activeCallTerminationAuthenticationSocket === authenticationSocket,
              authenticationSocket === socket else {
            return nil
        }
        let gatewayMessage = GatewayMessage()
        activeCallTerminationGatewayMessageId = gatewayMessage.id
        guard authenticationSocket.sendMessage(message: gatewayMessage.encode()) else {
            activeCallTerminationGatewayMessageId = nil
            return nil
        }
        return gatewayMessage.id
    }

    private func scheduleActiveCallTerminationGatewayPoll() {
        registerTimer.invalidate()
        let authenticationGeneration = activeCallTerminationAuthenticationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.pendingActiveCallTerminations.isEmpty,
                  self.activeCallTerminationAuthenticationGeneration == authenticationGeneration else {
                return
            }
            self.registerTimer = Timer.scheduledTimer(
                withTimeInterval: self.activeCallTerminationGatewayPollInterval,
                repeats: false
            ) { [weak self] _ in
                guard let self,
                      !self.pendingActiveCallTerminations.isEmpty,
                      self.activeCallTerminationAuthenticationGeneration == authenticationGeneration,
                      let authenticationSocket = self.activeCallTerminationAuthenticationSocket,
                      authenticationSocket === self.socket else {
                    return
                }
                self.activeCallTerminationGatewayRetryCount -= 1
                if self.activeCallTerminationGatewayRetryCount > 0 {
                    _ = self.requestActiveCallTerminationGatewayState(on: authenticationSocket)
                } else {
                    self.resetActiveCallTerminationAuthentication()
                    self.gatewayState = .NOREG
                    self.gatewayRegisteredSocket = nil
                    self.scheduleActiveCallTerminationRecovery(delay: 0.0)
                }
            }
        }
    }

    private func resetActiveCallTerminationAuthentication() {
        activeCallTerminationAuthenticationGeneration &+= 1
        registerTimer.invalidate()
        activeCallTerminationLoginMessageId = nil
        activeCallTerminationLoginAccepted = false
        activeCallTerminationClientReadySeen = false
        activeCallTerminationGatewayMessageId = nil
        activeCallTerminationAuthenticationSocket = nil
        activeCallTerminationAuthenticatedSocket = nil
    }

    private func activeCallTerminationCallId(
        forByeResponseId responseId: String,
        socket responseSocket: Socket
    ) -> UUID? {
        pendingActiveCallTerminations.first { entry in
            entry.value.byeMessageId == responseId &&
                entry.value.byeSocket === responseSocket
        }?.key
    }

    private func pendingActiveCallTerminationCallId(
        matching callId: UUID
    ) -> UUID? {
        if pendingActiveCallTerminations[callId] != nil {
            return callId
        }
        guard let appCallId = call(forSocketCallId: callId)?.callInfo?.callId,
              pendingActiveCallTerminations[appCallId] != nil else {
            return nil
        }
        return appCallId
    }

    @discardableResult
    private func confirmActiveCallTerminationBye(
        responseId: String,
        socket responseSocket: Socket
    ) -> Bool {
        guard let callId = activeCallTerminationCallId(
            forByeResponseId: responseId,
            socket: responseSocket
        ) else {
            return false
        }
        guard let call = call(forSocketCallId: callId) else {
            completeActiveCallTermination(callId: callId, success: false)
            return true
        }
        call.confirmQueuedHangup()
        completeActiveCallTermination(callId: callId, success: true)
        return true
    }

    @discardableResult
    private func failActiveCallTerminationBye(
        responseId: String,
        socket responseSocket: Socket
    ) -> Bool {
        guard let callId = activeCallTerminationCallId(
            forByeResponseId: responseId,
            socket: responseSocket
        ) else {
            return false
        }
        completeActiveCallTermination(callId: callId, success: false)
        return true
    }

    private func clearActiveCallTerminationByeTransactions(sentOn sourceSocket: Socket) {
        for callId in Array(pendingActiveCallTerminations.keys) {
            guard var pending = pendingActiveCallTerminations[callId],
                  pending.byeSocket === sourceSocket else {
                continue
            }
            pending.byeMessageId = nil
            pending.byeSocket = nil
            pendingActiveCallTerminations[callId] = pending
        }
    }

    private func clearObsoleteActiveCallTerminationByeTransactions(
        currentSocket: Socket
    ) {
        for callId in Array(pendingActiveCallTerminations.keys) {
            guard var pending = pendingActiveCallTerminations[callId],
                  pending.byeSocket != nil,
                  pending.byeSocket !== currentSocket else {
                continue
            }
            pending.byeMessageId = nil
            pending.byeSocket = nil
            pendingActiveCallTerminations[callId] = pending
        }
    }

    private func completeActiveCallTermination(callId: UUID, success: Bool) {
        let exactCallId: UUID
        if pendingActiveCallTerminations[callId] != nil {
            exactCallId = callId
        } else if let appCallId = call(forSocketCallId: callId)?.callInfo?.callId,
                  pendingActiveCallTerminations[appCallId] != nil {
            exactCallId = appCallId
        } else {
            return
        }
        guard let pending = pendingActiveCallTerminations.removeValue(forKey: exactCallId) else {
            return
        }
        pending.timeoutWorkItem?.cancel()
        if pendingActiveCallTerminations.isEmpty {
            invalidateActiveCallTerminationRecovery(resetAttempts: true)
            resetActiveCallTerminationAuthentication()
        }
        pending.completions.forEach { $0(success) }
    }

    private func completeAllActiveCallTerminations(success: Bool) {
        let pending = Array(pendingActiveCallTerminations.values)
        pendingActiveCallTerminations.removeAll()
        invalidateActiveCallTerminationRecovery(resetAttempts: true)
        resetActiveCallTerminationAuthentication()
        pending.forEach { request in
            request.timeoutWorkItem?.cancel()
            request.completions.forEach { $0(success) }
        }
    }

    private func invalidateActiveCallTerminationRecovery(resetAttempts: Bool) {
        activeCallTerminationReconnectGeneration &+= 1
        isActiveCallTerminationReconnectScheduled = false
        if resetAttempts {
            activeCallTerminationReconnectAttempts = 0
        }
    }

    private func performOnActiveCallTerminationQueue(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
    
    /// Answers an incoming call from CallKit and manages the active call flow.
    ///
    /// This method should be called from the CXProviderDelegate's `provider(_:perform:)` method
    /// when handling a `CXAnswerCallAction`. It properly integrates with CallKit to answer incoming calls.
    ///
    /// ### Examples:
    /// ```swift
    /// extension CallKitProvider: CXProviderDelegate {
    ///     func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    ///         // Basic answer
    ///         telnyxClient.answerFromCallkit(answerAction: action)
    ///
    ///         // Answer with custom headers and debug mode
    ///         telnyxClient.answerFromCallkit(
    ///             answerAction: action,
    ///             customHeaders: ["X-Custom-Header": "Value"],
    ///             debug: true
    ///         )
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - answerAction: The `CXAnswerCallAction` provided by CallKit's provider delegate.
    ///   - customHeaders: (optional) Custom Headers to be passed over webRTC Messages.
    ///     Headers should be in the format `X-key:Value` where `X-` prefix is required for custom headers.
    ///     When calling AI Agents, headers with the `X-` prefix will be mapped to dynamic variables
    ///     (e.g., `X-Account-Number` becomes `{{account_number}}`). Hyphens in header names are
    ///     converted to underscores in variable names.
    ///   - debug: (optional) Enable debug mode for call quality metrics and WebRTC statistics.
    ///     When enabled, real-time call quality metrics will be available through the call's `onCallQualityChange` callback.
    public func answerFromCallkit(answerAction: CXAnswerCallAction,
                                  customHeaders: [String:String] = [:],
                                  debug: Bool = false,
                                  preferredCodecs: [TxCodecCapability]? = nil) {
        Logger.log.i(message: "TxClient:: answerFromCallkit - started for callId: \(String(describing: answerAction.callUUID))")
        self.answerCallAction = answerAction

        // Check if the call was initiated by a push notification
        if isCallFromPush {
            Logger.log.i(message: "TxClient:: answerFromCallkit - Call initiated by push notification")
            /// Let's Keep track of the `customHeaders` passed
            pendingAnswerHeaders = customHeaders
            pendingAnswerPreferredCodecs = preferredCodecs
            /// Set call quality metrics
            self.enableQualityMetrics = debug

            // Start the login process by sending a login message with decline_push: false
            // Automatically accept the call once the INVITE is received
            if isConnected() {
                if pushCallState == .loginSent {
                    Logger.log.i(message: "TxClient:: answerFromCallkit - Push login already sent, waiting for INVITE")
                } else {
                    Logger.log.i(message: "TxClient:: answerFromCallkit - Socket connected, performing login with decline_push: false")
                    performLogin(declinePush: false)
                    pushCallState = .loginSent
                }
            } else {
                Logger.log.i(message: "TxClient:: answerFromCallkit - Socket not connected, connecting first")
                if pushSocketConnectionPending, socket != nil {
                    Logger.log.i(message: "TxClient:: answerFromCallkit - Push socket is already connecting, waiting for it")
                    return
                }
                do {
                    try connectSocketOnly(serverConfiguration: storedServerConfiguration!)
                    // Login will happen in onSocketConnected
                } catch let error {
                    Logger.log.e(message: "TxClient:: answerFromCallkit connect error \(error.localizedDescription)")
                    answerCallAction?.fail()
                }
            }
            return
        }

        // If already connected and there's a pending INVITE, immediately accept the call
        if let currentCall = self.calls[currentCallId] {
            currentCall.answer(customHeaders: customHeaders,
                               debug: debug,
                               preferredCodecs: preferredCodecs)
            answerCallAction?.fulfill()
            resetPushVariables()
            Logger.log.i(message: "answered from callkit")
        } else {
            /// Let's Keep track of the `customHeaders` passed
            pendingAnswerHeaders = customHeaders
            pendingAnswerPreferredCodecs = preferredCodecs
            /// Set call quality metrics
            self.enableQualityMetrics = debug
        }
    }
    
    private func resetPushVariables() {
        pendingAnswerHeaders = [:]
        pendingAnswerPreferredCodecs = nil
        answerCallAction = nil
        endCallAction = nil
        storedTxConfig = nil
        storedServerConfiguration = nil
        pendingCallDecline = false
        pendingDeclineLoginMessageId = nil
        pendingDeclineLoginAccepted = false
        pendingDeclineClientReadySeen = false
        pendingDeclineGatewayMessageId = nil
        isReconnectPendingForCallKitDecline = false
        pendingDeclineReconnectGeneration &+= 1
        isCallFromPush = false
        pushCallState = .idle
        stopInviteTimeout()
        isWaitingForInviteAfterPush = false
    }

    private func cleanupPendingCallKitDecline(reason: String) {
        guard pendingCallDecline else { return }
        Logger.log.i(message: "TxClient:: cleanupPendingCallKitDecline - \(reason)")
        let callId = currentCallId
        resetPushVariables()
        delegate?.onPushDeclineCompleted(
            callId: callId,
            success: false,
            error: reason
        )
    }

    private func confirmPendingCallKitDecline() {
        guard pendingCallDecline else { return }
        let callId = currentCallId
        resetPushVariables()
        delegate?.onPushDeclineCompleted(
            callId: callId,
            success: true,
            error: nil
        )
    }

    private func failEndCallAction(_ endAction: CXEndCallAction) {
        if pendingCallDecline {
            cleanupPendingCallKitDecline(
                reason: "decline_push could not start"
            )
        } else {
            resetPushVariables()
        }
        endAction.fail()
    }
    
    /// Starts the INVITE timeout timer for VoIP push calls
    private func startInviteTimeout() {
        if pushCallState == .inviteReceived {
            Logger.log.i(message: "TxClient:: Skipping INVITE timeout - INVITE already received for VoIP push call")
            return
        }

        stopInviteTimeout() // Ensure any existing timer is stopped
        
        Logger.log.i(message: "TxClient:: Starting INVITE timeout timer (\(inviteTimeoutInterval) seconds)")
        isWaitingForInviteAfterPush = true
        
        inviteTimeoutTimer = Timer.scheduledTimer(withTimeInterval: inviteTimeoutInterval, repeats: false) { [weak self] _ in
            self?.handleInviteTimeout()
        }
    }
    
    /// Stops the INVITE timeout timer
    private func stopInviteTimeout() {
        inviteTimeoutTimer?.invalidate()
        inviteTimeoutTimer = nil
        isWaitingForInviteAfterPush = false
    }
    
    /// Handles the timeout when no INVITE is received after accepting a VoIP push call
    private func handleInviteTimeout() {
        Logger.log.w(message: "TxClient:: INVITE timeout - No INVITE received within \(inviteTimeoutInterval) seconds after accepting VoIP push call")
        let timedOutCallId = currentCallId
        let pendingAnswerAction = answerCallAction
        
        // Create the termination reason as specified in the ticket
        let terminationReason = CallTerminationReason(
            cause: "ORIGINATOR_CANCEL",
            causeCode: 487,
            sipCode: 487,
            sipReason: "Request Terminated",
            origin: .inviteTimeout
        )
        
        // Emit both delegate events to ensure proper CallKit termination
        delegate?.onRemoteCallEnded(callId: timedOutCallId, reason: terminationReason)
        delegate?.onCallStateUpdated(callState: CallState.DONE(reason: terminationReason),
                                     callId: timedOutCallId)
        
        // Resolve the CallKit action before reset clears the stored action reference.
        pendingAnswerAction?.fulfill()
        resetPushVariables()
        
        Logger.log.i(message: "TxClient:: INVITE timeout handled - Call terminated with ORIGINATOR_CANCEL, CallKit events emitted")
    }
    
    /// To end and control callKit active and conn
    public func endCallFromCallkit(endAction: CXEndCallAction,
                                   callId: UUID? = nil) {
        Logger.log.i(message: "TxClient:: endCallFromCallkit - started for callID \(String(describing: endAction.callUUID))")

        self.endCallAction = endAction
        
        // Check if the call was initiated by a push notification
        if isCallFromPush {
            Logger.log.i(message: "TxClient:: endCallFromCallkit - Call initiated by push notification, sending decline_push")
            answerCallAction?.fail()
            answerCallAction = nil
            self.pendingCallDecline = true
            self.currentCallId = callId ?? endAction.callUUID

            // Send a login message with decline_push: true to silently reject the call
            if isConnected() {
                Logger.log.i(message: "TxClient:: endCallFromCallkit - Socket connected, performing login with decline_push: true")
                performLogin(declinePush: true)
            } else {
                Logger.log.i(message: "TxClient:: endCallFromCallkit - Socket not connected, connecting first")
                guard let storedServerConfiguration = storedServerConfiguration else {
                    Logger.log.e(message: "TxClient:: endCallFromCallkit missing stored server configuration")
                    failEndCallAction(endAction)
                    return
                }

                do {
                    try connectSocketOnly(serverConfiguration: storedServerConfiguration)
                    // Login with decline_push will happen in onSocketConnected
                    // Provider completion is reported only after the gateway
                    // accepts the decline_push login.
                } catch let error {
                    Logger.log.e(message: "TxClient:: endCallFromCallkit connect error \(error.localizedDescription)")
                    failEndCallAction(endAction)
                    return
                }
            }
            
            // Remove pending call from internal list
            if let callUUID = endAction.callUUID as UUID?,
               let call = self.calls[callUUID] {
                // Clean up reverse mapping if signaling ID differs
                if call.signalingCallId != callUUID {
                    socketToAppCallId.removeValue(forKey: call.signalingCallId)
                }
                self.calls.removeValue(forKey: callUUID)
            }
            
            self.stopReconnectTimeout()
            endAction.fulfill()
            return
        }
        
        // If the call was not initiated by push and there's an active call (currentCall exists)
        // Perform a standard call rejection
        if let call = self.calls[endAction.callUUID] {
            Logger.log.i(message: "EndClient:: Ended Call with Id \(endAction.callUUID)")
            call.hangup()
            self.resetPushVariables()
            self.stopReconnectTimeout()
            endAction.fulfill()
        } else {
            Logger.log.e(message: "TxClient:: endCallFromCallkit failed - no call found for \(endAction.callUUID)")
            failEndCallAction(endAction)
        }
    }
    
    
    /// Disables push notifications for the current user.
    ///
    /// The delegate is notified only after the exact request is acknowledged on
    /// the socket that sent it. A newer request supersedes any pending request.
    public func disablePushNotifications() {
        let start: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.startDisablePushNotifications()
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }

    private func startDisablePushNotifications() {
        Logger.log.i(message: "TxClient:: disablePush()")
        if let superseded = takePendingDisablePush() {
            notifyDisablePushCompletion(
                superseded,
                success: false,
                message: "disable push notification request superseded"
            )
        }

        guard let config = txConfig else {
            delegate?.onPushDisabled(
                success: false,
                message: "disable push notification configuration unavailable"
            )
            return
        }
        guard let sourceSocket = socket else {
            delegate?.onPushDisabled(
                success: false,
                message: "disable push notification socket unavailable"
            )
            return
        }

        let pushProvider = config.pushNotificationConfig?.pushNotificationProvider
        let pushToken = config.pushNotificationConfig?.pushDeviceToken
        let disablePushMessage: DisablePushMessage
        if let sipUser = config.sipUser {
            disablePushMessage = DisablePushMessage(
                user: sipUser,
                pushDeviceToken: pushToken,
                pushNotificationProvider: pushProvider,
                pushEnvironment: config.pushEnvironment
            )
        } else if let token = config.token {
            disablePushMessage = DisablePushMessage(
                loginToken: token,
                pushDeviceToken: pushToken,
                pushNotificationProvider: pushProvider,
                pushEnvironment: config.pushEnvironment
            )
        } else {
            delegate?.onPushDisabled(
                success: false,
                message: "disable push notification credentials unavailable"
            )
            return
        }

        guard let encodedMessage = disablePushMessage.encode() else {
            delegate?.onPushDisabled(
                success: false,
                message: "disable push notification request could not be encoded"
            )
            return
        }

        disablePushGeneration &+= 1
        let generation = disablePushGeneration
        let messageId = disablePushMessage.id
        let timeoutWorkItem = DispatchWorkItem { [weak self, weak sourceSocket] in
            guard let self, let sourceSocket else { return }
            _ = self.finishPendingDisablePush(
                messageId: messageId,
                socket: sourceSocket,
                generation: generation,
                success: false,
                message: "disable push notification request timed out"
            )
        }
        let pending = PendingDisablePush(
            messageId: messageId,
            generation: generation,
            socket: sourceSocket,
            timeoutWorkItem: timeoutWorkItem
        )
        setPendingDisablePush(pending)

        guard sourceSocket.sendMessage(message: encodedMessage) else {
            _ = finishPendingDisablePush(
                messageId: messageId,
                socket: sourceSocket,
                generation: generation,
                success: false,
                message: "disable push notification request could not be sent"
            )
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.0, disablePushTimeoutInterval),
            execute: timeoutWorkItem
        )
    }

    private func setPendingDisablePush(_ pending: PendingDisablePush) {
        disablePushLock.lock()
        pendingDisablePush = pending
        disablePushLock.unlock()
    }

    private func failPendingDisablePushForSocketReplacement() {
        guard let sourceSocket = socket else { return }
        _ = finishPendingDisablePush(
            socket: sourceSocket,
            success: false,
            message: "socket replaced before push notifications were disabled"
        )
    }

    private func takePendingDisablePush(
        messageId: String? = nil,
        socket expectedSocket: Socket? = nil,
        generation: UInt? = nil
    ) -> PendingDisablePush? {
        disablePushLock.lock()
        defer { disablePushLock.unlock() }
        guard let pending = pendingDisablePush else { return nil }
        if let messageId, pending.messageId != messageId { return nil }
        if let expectedSocket, pending.socket !== expectedSocket { return nil }
        if let generation, pending.generation != generation { return nil }
        pendingDisablePush = nil
        return pending
    }

    private func notifyDisablePushCompletion(
        _ pending: PendingDisablePush,
        success: Bool,
        message: String
    ) {
        pending.timeoutWorkItem?.cancel()
        delegate?.onPushDisabled(success: success, message: message)
    }

    @discardableResult
    private func finishPendingDisablePush(
        messageId: String? = nil,
        socket expectedSocket: Socket? = nil,
        generation: UInt? = nil,
        success: Bool,
        message: String
    ) -> Bool {
        guard let pending = takePendingDisablePush(
            messageId: messageId,
            socket: expectedSocket,
            generation: generation
        ) else {
            return false
        }
        notifyDisablePushCompletion(pending, success: success, message: message)
        return true
    }

    private func validDisablePushSuccessMessage(
        from result: [String: Any]?
    ) -> String? {
        guard let result else { return nil }
        let message = result["message"] as? String
        if result.keys.contains(DisablePushMessage.SUCCESS_KEY) {
            let successValue = result[DisablePushMessage.SUCCESS_KEY]
            let isSuccess = (successValue as? Bool) == true ||
                (successValue as? String)?.lowercased() == "true" ||
                (successValue as? String) == DisablePushMessage.DISABLE_PUSH_SUCCESS_MESSAGE
            return isSuccess ? (message ?? DisablePushMessage.DISABLE_PUSH_SUCCESS_MESSAGE) : nil
        }
        guard message == DisablePushMessage.DISABLE_PUSH_SUCCESS_MESSAGE else {
            return nil
        }
        return message
    }

    @discardableResult
    private func handleDisablePushResponse(
        responseId: String,
        socket responseSocket: Socket,
        result: [String: Any]?
    ) -> Bool {
        disablePushLock.lock()
        let matchesPending = pendingDisablePush?.messageId == responseId &&
            pendingDisablePush?.socket === responseSocket
        disablePushLock.unlock()
        guard matchesPending else { return false }

        guard let successMessage = validDisablePushSuccessMessage(from: result) else {
            return finishPendingDisablePush(
                messageId: responseId,
                socket: responseSocket,
                success: false,
                message: "disable push notification was not confirmed"
            )
        }
        return finishPendingDisablePush(
            messageId: responseId,
            socket: responseSocket,
            success: true,
            message: successMessage
        )
    }

    /// Get the current session ID after logging into Telnyx Backend.
    /// - Returns: The current sessionId. If this value is empty, that means that the client is not connected to Telnyx server.
    public func getSessionId() -> String {
        return sessionId ?? ""
    }
    
    /// Performs an anonymous login to the Telnyx backend for AI assistant connections.
    /// This method allows connecting to AI assistants without traditional authentication.
    /// 
    /// If the socket is already connected, the anonymous login message is sent immediately.
    /// If not connected, the socket connection process is started, and the anonymous login 
    /// message is sent once the connection is established.
    /// 
    /// - Parameters:
    ///   - targetId: The target ID for the AI assistant
    ///   - targetType: The target type (defaults to "ai_assistant")
    ///   - targetVersionId: Optional target version ID
    ///   - userVariables: Optional user variables to include in the login
    ///   - reconnection: Whether this is a reconnection attempt (defaults to false)
    ///   - serverConfiguration: Server configuration to use for connection (defaults to TxServerConfiguration())
    public func anonymousLogin(
        targetId: String, 
        targetType: String = "ai_assistant", 
        targetVersionId: String? = nil,
        userVariables: [String: Any] = [:],
        reconnection: Bool = false,
        serverConfiguration: TxServerConfiguration = TxServerConfiguration()
    ) {
        Logger.log.i(message: "TxClient:: anonymousLogin() targetId: \(targetId), targetType: \(targetType)")
        
        // Generate session ID if not available
        if self.sessionId == nil {
            self.sessionId = UUID().uuidString
        }
        
        guard let sessionId = self.sessionId else {
            Logger.log.e(message: "TxClient:: anonymousLogin() failed to generate sessionId")
            self.delegate?.onClientError(error: TxError.callFailed(reason: .sessionIdIsRequired))
            return
        }
        
        let anonymousLoginMessage = AnonymousLoginMessage(
            targetType: targetType,
            targetId: targetId,
            targetVersionId: targetVersionId,
            sessionId: sessionId,
            userVariables: userVariables,
            reconnection: reconnection
        )
        
        if let socket = self.socket, socket.isConnected {
            // Socket is already connected, send the message immediately
            Logger.log.i(message: "TxClient:: anonymousLogin() socket connected, sending message immediately")
            socket.sendMessage(message: anonymousLoginMessage.encode())
            
            // Update AI Assistant Manager state
            self.aiAssistantManager.updateConnectionState(
                connected: true,
                targetId: targetId,
                targetType: targetType,
                targetVersionId: targetVersionId
            )
        } else {
            // Socket is not connected, store the message and start connection
            Logger.log.i(message: "TxClient:: anonymousLogin() socket not connected, starting connection process")
            self.pendingAnonymousLoginMessage = anonymousLoginMessage
            
            // Set up server configuration
            if self.voiceSdkId != nil {
                Logger.log.i(message: "TxClient:: anonymousLogin() with voice_sdk_id")
                self.serverConfiguration = TxServerConfiguration(
                    signalingServer: serverConfiguration.signalingServer,
                    webRTCIceServers: serverConfiguration.webRTCIceServers,
                    environment: serverConfiguration.environment,
                    pushMetaData: ["voice_sdk_id": self.voiceSdkId!]
                )
            } else {
                Logger.log.i(message: "TxClient:: anonymousLogin() without voice_sdk_id")
                self.serverConfiguration = serverConfiguration
            }
            
            Logger.log.i(message: "TxClient:: anonymousLogin() serverConfiguration server: [\(self.serverConfiguration.signalingServer)] ICE Servers [\(self.serverConfiguration.webRTCIceServers)]")
            
            // Initialize socket and start connection
            self.gatewayState = .NOREG
            self.gatewayRegisteredSocket = nil
            self.failPendingDisablePushForSocketReplacement()
            self.socket = socketFactory()
            self.socket?.delegate = self
            self.aiAssistantManager.setSocket(self.socket)
            self.socket?.connect(signalingServer: self.serverConfiguration.signalingServer)
        }
    }
    
    /// Send a ringing acknowledgment message for a specific call
    /// - Parameter callId: The call ID to acknowledge
    public func sendRingingAck(callId: String) {
        guard let socket = self.socket, socket.isConnected else {
            Logger.log.e(message: "TxClient:: sendRingingAck() socket not connected")
            return
        }
        
        guard let sessionId = self.sessionId else {
            Logger.log.e(message: "TxClient:: sendRingingAck() sessionId not available")
            return
        }
        
        Logger.log.i(message: "TxClient:: sendRingingAck() callId: \(callId)")
        
        let ringingAckMessage = RingingAckMessage(callId: callId, sessionId: sessionId)
        socket.sendMessage(message: ringingAckMessage.encode())
    }
    
    /// Send a text message to AI Assistant during active call (mixed-mode communication)
    /// - Parameter message: The text message to send to AI assistant
    /// - Returns: True if message was sent successfully, false otherwise
    @discardableResult
    public func sendAIAssistantMessage(_ message: String) -> Bool {
        Logger.log.i(message: "TxClient:: sendAIAssistantMessage() message: '\(message)'")
        return aiAssistantManager.sendAIAssistantMessage(message)
    }

    /// Send a text message with multiple Base64 encoded images to AI Assistant during active call
    /// - Parameters:
    ///   - message: The text message to send to AI assistant
    ///   - base64Images: Optional array of Base64 encoded image data (without data URL prefix)
    ///   - imageFormat: Image format (jpeg, png, etc.). Defaults to "jpeg"
    /// - Returns: True if message was sent successfully, false otherwise
    @discardableResult
    public func sendAIAssistantMessage(_ message: String, base64Images: [String]?, imageFormat: String = "jpeg") -> Bool {
        let imageCount = base64Images?.count ?? 0
        let logMessage = imageCount > 0 ? "text message with \(imageCount) image(s)" : "text message"
        Logger.log.i(message: "TxClient:: sendAIAssistantMessage() \(logMessage): '\(message)'")
        return aiAssistantManager.sendAIAssistantMessage(message, base64Images: base64Images, imageFormat: imageFormat)
    }

    /// This function check the gateway status updates to determine if the current user has been successfully
    /// registered and can start receiving and/or making calls.
    /// - Parameter newState: The new gateway state received from B2BUA
    private func updateGatewayState(
        newState: GatewayStates,
        responseId: String,
        socket responseSocket: Socket
    ) {
        guard responseSocket === socket else {
            Logger.log.i(message: "TxClient:: ignoring gateway state from obsolete socket")
            return
        }
        Logger.log.i(message: "TxClient:: updateGatewayState() newState [\(newState)] gatewayState [\(self.gatewayState)]")

        if pendingCallDecline {
            guard pendingDeclineLoginAccepted,
                  responseId == pendingDeclineGatewayMessageId else {
                Logger.log.i(
                    message: "TxClient:: ignoring gateway state outside the pending decline transaction"
                )
                return
            }
        } else if !pendingActiveCallTerminations.isEmpty {
            guard activeCallTerminationLoginAccepted,
                  responseId == activeCallTerminationGatewayMessageId,
                  let authenticationSocket = activeCallTerminationAuthenticationSocket,
                  authenticationSocket === socket else {
                Logger.log.i(
                    message: "TxClient:: ignoring gateway state outside the active termination transaction"
                )
                return
            }
        }

        if self.gatewayState == .REGED &&
            !pendingCallDecline &&
            pendingActiveCallTerminations.isEmpty {
            // If the client is already registered, we don't need to do anything else.
            return
        }
        // Keep the new state.
        self.gatewayState = newState
        self.gatewayRegisteredSocket = newState == .REGED ? responseSocket : nil
        switch newState {
            case .REGED:
                // If the client is now registered:
                // - Stop the timer
                // - Propagate the client state to the app.
                self.registerTimer.invalidate()
                
                // Handle decline_push case - disconnect immediately after successful login
                if pendingCallDecline {
                    Logger.log.i(message: "TxClient:: updateGatewayState() decline_push completed, disconnecting")
                    confirmPendingCallKitDecline()
                    self.disconnect()
                    return
                }

                if !pendingActiveCallTerminations.isEmpty,
                   let authenticationSocket = activeCallTerminationAuthenticationSocket,
                   authenticationSocket === socket {
                    activeCallTerminationAuthenticatedSocket = authenticationSocket
                    activeCallTerminationLoginMessageId = nil
                    activeCallTerminationLoginAccepted = false
                    activeCallTerminationClientReadySeen = false
                    activeCallTerminationGatewayMessageId = nil
                    activeCallTerminationAuthenticationSocket = nil
                }

                performOnActiveCallTerminationQueue { [weak self] in
                    self?.drainActiveCallTerminationsIfReady()
                }
                
                self.delegate?.onClientReady()
                //Check if isCallFromPush and sendAttachCall Message
                if (self.isCallFromPush == true){
                    self.sendAttachCall()
                    
                    // Start INVITE timeout for VoIP push calls that are being answered (not declined)
                    if answerCallAction != nil && !pendingCallDecline && pushCallState != .inviteReceived {
                        Logger.log.i(message: "TxClient:: updateGatewayState() Starting INVITE timeout for VoIP push call")
                        startInviteTimeout()
                    }
                }
                break
            default:
                if !pendingActiveCallTerminations.isEmpty {
                    scheduleActiveCallTerminationGatewayPoll()
                    break
                }
                // The gateway state can transition through multiple states before changing to REGED (Registered).
                self.registerTimer.invalidate()
                DispatchQueue.main.async {
                    self.registerTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(TxClient.DEFAULT_REGISTER_INTERVAL), repeats: false) { [weak self] _ in

                        if self?.gatewayState == .REGED {
                            self?.delegate?.onClientReady()
                        } else {
                            self?.registerRetryCount -= 1
                            if self?.registerRetryCount ?? 0 > 0 {
                                self?.requestGatewayState()
                            } else {
                                let notRegisteredError = TxError.serverError(reason: .gatewayNotRegistered)
                                self?.cleanupPendingCallKitDecline(
                                    reason: "decline_push gateway registration timed out"
                                )
                                self?.delegate?.onClientError(error: notRegisteredError)
                                Logger.log.e(message: "TxClient:: updateGatewayState() client not registered")
                            }
                        }
                    }
                }
                break
        }
    }

    @discardableResult
    private func requestGatewayState() -> String {
        let gatewayMessage = GatewayMessage()
        let message = gatewayMessage.encode() ?? ""
        if pendingCallDecline && pendingDeclineLoginAccepted {
            pendingDeclineGatewayMessageId = gatewayMessage.id
        }
        // Request gateway state
        self.socket?.sendMessage(message: message)
        return gatewayMessage.id
    }

    private func advancePendingDeclineIfReady() {
        guard pendingCallDecline,
              pendingDeclineLoginAccepted,
              pendingDeclineClientReadySeen,
              pendingDeclineGatewayMessageId == nil else {
            return
        }
        pendingDeclineGatewayMessageId = requestGatewayState()
    }
}

// MARK: - SDK Initializations
extension TxClient {

    /// This function is called when the TxClient is instantiated. This funciton is intended to be used to initialize any
    /// required tool.
    private func configure() {}
} //END SDK initializations

// MARK: - Call handling
extension TxClient {

    /// This function can be used to access any active call tracked by the SDK.
    ///  A call will be accessible until has ended (transitioned to the DONE state).
    /// - Parameter callId: The unique identifier of a call.
    /// - Returns: The` Call` object that matches the  requested `callId`. Returns `nil` if no call was found.
    public func getCall(callId: UUID) -> Call? {
        return call(forSocketCallId: callId)
    }

    /// Looks up a Call by either its app-facing UUID or signaling UUID.
    private func call(forSocketCallId socketCallId: UUID) -> Call? {
        if let call = calls[socketCallId] { return call }
        if let appId = socketToAppCallId[socketCallId] { return calls[appId] }
        return calls.values.first { $0.signalingCallId == socketCallId }
    }

    /// Creates a new Call and starts the call sequence, negotiate the ICE Candidates and sends the invite.
    ///
    /// This method initiates an outbound call to the specified destination. The call will go through
    /// WebRTC negotiation, ICE candidate gathering, and SIP signaling to establish the connection.
    ///
    /// ### Examples:
    /// ```swift
    /// // Basic call
    /// let call = try telnyxClient.newCall(
    ///     callerName: "John Doe",
    ///     callerNumber: "1234567890",
    ///     destinationNumber: "18004377950",
    ///     callId: UUID()
    /// )
    ///
    /// // Call with preferred audio codecs
    /// let preferredCodecs = [
    ///     TxCodecCapability(mimeType: "audio/opus", clockRate: 48000, channels: 2),
    ///     TxCodecCapability(mimeType: "audio/PCMU", clockRate: 8000, channels: 1)
    /// ]
    /// let call = try telnyxClient.newCall(
    ///     callerName: "John Doe",
    ///     callerNumber: "1234567890",
    ///     destinationNumber: "18004377950",
    ///     callId: UUID(),
    ///     preferredCodecs: preferredCodecs
    /// )
    ///
    /// // Call with codecs and debug mode enabled
    /// let call = try telnyxClient.newCall(
    ///     callerName: "John Doe",
    ///     callerNumber: "1234567890",
    ///     destinationNumber: "18004377950",
    ///     callId: UUID(),
    ///     customHeaders: ["X-Custom-Header": "Value"],
    ///     preferredCodecs: preferredCodecs,
    ///     debug: true
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - callerName: The caller name. This will be displayed as the caller name in the remote's client.
    ///   - callerNumber: The caller Number. The phone number of the current user.
    ///   - destinationNumber: The destination `SIP user address` (sip:YourSipUser@sip.telnyx.com) or `phone number`.
    ///   - callId: The current call UUID.
    ///   - clientState: (optional) Custom state in string format encoded in base64
    ///   - customHeaders: (optional) Custom Headers to be passed over webRTC Messages.
    ///     Headers should be in the format `X-key:Value` where `X-` prefix is required for custom headers.
    ///     When calling AI Agents, headers with the `X-` prefix will be mapped to dynamic variables
    ///     (e.g., `X-Account-Number` becomes `{{account_number}}`). Hyphens in header names are
    ///     converted to underscores in variable names.
    ///   - preferredCodecs: (optional) Array of preferred audio codecs in priority order.
    ///     The SDK will attempt to use these codecs in the specified order during negotiation.
    ///     If none of the preferred codecs are available, WebRTC will fall back to its default codec selection.
    ///     Use `getSupportedAudioCodecs()` to retrieve available codecs before setting preferences.
    ///     See the [Preferred Audio Codecs Guide](https://github.com/team-telnyx/telnyx-webrtc-ios#preferred-audio-codecs) for more information.
    ///   - debug: (optional) Enable debug mode for call quality metrics and WebRTC statistics.
    ///     When enabled, real-time call quality metrics will be available through the call's `onCallQualityChange` callback.
    /// - Throws:
    ///   - sessionId is required if user is not logged in
    ///   - socket connection error if socket is not connected
    ///   - destination number is required to start a call.
    /// - Returns: The call that has been created
    public func newCall(callerName: String,
                        callerNumber: String,
                        destinationNumber: String,
                        callId: UUID,
                        clientState: String? = nil,
                        customHeaders:[String:String] = [:],
                        preferredCodecs: [TxCodecCapability]? = nil,
                        debug:Bool = false) throws -> Call {
        //User needs to be logged in to get a sessionId
        guard let sessionId = self.sessionId else {
            throw TxError.callFailed(reason: .sessionIdIsRequired)
        }
        //A socket connection is required
        guard let socket = self.socket,
              socket.isConnected else {
            throw TxError.socketConnectionFailed(reason: .socketNotConnected)
        }

        //A destination number or sip address is required to start a call
        if destinationNumber.isEmpty {
            throw TxError.callFailed(reason: .destinationNumberIsRequired)
        }

        let call = Call(callId: callId,
                        remoteSdp: "",
                        sessionId: sessionId,
                        socket: socket,
                        delegate: self,
                        ringtone: self.txConfig?.ringtone,
                        ringbackTone: self.txConfig?.ringBackTone,
                        iceServers: self.serverConfiguration.webRTCIceServers,
                        debug: self.txConfig?.debug ?? false,
                        forceRelayCandidate: self.txConfig?.forceRelayCandidate ?? false,
                        sendWebRTCStatsViaSocket: self.txConfig?.sendWebRTCStatsViaSocket ?? false,
                        useTrickleIce: self.txConfig?.useTrickleIce ?? false,
                        enableMissedCallNotifications: self.txConfig?.enableMissedCallNotifications ?? false,
                        enableCallReports: self.txConfig?.enableCallReports ?? true,
                        callReportInterval: self.txConfig?.callReportInterval ?? 5.0,
                        callReportLogLevel: self.txConfig?.callReportLogLevel ?? "debug",
                        callReportMaxLogEntries: self.txConfig?.callReportMaxLogEntries ?? 1000,
                        pushWhenActive: self.txConfig?.pushWhenActive ?? false,
                        pushDeviceToken: self.txConfig?.pushNotificationConfig?.pushDeviceToken,
                        peerFactory: peerFactory)
        call.newCall(callerName: callerName,
                     callerNumber: callerNumber,
                     destinationNumber: destinationNumber,
                     clientState: clientState,
                     customHeaders: customHeaders,
                     preferredCodecs: preferredCodecs,
                     debug: debug)

        currentCallId = callId
        self.calls[callId] = call
        return call
    }
    
    /// Returns the list of supported audio codecs available for use in calls
    /// - Returns: Array of TxCodecCapability objects representing available audio codecs
    ///
    /// This method reuses the shared RTCPeerConnectionFactory instance for efficiency.
    /// The codec list is queried from WebRTC's native capabilities and remains consistent
    /// throughout the application lifecycle.
    ///
    /// ### Example:
    /// ```swift
    /// let supportedCodecs = telnyxClient.getSupportedAudioCodecs()
    /// for codec in supportedCodecs {
    ///     print("Codec: \(codec.mimeType), Clock Rate: \(codec.clockRate)")
    /// }
    /// ```
    public func getSupportedAudioCodecs() -> [TxCodecCapability] {
        // Reuse the shared Peer factory instance instead of creating a new one each time
        let capabilities = Peer.factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
        let codecs = capabilities.codecs

        guard !codecs.isEmpty else {
            Logger.log.w(message: "TxClient:: No audio codecs found")
            return []
        }

        return codecs.map { TxCodecCapability(from: $0) }
    }

    /// Creates a call object when an invite is received.
    /// - Parameters:
    ///   - callerName: The name of the caller
    ///   - callerNumber: The caller phone number
    ///   - callId: The UUID of the incoming call
    ///   - remoteSdp: The SDP of the remote peer
    ///   - telnyxSessionId: The incoming call Telnyx Session ID
    ///   - telnyxLegId: The incoming call Leg ID
    private func createIncomingCall(callerName: String,
                                    callerNumber: String,
                                    callId: UUID,
                                    remoteSdp: String,
                                    telnyxSessionId: String,
                                    telnyxLegId: String,
                                    customHeaders:[String:String] = [:],
                                    isAttach:Bool = false
    ) {

        guard let sessionId = self.sessionId,
        let socket = self.socket else {
            return
        }

        // Determine app-facing vs signaling call IDs
        let appFacingCallId: UUID
        let signalingCallId: UUID

        if isCallFromPush && currentCallId != callId {
            // Push flow: currentCallId is the push call_id, callId is the socket callID
            appFacingCallId = currentCallId
            signalingCallId = callId
            Logger.log.i(message: "TxClient:: Push call ID mapping: app=\(appFacingCallId) -> signaling=\(signalingCallId)")
        } else if let appId = socketToAppCallId[callId], appId != callId {
            // Existing alias mapping learned from the push flow still wins for later socket events.
            appFacingCallId = appId
            signalingCallId = callId
            Logger.log.i(message: "TxClient:: Push-when-active call ID mapping: app=\(appFacingCallId) -> signaling=\(signalingCallId)")
        } else {
            // Normal flow: no mismatch
            appFacingCallId = callId
            signalingCallId = callId
        }

        let reattachedPreferredCodecs = isAttach
            ? self.calls[appFacingCallId]?.preferredAudioCodecs
            : nil

        // Remove placeholder call if it exists from processVoIPNotification
        if appFacingCallId != signalingCallId {
            self.calls.removeValue(forKey: appFacingCallId)
            socketToAppCallId[signalingCallId] = appFacingCallId
        }

        let call = Call(callId: appFacingCallId,
                        signalingCallId: signalingCallId,
                        remoteSdp: remoteSdp,
                        sessionId: sessionId,
                        socket: socket,
                        delegate: self,
                        telnyxSessionId: UUID(uuidString: telnyxSessionId),
                        telnyxLegId: UUID(uuidString: telnyxLegId),
                        ringtone: self.txConfig?.ringtone,
                        ringbackTone: self.txConfig?.ringBackTone,
                        iceServers: self.serverConfiguration.webRTCIceServers,
                        isAttach: isAttach,
                        debug: self.txConfig?.debug ?? false,
                        forceRelayCandidate: self.txConfig?.forceRelayCandidate ?? false,
                        sendWebRTCStatsViaSocket: self.txConfig?.sendWebRTCStatsViaSocket ?? false,
                        useTrickleIce: self.txConfig?.useTrickleIce ?? false,
                        enableMissedCallNotifications: self.txConfig?.enableMissedCallNotifications ?? false,
                        enableCallReports: self.txConfig?.enableCallReports ?? true,
                        callReportInterval: self.txConfig?.callReportInterval ?? 5.0,
                        callReportLogLevel: self.txConfig?.callReportLogLevel ?? "debug",
                        callReportMaxLogEntries: self.txConfig?.callReportMaxLogEntries ?? 1000,
                        pushWhenActive: self.txConfig?.pushWhenActive ?? false,
                        pushDeviceToken: self.txConfig?.pushNotificationConfig?.pushDeviceToken,
                        peerFactory: peerFactory)
        call.callInfo?.callerName = callerName
        call.callInfo?.callerNumber = callerNumber
        call.callOptions = TxCallOptions(audio: true)
        call.inviteCustomHeaders = customHeaders
        self.calls[appFacingCallId] = call
        // propagate the incoming call to the App
        Logger.log.i(message: "TxClient:: push flow createIncomingCall \(call)")

        currentCallId = appFacingCallId
        
        if isAttach {
            Logger.log.i(message: "TxClient :: Attaching Call....")
            call.acceptReAttach(
                peer: nil,
                debug: enableQualityMetrics,
                preferredCodecs: reattachedPreferredCodecs
            )
            return
        }

        if isCallFromPush {
            // A local end always wins over a late provider INVITE. Emitting
            // onPushCall or answering first can resurrect a call which
            // CallKit has already removed.
            if pendingCallDecline || endCallAction != nil {
                if let answerCallAction, !answerCallAction.isComplete {
                    answerCallAction.fail()
                }
                call.hangup()
                stopReconnectTimeout()
                if pendingCallDecline {
                    cleanupPendingCallKitDecline(
                        reason: "INVITE arrived before decline_push was accepted"
                    )
                } else {
                    resetPushVariables()
                }
                currentCallId = UUID()
                return
            }
            self.delegate?.onPushCall(call: call)
            //Answer is pending from push - Answer Call
            if(answerCallAction != nil){
                call.answer(customHeaders: pendingAnswerHeaders, debug: enableQualityMetrics, preferredCodecs: pendingAnswerPreferredCodecs)
                answerCallAction?.fulfill()
                resetPushVariables()
            }
        } else {
            self.delegate?.onIncomingCall(call: call)
        }
        self.isCallFromPush = false
    }
}

// MARK: - Push Notifications handling
extension TxClient {

    /// Call this function to process a VoIP push notification of an incoming call.
    /// This function will be executed when the app was closed and the user executes an action over the VoIP push notification.
    ///  You will need to
    /// - Parameters:
    ///   - txConfig: The desired configuration to login to B2B2UA. User credentials must be the same as the
    ///   - serverConfiguration : required to setup from  VoIP push notification metadata.
    ///   - pushMetaData : meta data payload from VOIP Push notification
    ///                    (this should be gotten from payload.dictionaryPayload["metadata"] as? [String: Any])
    /// - Throws: Error during the connection process
    public func processVoIPNotification(txConfig: TxConfig,
                                        serverConfiguration: TxServerConfiguration,pushMetaData:[String: Any]) throws {
        
        
        let rtc_id = (pushMetaData["voice_sdk_id"] as? String)
        
        // Check if we are already connected and logged in
        FileLogger.isCallFromPush = true

        if(rtc_id == nil){
            Logger.log.e(message: "TxClient:: processVoIPNotification - pushMetaData is empty")
            throw TxError.clientConfigurationFailed(reason: .voiceSdkIsRequired)
        }
        
        self.pushMetaData = pushMetaData
        self.pushCallState = .idle
        
        // Store config objects for later use (don't login immediately)
        self.storedTxConfig = txConfig
        self.storedServerConfiguration = TxServerConfiguration(
            signalingServer:nil,
            webRTCIceServers: serverConfiguration.webRTCIceServers,
            environment: serverConfiguration.environment,
            pushMetaData: pushMetaData,
            region: serverConfiguration.region)
                
        let noActiveCalls = self.calls.filter { 
            $0.value.callState.isConsideredActive
        }.isEmpty

        if noActiveCalls && isConnected() {
            Logger.log.i(message: "TxClient:: processVoIPNotification - No Active Calls disconnect")
            self.disconnect()
        }
        
        if noActiveCalls {
            do {
                Logger.log.i(message: "TxClient:: No Active Calls - Only connecting socket, not logging in")
                // Only initiate socket connection, don't login yet
                try self.connectSocketOnly(serverConfiguration: self.storedServerConfiguration!)
                
                // Create an initial call_object to handle early bye message
                if let newCallId = pushMetaData["call_id"] as? String,
                   let callUUID = UUID(uuidString: newCallId),
                   let socket = self.socket,
                   let iceServers = self.storedServerConfiguration?.webRTCIceServers {
                    self.calls[callUUID] = Call(callId: callUUID,
                                               remoteSdp: "",
                                               sessionId: newCallId,
                                               socket: socket,
                                               delegate: self,
                                               iceServers: iceServers,
                                               debug: self.txConfig?.debug ?? false,
                                               forceRelayCandidate: self.txConfig?.forceRelayCandidate ?? false,
                                               sendWebRTCStatsViaSocket: self.txConfig?.sendWebRTCStatsViaSocket ?? false,
                                               useTrickleIce: self.txConfig?.useTrickleIce ?? false,
                                               enableMissedCallNotifications: self.txConfig?.enableMissedCallNotifications ?? false,
                                               enableCallReports: self.txConfig?.enableCallReports ?? true,
                                               callReportInterval: self.txConfig?.callReportInterval ?? 5.0,
                                               callReportLogLevel: self.txConfig?.callReportLogLevel ?? "debug",
                                               callReportMaxLogEntries: self.txConfig?.callReportMaxLogEntries ?? 1000,
                                               pushWhenActive: self.storedTxConfig?.pushWhenActive ?? false,
                                               pushDeviceToken: self.storedTxConfig?.pushNotificationConfig?.pushDeviceToken,
                                               peerFactory: peerFactory)
                    self.currentCallId = callUUID
                } else {
                    Logger.log.e(message: "TxClient:: processVoIPNotification - Invalid call_id, socket, or ICE servers. Cannot create call object.")
                }
            } catch let error {
                Logger.log.e(message: "TxClient:: push flow connect error \(error.localizedDescription)")
            }
        }
       
    
        self.isCallFromPush = true
    }

    /// To receive INVITE message after Push Noficiation is Received. Send attachCall Command
    func sendAttachCall() {
        Logger.log.e(message: "TxClient:: PN Recieved.. Sending reattach call ")
        let pushProvider = self.txConfig?.pushNotificationConfig?.pushNotificationProvider
        let attachMessage = AttachCallMessage(pushNotificationProvider: pushProvider,pushEnvironment:self.txConfig?.pushEnvironment)
        let message = attachMessage.encode() ?? ""
        attachCallId = attachMessage.id
        self.socket?.sendMessage(message: message)
    }
}

// MARK: - Audio
extension TxClient {

    /// Select the internal earpiece as the audio output
    public func setEarpiece() {
        Logger.log.i(message: "[ACM_RESET] TxClient:: setEarpiece() called")
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.overrideOutputAudioPort(.none)
            _isSpeakerEnabled = false
            Logger.log.i(message: "[ACM_RESET] TxClient:: Earpiece set successfully, _isSpeakerEnabled: \(_isSpeakerEnabled)")
        } catch let error {
            Logger.log.e(message: "[ACM_RESET] TxClient:: Error setting Earpiece \(error)")
        }
    }

    /// Select the speaker as the audio output
    public func setSpeaker() {
        Logger.log.i(message: "[ACM_RESET] TxClient:: setSpeaker() called")
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.overrideOutputAudioPort(.speaker)
            _isSpeakerEnabled = true
            Logger.log.i(message: "[ACM_RESET] TxClient:: Speaker set successfully, _isSpeakerEnabled: \(_isSpeakerEnabled)")
        } catch let error {
            Logger.log.e(message: "[ACM_RESET] TxClient:: Error setting Speaker \(error)")
        }
    }
}

// MARK: - CallProtocol
extension TxClient: CallProtocol {

    func callStateUpdated(call: Call) {
        Logger.log.i(message: "TxClient:: callStateUpdated()")

        guard let callId = call.callInfo?.callId else { return }
        
        // Forward call state
        self.delegate?.onCallStateUpdated(callState: call.callState, callId: callId)

        // Remove call if it has ended
        if case .DONE = call.callState,
           let callId = call.callInfo?.callId {
            Logger.log.i(message: "TxClient:: Remove call")
            self.calls.removeValue(forKey: callId)

            // Clean up reverse mapping if this was a push call with different signaling ID
            if call.signalingCallId != callId {
                socketToAppCallId.removeValue(forKey: call.signalingCallId)
            }

            // Clear AI Assistant transcriptions when call ends
            self.aiAssistantManager.clearTranscriptions()
            
            //Forward call ended state with termination reason if available
            if case let .DONE(reason) = call.callState {
                self.delegate?.onRemoteCallEnded(callId: callId, reason: reason)
            } else {
                self.delegate?.onRemoteCallEnded(callId: callId, reason: nil)
            }
            self._isSpeakerEnabled = false
        }
    }

}

// MARK: - SocketDelegate
/**
 Listen for wss socket events
 */
extension TxClient : SocketDelegate {
    
    /// Stops the reconnection timeout timer.
    /// 
    /// This function cancels the timer that would terminate a call if reconnection takes too long.
    /// It should be called when a call has successfully reconnected or when the call is intentionally ended.
    /// 
    /// Thread-safe implementation that prevents EXC_BREAKPOINT crashes by properly managing
    /// the DispatchSourceTimer lifecycle and avoiding double-cancellation.
    func stopReconnectTimeout() {
        Logger.log.i(message: "Reconnect TimeOut stopped")
        
        // Ensure thread safety by dispatching to the reconnect queue
        guard reconnectTimeoutTimer != nil else {
            Logger.log.i(message: "Reconnect timeout timer is already nil")
            return
        }
        
        reconnectQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if timer exists and is not already cancelled
            if let timer = self.reconnectTimeoutTimer {
                timer.cancel()
                self.reconnectTimeoutTimer = nil
                Logger.log.i(message: "Reconnect timeout timer cancelled successfully")
            }
        }
    }

    /// Starts the reconnection timeout timer.
    /// 
    /// This function initializes and starts a timer that will terminate a call if reconnection
    /// takes longer than the configured timeout period (default: 60 seconds).
    /// 
    /// When the timer expires, the following actions occur:
    /// 1. The call state is updated to DONE
    /// 2. The client disconnects from the signaling server
    /// 3. A reconnectFailed error is triggered via the delegate
    /// 
    /// This prevents calls from being stuck in a "reconnecting" state indefinitely when
    /// network conditions prevent successful reconnection.
    /// 
    /// Thread-safe implementation that properly manages timer lifecycle to prevent crashes.
    func startReconnectTimeout() {
        Logger.log.i(message: "Reconnect TimeOut Started")
        
        // Ensure thread safety by dispatching to the reconnect queue
        reconnectQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any existing timer before creating a new one
            if let existingTimer = self.reconnectTimeoutTimer {
                existingTimer.cancel()
                self.reconnectTimeoutTimer = nil
            }
            
            // Create and configure new timer
            let timer = DispatchSource.makeTimerSource(queue: self.reconnectQueue)
            timer.schedule(deadline: .now() + (self.txConfig?.reconnectTimeout ?? TxConfig.DEFAULT_TIMEOUT))
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                Logger.log.i(message: "Reconnect TimeOut : after \(self.txConfig?.reconnectTimeout ?? TxConfig.DEFAULT_TIMEOUT) secs")
                
                // Execute timeout actions on main queue for UI updates
                self.updateActiveCallsState(callState: CallState.DONE(reason: nil))
                self.disconnect()
                self.delegate?.onClientError(error: TxError.callFailed(reason: .reconnectFailed))
                
                // Clean up timer reference
                self.reconnectTimeoutTimer = nil
            }
            
            // Store reference and start timer
            self.reconnectTimeoutTimer = timer
            timer.resume()
        }
    }
   
    func reconnectClient() {
        if self.isCallsActive {
            updateActiveCallsState(callState: CallState.RECONNECTING(reason: .networkSwitch))
            startReconnectTimeout()
            Logger.log.i(message: "Reconnect Called : Calls are active")
        }else {
            return
        }
        if let txConfig = self.txConfig {
            if(txConfig.reconnectClient){
                guard let currentCall = self.calls[self.currentCallId] else {

                    Logger.log.e(message: "Current Call not available for ATTACH")
                    return
                }
                currentCall.endForAttachCall()
                self.socket?.disconnect(reconnect: true)
            }else {
                Logger.log.i(message: "TxClient:: Reconnect Disabled")
            }
        }else {
            Logger.log.e(message:"TxClient:: Not Reconnecting")
        }
    }
    
    func updateActiveCallsState(callState: CallState) {
        if self.isCallsActive {
            for call in self.calls.values {
                call.updateCallState(callState: callState)
            }
        }
    }
    
  
    func onSocketConnected(socket sourceSocket: Socket) {
        guard sourceSocket === socket else {
            Logger.log.i(message: "TxClient:: ignoring connected callback from obsolete socket")
            return
        }
        clearObsoleteActiveCallTerminationByeTransactions(currentSocket: sourceSocket)
        pushSocketConnectionPending = false
        Logger.log.i(message: "TxClient:: SocketDelegate onSocketConnected()")
        isReconnectPendingForCallKitDecline = false
        self.delegate?.onSocketConnected()

        // Handle push notification flows
        if isCallFromPush {
            Logger.log.i(message: "TxClient:: Socket connected isCallFromPush == true")
            if pendingCallDecline {
                Logger.log.i(message: "TxClient:: Socket connected for decline_push flow")
                performLogin(declinePush: true)
                return
            } else if answerCallAction != nil {
                if pushCallState == .loginSent {
                    Logger.log.i(message: "TxClient:: Socket connected for answer flow - push login already sent")
                } else {
                    Logger.log.i(message: "TxClient:: Socket connected for answer flow")
                    performLogin(declinePush: false)
                    pushCallState = .loginSent
                }
                return
            } else {
                Logger.log.i(message: "TxClient:: Socket connected from push - waiting for CallKit answer or end")
                return
            }
        }

        if !pendingActiveCallTerminations.isEmpty,
           let currentSocket = socket,
           let currentConfig = txConfig ?? storedTxConfig {
            clearActiveCallTerminationByeTransactions(sentOn: currentSocket)
            _ = beginActiveCallTerminationAuthentication(
                on: currentSocket,
                txConfig: currentConfig
            )
            return
        }

        // Check if there's a pending anonymous login message
        if let pendingMessage = self.pendingAnonymousLoginMessage {
            Logger.log.i(message: "TxClient:: SocketDelegate onSocketConnected() sending pending anonymous login message")
            self.socket?.sendMessage(message: pendingMessage.encode())

            // Extract target information from the pending message to update AI Assistant Manager
            if let params = pendingMessage.params {
                let targetId = params["target_id"] as? String
                let targetType = params["target_type"] as? String
                let targetVersionId = params["target_version_id"] as? String

                self.aiAssistantManager.updateConnectionState(
                    connected: true,
                    targetId: targetId,
                    targetType: targetType,
                    targetVersionId: targetVersionId
                )
            }

            self.pendingAnonymousLoginMessage = nil
            return
        }

        // Get push token and push provider if available
        let pushToken = self.txConfig?.pushNotificationConfig?.pushDeviceToken
        let pushProvider = self.txConfig?.pushNotificationConfig?.pushNotificationProvider

        //Login into the signaling server after the connection is produced.
        if let token = self.txConfig?.token  {
            Logger.log.i(message: "TxClient:: SocketDelegate onSocketConnected() login with Token")
            let vertoLogin = LoginMessage(token: token, pushDeviceToken: pushToken,
                                          pushNotificationProvider: pushProvider,
                                          startFromPush: self.isCallFromPush,
                                          pushEnvironment: self.txConfig?.pushEnvironment,
                                          sessionId: self.sessionId!,
                                          declinePush: false,
                                          enableMissedCallNotifications: self.txConfig?.enableMissedCallNotifications ?? false,
                                          pushWhenActive: self.txConfig?.pushWhenActive ?? false)
            self.socket?.sendMessage(message: vertoLogin.encode())
        } else {
            Logger.log.i(message: "TxClient:: SocketDelegate onSocketConnected() login with SIP User and Password")
            guard let sipUser = self.txConfig?.sipUser else { return }
            guard let password = self.txConfig?.password else { return }
            let pushToken = self.txConfig?.pushNotificationConfig?.pushDeviceToken
            let vertoLogin = LoginMessage(user: sipUser,
                                          password: password,
                                          pushDeviceToken: pushToken,
                                          pushNotificationProvider: pushProvider,
                                          startFromPush: self.isCallFromPush,
                                          pushEnvironment: self.txConfig?.pushEnvironment,
                                          sessionId: self.sessionId!,
                                          declinePush: false,
                                          enableMissedCallNotifications: self.txConfig?.enableMissedCallNotifications ?? false,
                                          pushWhenActive: self.txConfig?.pushWhenActive ?? false)
            self.socket?.sendMessage(message: vertoLogin.encode())
        }
    }
    
    func onSocketDisconnected(socket sourceSocket: Socket, reconnect: Bool, region: Region?) {
        _ = finishPendingDisablePush(
            socket: sourceSocket,
            success: false,
            message: "socket disconnected before push notifications were disabled"
        )
        guard sourceSocket === socket else {
            Logger.log.i(message: "TxClient:: ignoring disconnected callback from obsolete socket")
            return
        }
        pushSocketConnectionPending = false
        if !pendingActiveCallTerminations.isEmpty {
            clearActiveCallTerminationByeTransactions(sentOn: sourceSocket)
            gatewayState = .NOREG
            gatewayRegisteredSocket = nil
            resetActiveCallTerminationAuthentication()
            scheduleActiveCallTerminationRecovery()
            delegate?.onSocketDisconnected()
            return
        }
        if reconnect {
            Logger.log.i(message: "TxClient:: SocketDelegate  Reconnecting")
            let declineReconnectGeneration: UInt?
            if pendingCallDecline {
                isReconnectPendingForCallKitDecline = true
                pendingDeclineReconnectGeneration &+= 1
                declineReconnectGeneration = pendingDeclineReconnectGeneration
            } else {
                declineReconnectGeneration = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + TxClient.RECONNECT_BUFFER) {
                if let declineReconnectGeneration {
                    guard self.pendingCallDecline,
                          self.pendingDeclineReconnectGeneration == declineReconnectGeneration else {
                        return
                    }
                }
                do {
                    var updatedServerConfig = self.serverConfiguration

                    // Override region only if region is NOT nil - fallack mechanism for failed refion
                    if region != nil {
                        updatedServerConfig = TxServerConfiguration(
                            signalingServer: nil, // Pass nil to rebuild URL without region prefix
                            webRTCIceServers: updatedServerConfig.webRTCIceServers,
                            environment: updatedServerConfig.environment,
                            pushMetaData: updatedServerConfig.pushMetaData,
                            region: .auto
                        )
                    }

                    guard let reconnectConfig = self.txConfig ?? self.storedTxConfig else {
                        Logger.log.e(message: "TxClient:: SocketDelegate reconnect skipped - missing config")
                        self.cleanupPendingCallKitDecline(reason: "decline_push reconnect skipped because config is missing")
                        return
                    }
                    try self.connect(txConfig: reconnectConfig, serverConfiguration: updatedServerConfig)
                    self.isReconnectPendingForCallKitDecline = false
                } catch let error {
                    Logger.log.e(message: "TxClient:: SocketDelegate reconnect error" + error.localizedDescription)
                    self.cleanupPendingCallKitDecline(reason: "decline_push reconnect failed")
                }
            }
            return
        }

        Logger.log.i(message: "TxClient:: SocketDelegate onSocketDisconnected()")
        cleanupPendingCallKitDecline(reason: "socket disconnected before decline_push login completed")
        self.socket = nil
        self.sessionId = nil
        self.sessionId = UUID().uuidString.lowercased()
        self.delegate?.onSocketDisconnected()
    }

    func onSocketError(socket sourceSocket: Socket, error: Error) {
        _ = finishPendingDisablePush(
            socket: sourceSocket,
            success: false,
            message: "socket error before push notifications were disabled"
        )
        guard sourceSocket === socket else {
            Logger.log.i(message: "TxClient:: ignoring error callback from obsolete socket")
            return
        }
        pushSocketConnectionPending = false
        Logger.log.i(message: "TxClient:: SocketDelegate onSocketError()")
        if !pendingActiveCallTerminations.isEmpty {
            clearActiveCallTerminationByeTransactions(sentOn: sourceSocket)
            gatewayState = .NOREG
            gatewayRegisteredSocket = nil
            resetActiveCallTerminationAuthentication()
            scheduleActiveCallTerminationRecovery()
        }
        if pendingCallDecline && !isReconnectPendingForCallKitDecline {
            cleanupPendingCallKitDecline(reason: "socket error before decline_push login completed")
        }
        self.delegate?.onSocketDisconnected()
        Logger.log.e(message:"TxClient:: Socket Error" +  error.localizedDescription)
    }

    /**
     Each time we receive a message throught  the WSS this method will be called.
     Here we are checking the mesaging
     */
    func onMessageReceived(socket sourceSocket: Socket, message: String) {
        guard sourceSocket === socket else {
            Logger.log.i(message: "TxClient:: ignoring message callback from obsolete socket")
            return
        }
        Logger.log.i(message: "TxClient:: SocketDelegate onMessageReceived() message: \(message)")
        
        // Post notification for websocket message capture
        NotificationCenter.default.post(name: .telnyxWebSocketMessageReceived, object: nil, userInfo: ["message": message])
        
        guard let vertoMessage = Message().decode(message: message) else { return }
        
        // Process message through AI Assistant Manager
        if let messageDict = try? JSONSerialization.jsonObject(with: Data(message.utf8), options: []) as? [String: Any] {
            _ = self.aiAssistantManager.processIncomingMessage(messageDict)
        }
        
       // FileLogger().log(message)

        //Check if server is sending an error code
        if let error = vertoMessage.serverError {
            let disablePushErrorMessage = error["message"] as? String ??
                "disable push notification request was rejected"
            let failedDisablePush = finishPendingDisablePush(
                messageId: vertoMessage.id,
                socket: sourceSocket,
                success: false,
                message: disablePushErrorMessage
            )
            let failedActiveCallTerminationBye = failActiveCallTerminationBye(
                responseId: vertoMessage.id,
                socket: sourceSocket
            )
            if attachCallId == vertoMessage.id {
                attachCallId = nil
                if let callId = pushMetaData?["call_id"] as? String,
                let callUUID = UUID(uuidString: callId) {
                  if pendingActiveCallTerminationCallId(
                    matching: callUUID
                  ) != nil {
                    Logger.log.i(
                      message: "TxClient:: ignoring ATTACH error as active call termination evidence"
                    )
                    scheduleActiveCallTerminationRecovery(delay: 0.0)
                    return
                  }
                  Logger.log.i(
                    message: "TxClient:: ATTACH error is not remote termination evidence for \(callUUID)"
                  )
                }
                // Authentication, gateway, or transient reattach failures can
                // all reject ATTACH while the carrier call still exists. Let
                // the normal client error and bounded invite recovery paths
                // handle it without manufacturing remote BYE or DONE.
            }
            let message: String = error["message"] as? String ?? "Unknown"
            let codeInt: Int = error["code"] as? Int ?? 0
            let code: String = String(codeInt)

            if pendingCallDecline &&
                (vertoMessage.id == pendingDeclineLoginMessageId ||
                    vertoMessage.id == pendingDeclineGatewayMessageId) {
                cleanupPendingCallKitDecline(
                    reason: "decline_push server error \(code): \(message)"
                )
            }
            if !pendingActiveCallTerminations.isEmpty &&
                (vertoMessage.id == activeCallTerminationLoginMessageId ||
                    vertoMessage.id == activeCallTerminationGatewayMessageId) {
                resetActiveCallTerminationAuthentication()
                gatewayState = .NOREG
                gatewayRegisteredSocket = nil
                scheduleActiveCallTerminationRecovery(delay: 0.0)
            }

            // Use the existing ServerErrorReason.signalingServerError approach
            let err = TxError.serverError(reason: .signalingServerError(message: message, code: code))
            self.delegate?.onClientError(error: err)
            if failedDisablePush || failedActiveCallTerminationBye {
                return
            }
        }

        if vertoMessage.jsonMessage.keys.contains("result"),
           handleDisablePushResponse(
                responseId: vertoMessage.id,
                socket: sourceSocket,
                result: vertoMessage.result
           ) {
            return
        }

        if vertoMessage.jsonMessage.keys.contains("result"),
           confirmActiveCallTerminationBye(
                responseId: vertoMessage.id,
                socket: sourceSocket
           ) {
            return
        }

        //Check if we are getting the new sessionId in response to the "login" message.
        if let result = vertoMessage.result {
            if pendingCallDecline &&
                vertoMessage.id == pendingDeclineLoginMessageId {
                pendingDeclineLoginAccepted = true
                advancePendingDeclineIfReady()
            }
            if !pendingActiveCallTerminations.isEmpty &&
                vertoMessage.id == activeCallTerminationLoginMessageId &&
                activeCallTerminationAuthenticationSocket === sourceSocket {
                activeCallTerminationLoginAccepted = true
                advanceActiveCallTerminationAuthenticationIfReady()
            }
            // Process gateway state result.
            if let params = result["params"] as? [String: Any],
               let state = params["state"] as? String,
               let gatewayState = GatewayStates(rawValue: state) {
                Logger.log.i(message: "GATEWAY_STATE RESULT HERE: \(state)")
                self.voiceSdkId = vertoMessage.voiceSdkId
                Logger.log.i(message: "VDK \(String(describing: vertoMessage.voiceSdkId))")
                
                // Capture call_report_id and voice_sdk_id for SDK call reporting
                if let callReportId = params["call_report_id"] as? String {
                    self.socket?.callReportId = callReportId
                    Logger.log.i(message: "TelnyxCallReportCollector: Captured call_report_id from REGED: \(callReportId)")
                } else {
                    Logger.log.w(message: "TelnyxCallReportCollector: No call_report_id found in REGED params: \(params.keys.joined(separator: ", "))")
                }
                self.socket?.voiceSdkId = vertoMessage.voiceSdkId
                
                self.updateGatewayState(
                    newState: gatewayState,
                    responseId: vertoMessage.id,
                    socket: sourceSocket
                )
              
            }
            
            //process ICE restart response (updateMedia)
            if let action = result["action"] as? String,
               action == "updateMedia",
               let callID = result["callID"] as? String,
               let callUUID = UUID(uuidString: callID),
               let call = call(forSocketCallId: callUUID) {
                call.handleVertoMessage(message: vertoMessage, dataMessage: message, txClient: self)
                // For ICE restart, we don't need to process sessionId, so we can return here
                return
            }

            guard let sessionId = result["sessid"] as? String else { return }
            //keep the sessionId
            self.sessionId = sessionId
            self.delegate?.onSessionUpdated(sessionId: sessionId)
            
        } else {
            //Forward message to call based on it's uuid
            if let params = vertoMessage.params,
               let callUUIDString = params["callID"] as? String,
               let callUUID = UUID(uuidString: callUUIDString),
               let call = call(forSocketCallId: callUUID) {
                call.handleVertoMessage(message: vertoMessage, dataMessage: message, txClient: self)
            }
            

            Logger.log.i(message: "VDK \(String(describing: vertoMessage.voiceSdkId))")

            //Parse incoming Verto message
            switch vertoMessage.method {
                case .CLIENT_READY:
                    // Once the client logs into the backend, a registration process starts.
                    // Clients can receive or place calls when they are fully registered into the backend.
                    // If a client try to call beforw been registered, a GATEWAY_DOWN error is received.
                    // Therefore, we need to check the gateway state once we have successfully loged in:
                    if pendingCallDecline {
                        pendingDeclineClientReadySeen = true
                        advancePendingDeclineIfReady()
                    } else if !pendingActiveCallTerminations.isEmpty,
                              activeCallTerminationAuthenticationSocket === sourceSocket {
                        activeCallTerminationClientReadySeen = true
                        advanceActiveCallTerminationAuthenticationIfReady()
                    } else {
                        self.requestGatewayState()
                    }
                    // If we are going to receive an incoming call
                    if let params = vertoMessage.params,
                       let _ = params["reattached_sessions"] {
                    }
                    
                    break

                case .INVITE:
                    //invite received
                    if isCallFromPush {
                        pushCallState = .inviteReceived
                    }
                    if isWaitingForInviteAfterPush {
                        Logger.log.i(message: "TxClient:: INVITE received - stopping timeout timer for VoIP push call")
                        stopInviteTimeout()
                    }
                    
                    if let params = vertoMessage.params {
                        guard let sdp = params["sdp"] as? String,
                              let callId = params["callID"] as? String,
                              let uuid = UUID(uuidString: callId) else {
                            return
                        }
                        
                        self.voiceSdkId = vertoMessage.voiceSdkId

                        let callerName = params["caller_id_name"] as? String ?? ""
                        let callerNumber = params["caller_id_number"] as? String ?? ""
                        let telnyxSessionId = params["telnyx_session_id"] as? String ?? ""
                        let telnyxLegId = params["telnyx_leg_id"] as? String ?? ""
                        
                        if telnyxSessionId.isEmpty {
                            Logger.log.w(message: "TxClient:: Telnyx Session ID unavailable on INVITE message")
                        }
                        if telnyxLegId.isEmpty {
                            Logger.log.w(message: "TxClient:: Telnyx Leg ID unavailable on INVITE message")
                        }
                        
                        var customHeaders = [String:String]()
                        if params["dialogParams"] is [String:Any] {
                            do {
                                let dataDecoded = try JSONDecoder().decode(CustomHeaderData.self, from: message.data(using: .utf8)!)
                                dataDecoded.params.dialogParams.custom_headers.forEach { xHeader in
                                    customHeaders[xHeader.name] = xHeader.value
                                }
                            } catch {
                                Logger.log.e(message: "Custom header decoding error: \(error)")
                            }
                        }
                        self.createIncomingCall(callerName: callerName,
                                                callerNumber: callerNumber,
                                                callId: uuid,
                                                remoteSdp: sdp,
                                                telnyxSessionId: telnyxSessionId,
                                                telnyxLegId: telnyxLegId,
                                                customHeaders: customHeaders)
                        if(isCallFromPush){
                            /*FileLogger.shared.log("INVITE : \(message) \n")
                            FileLogger.shared.log("INVITE telnyxLegId: \(telnyxLegId) \n") */
                            self.sendFileLogs = true
                        }

                    }

                    break;
            case .ATTACH:
                Logger.log.i(message: "Attach Received")
                // Stop the timeout
                stopReconnectTimeout()
                if let params = vertoMessage.params {
                    guard let sdp = params["sdp"] as? String,
                          let callId = params["callID"] as? String,
                          let uuid = UUID(uuidString: callId) else {
                        return
                    }
                    
                    self.voiceSdkId = vertoMessage.voiceSdkId

                    let callerName = params["caller_id_name"] as? String ?? ""
                    let callerNumber = params["caller_id_number"] as? String ?? ""
                    let telnyxSessionId = params["telnyx_session_id"] as? String ?? ""
                    let telnyxLegId = params["telnyx_leg_id"] as? String ?? ""
                    
                    if telnyxSessionId.isEmpty {
                        Logger.log.w(message: "TxClient:: Telnyx Session ID unavailable on INVITE message")
                    }
                    if telnyxLegId.isEmpty {
                        Logger.log.w(message: "TxClient:: Telnyx Leg ID unavailable on INVITE message")
                    }
                    
                    var customHeaders = [String:String]()
                    if params["dialogParams"] is [String:Any] {
                        do {
                            let dataDecoded = try JSONDecoder().decode(CustomHeaderData.self, from: message.data(using: .utf8)!)
                            dataDecoded.params.dialogParams.custom_headers.forEach { xHeader in
                                customHeaders[xHeader.name] = xHeader.value
                            }
                        } catch {
                            Logger.log.e(message: "Custom header decoding error: \(error)")
                        }
                    }

                    Logger.log.i(message: "isAudioEnabled : \(self.isAudioDeviceEnabled)")
                    self.createIncomingCall(callerName: callerName,
                                            callerNumber: callerNumber,
                                            callId: uuid,
                                            remoteSdp: sdp,
                                            telnyxSessionId: telnyxSessionId,
                                            telnyxLegId: telnyxLegId,
                                            customHeaders: customHeaders,
                                            isAttach: true
                    )
                    
                }
                 break;
                //Mark: to send meassage to pong
            case .PING:
                // Only reply to ping if we are authenticated (registered).
                // During push flow the socket is unauthenticated until the user
                // answers and performLogin completes. Sending pong on an
                // unauthenticated socket triggers a 401 error from the server
                // which corrupts SDK state and prevents future calls.
                if self.gatewayState == .REGED {
                    self.socket?.sendMessage(message: message)
                } else {
                    Logger.log.i(message: "TxClient:: Ignoring PING - not yet authenticated (gateway: \(self.gatewayState))")
                }
                break;
                default:
                    Logger.log.i(message: "TxClient:: SocketDelegate Default method")
                    break
            }
        }
    }

    internal func onSocketConnected() {
        guard let socket else { return }
        onSocketConnected(socket: socket)
    }

    internal func onSocketDisconnected(reconnect: Bool, region: Region?) {
        guard let socket else { return }
        onSocketDisconnected(socket: socket, reconnect: reconnect, region: region)
    }

    internal func onSocketError(error: Error) {
        guard let socket else { return }
        onSocketError(socket: socket, error: error)
    }

    internal func onMessageReceived(message: String) {
        guard let socket else { return }
        onMessageReceived(socket: socket, message: message)
    }
}

// MARK: - Audio session configurations
extension TxClient {
    internal func resetAudioConfiguration() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
        } catch {
            Logger.log.e(message: "Failed to set audio session category: \(error)")
        }
    }

    internal func setupCorrectAudioConfiguration() {
        do {
            try prepareAudioSessionForCallKit()
        } catch {
            Logger.log.e(message: "Failed to set RTC audio session configuration: \(error)")
        }
    }
}
