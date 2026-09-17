import UIKit
import Flutter
import AVFoundation
import CallKit
import PushKit

/// BROKA - iOS call integration.
///
/// iOS does not let an app ring the way Android does. Two OS frameworks are
/// mandatory rather than optional:
///
///  • **PushKit** is the only push type that reliably wakes a *terminated*
///    app. A normal APNs/FCM alert can't start a call; a VoIP push can.
///  • **CallKit** is what actually rings, shows the native full-screen
///    incoming-call UI over the lock screen, and routes audio. Since iOS 13
///    it is not merely recommended: if the app receives a VoIP push and does
///    NOT report a call to CallKit in the same callback, the system kills
///    the process and will stop delivering VoIP pushes to it entirely. That
///    is why `reportNewIncomingCall` is invoked unconditionally below,
///    before any parsing that could fail.
///
/// Everything here is a thin native shell: it rings, it answers, it hangs
/// up, and it hands the decision to Dart over a MethodChannel. The actual
/// call (WebRTC peer connection, signaling, media) stays in
/// `webrtc_service.dart`, exactly as on Android. No call logic is duplicated
/// in Swift.
@main
@objc class AppDelegate: FlutterAppDelegate {

  private var callChannel: FlutterMethodChannel?
  private var provider: CXProvider?
  private let callController = CXCallController()
  private var voipRegistry: PKPushRegistry?

  /// CallKit identifies calls by UUID; BROKA identifies them by room_id.
  /// Both directions are needed: CallKit hands us a UUID when the user taps
  /// Answer, and Dart hands us a room_id when it wants a call ended.
  private var roomIdByUUID: [UUID: String] = [:]
  private var uuidByRoomId: [String: UUID] = [:]
  /// Payload of a call that was answered before the Flutter engine was
  /// ready to hear about it (cold start from a locked screen). Replayed
  /// once Dart registers its handler.
  private var pendingAnsweredCall: [String: Any]?
  private var flutterReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.broka.app/callkit",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
      callChannel = channel

      // The Android foreground-service channel also exists on iOS so the
      // shared Dart code can call it unconditionally. iOS keeps a call
      // alive through the `voip`/`audio` background modes plus CallKit, so
      // there is nothing for it to do here - it succeeds and does nothing
      // rather than throwing a MissingPluginException on every call.
      FlutterMethodChannel(
        name: "com.broka.app/call_service",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { _, result in result(nil) }
    }

    configureCallKit()
    configureVoipPush()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - CallKit setup

  private func configureCallKit() {
    let config = CXProviderConfiguration(localizedName: "BROKA")
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    // Generic handle: BROKA calls are identified by listing/room, not by a
    // phone number, and claiming `.phoneNumber` would put fake numbers in
    // the user's native recents list.
    config.supportedHandleTypes = [.generic]
    if let icon = UIImage(named: "AppIcon") {
      config.iconTemplateImageData = icon.pngData()
    }
    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    self.provider = provider
  }

  private func configureVoipPush() {
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  // MARK: - Flutter -> native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ready":
      // Dart has registered its handler. Replay anything that happened
      // before the engine existed (the cold-start answer case).
      flutterReady = true
      if let pending = pendingAnsweredCall {
        pendingAnsweredCall = nil
        callChannel?.invokeMethod("answerCall", arguments: pending)
      }
      result(nil)

    case "reportOutgoingCall":
      // Registers an outgoing call with CallKit so iOS grants the call
      // audio session, shows it in the system UI, and keeps the app alive
      // while backgrounded.
      guard let args = call.arguments as? [String: Any],
            let roomId = args["roomId"] as? String else {
        result(FlutterError(code: "bad_args", message: "roomId required", details: nil))
        return
      }
      let peerName = args["peerName"] as? String ?? "BROKA call"
      let isVideo = args["isVideo"] as? Bool ?? false
      startOutgoingCall(roomId: roomId, peerName: peerName, isVideo: isVideo)
      result(nil)

    case "reportCallConnected":
      guard let args = call.arguments as? [String: Any],
            let roomId = args["roomId"] as? String,
            let uuid = uuidByRoomId[roomId] else { result(nil); return }
      provider?.reportOutgoingCall(with: uuid, connectedAt: Date())
      result(nil)

    case "endCall":
      guard let args = call.arguments as? [String: Any],
            let roomId = args["roomId"] as? String else { result(nil); return }
      endCall(roomId: roomId)
      result(nil)

    case "getVoipToken":
      let token = voipRegistry?.pushToken(for: .voIP)
      result(token.map { hexString(from: $0) })

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startOutgoingCall(roomId: String, peerName: String, isVideo: Bool) {
    let uuid = uuidByRoomId[roomId] ?? UUID()
    roomIdByUUID[uuid] = roomId
    uuidByRoomId[roomId] = uuid

    let handle = CXHandle(type: .generic, value: peerName)
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.isVideo = isVideo
    callController.request(CXTransaction(action: action)) { error in
      if let error = error {
        NSLog("[BROKA] CXStartCallAction failed: \(error.localizedDescription)")
      }
    }
  }

  private func endCall(roomId: String) {
    guard let uuid = uuidByRoomId[roomId] else { return }
    let action = CXEndCallAction(call: uuid)
    callController.request(CXTransaction(action: action)) { [weak self] error in
      if let error = error {
        // The call may already be gone from CallKit's point of view (the
        // user hit the native End button). Clear our own mapping either
        // way so a room id can't leak into a future call.
        NSLog("[BROKA] CXEndCallAction: \(error.localizedDescription)")
      }
      self?.forget(uuid: uuid)
    }
  }

  private func forget(uuid: UUID) {
    if let roomId = roomIdByUUID[uuid] {
      uuidByRoomId.removeValue(forKey: roomId)
    }
    roomIdByUUID.removeValue(forKey: uuid)
  }

  private func hexString(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - PushKit

extension AppDelegate: PKPushRegistryDelegate {

  func pushRegistry(_ registry: PKPushRegistry,
                    didUpdate credentials: PKPushCredentials,
                    for type: PKPushType) {
    guard type == .voIP else { return }
    let token = hexString(from: credentials.token)
    NSLog("[BROKA] VoIP token updated")
    // Dart forwards this to POST /calls/register-token as
    // token_type=apns_voip. Safe if the engine isn't up yet: the Dart side
    // also polls getVoipToken on every login/session restore.
    callChannel?.invokeMethod("voipToken", arguments: ["token": token])
  }

  func pushRegistry(_ registry: PKPushRegistry,
                    didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    callChannel?.invokeMethod("voipToken", arguments: ["token": ""])
  }

  func pushRegistry(_ registry: PKPushRegistry,
                    didReceiveIncomingPushWith payload: PKPushPayload,
                    for type: PKPushType,
                    completion: @escaping () -> Void) {
    guard type == .voIP else { completion(); return }

    let data = payload.dictionaryPayload
    let roomId = data["roomId"] as? String ?? UUID().uuidString
    let callerName = data["callerName"] as? String ?? "BROKA"
    let isVideo = (data["callType"] as? String) == "video"

    let uuid = UUID()
    roomIdByUUID[uuid] = roomId
    uuidByRoomId[roomId] = uuid

    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerName)
    update.localizedCallerName = callerName
    update.hasVideo = isVideo
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false

    // MUST happen on every VoIP push, before anything that can fail. See
    // the class doc comment: skipping it gets the app's VoIP push
    // entitlement revoked by the system.
    provider?.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error = error {
        NSLog("[BROKA] reportNewIncomingCall failed: \(error.localizedDescription)")
      }
      // Hand the full payload to Dart so it can pre-fetch the room-scoped
      // call token while the phone is still ringing - by the time the user
      // taps Answer, connecting is instant.
      if self.flutterReady {
        self.callChannel?.invokeMethod("incomingCall", arguments: data)
      }
      completion()
    }
  }
}

// MARK: - CallKit actions

extension AppDelegate: CXProviderDelegate {

  func providerDidReset(_ provider: CXProvider) {
    // The system tore down all calls (e.g. the provider crashed). Tell Dart
    // so it can clean up any live peer connection rather than leaving the
    // mic hot.
    for (_, roomId) in roomIdByUUID {
      callChannel?.invokeMethod("endCall", arguments: ["roomId": roomId])
    }
    roomIdByUUID.removeAll()
    uuidByRoomId.removeAll()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let roomId = roomIdByUUID[action.callUUID] else {
      action.fail()
      return
    }
    // Prepare the audio session before fulfilling - WebRTC needs the
    // category set by the time CallKit activates the session below.
    configureAudioSessionForCall()

    let args: [String: Any] = ["roomId": roomId]
    if flutterReady {
      callChannel?.invokeMethod("answerCall", arguments: args)
    } else {
      // Cold start: the engine isn't running yet. Stash it and replay on
      // "ready" - without this, answering from a locked screen on a
      // terminated app silently does nothing.
      pendingAnsweredCall = args
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let roomId = roomIdByUUID[action.callUUID] {
      callChannel?.invokeMethod("endCall", arguments: ["roomId": roomId])
    }
    forget(uuid: action.callUUID)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let roomId = roomIdByUUID[action.callUUID] {
      callChannel?.invokeMethod("setMuted",
                                arguments: ["roomId": roomId, "muted": action.isMuted])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    configureAudioSessionForCall()
    provider.reportOutgoingCall(with: action.callUUID, startedConnecting: Date())
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    // flutter_webrtc's iOS implementation needs to know the CallKit-owned
    // session has gone active; without this the peer connection produces no
    // audio at all on iOS even though everything else looks healthy.
    NSLog("[BROKA] CallKit audio session activated")
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("[BROKA] CallKit audio session deactivated")
  }

  private func configureAudioSessionForCall() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord,
                              mode: .voiceChat,
                              options: [.allowBluetooth, .allowBluetoothA2DP])
    } catch {
      NSLog("[BROKA] audio session configuration failed: \(error.localizedDescription)")
    }
  }
}
