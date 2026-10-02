import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/mobile/pages/settings_page.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../common.dart';
import '../nikodesk/cm_capabilities.dart';
import '../nikodesk/cm_camera.dart';
import '../nikodesk/cm_voice_ledger.dart';
import '../nikodesk/cm_voice_start.dart';
import '../nikodesk/cm_tunnel.dart';
import '../nikodesk/cm_tunnel_ledger.dart';
import '../nikodesk/cm_tunnel_native.dart';
import '../nikodesk/voice_session_model.dart';
import '../nikodesk/voice_session_native.dart';
import '../common/formatter/id_formatter.dart';
import '../desktop/pages/server_page.dart' as desktop;
import '../desktop/widgets/tabbar_widget.dart';
import '../mobile/pages/server_page.dart';
import 'model.dart';

const kLoginDialogTag = "LOGIN";

const kUseTemporaryPassword = "use-temporary-password";
const kUsePermanentPassword = "use-permanent-password";
const kUseBothPasswords = "use-both-passwords";

class ServerModel with ChangeNotifier {
  bool _isStart = false; // Android MainService status
  bool _mediaOk = false;
  bool _inputOk = false;
  bool _audioOk = false;
  bool _fileOk = false;
  bool _clipboardOk = false;
  bool _showElevation = false;
  bool hideCm = false;
  int _connectStatus = 0; // Rendezvous Server status
  String _verificationMethod = "";
  String _temporaryPasswordLength = "";
  bool _allowNumericOneTimePassword = false;
  String _approveMode = "";
  int _zeroClientLengthCounter = 0;

  late String _emptyIdShow;
  late final IDTextEditingController _serverId;
  final _serverPasswd =
      TextEditingController(text: translate("Generating ..."));

  final tabController = DesktopTabController(tabType: DesktopTabType.cm);

  final List<Client> _clients = [];
  final Map<int, NikoCapabilityStatus> _nikoCapabilities = {};
  NikoCapabilityStatus? nikoCapability(int id) => _nikoCapabilities[id];
  final Map<int, NikoCameraState> _nikoCameras = {};
  NikoCameraState? nikoCamera(int id) => _nikoCameras[id];
  late final NikoCmVoiceLedger _nikoVoices = NikoCmVoiceLedger(
      command: const NativeNikoCmVoiceTransport().send,
      readAvailability: const NativeNikoCmVoiceTransport().availability)
    ..addListener(notifyListeners);
  NikoVoiceSessionModel? nikoVoice(int id) => _nikoVoices.model(id);
  late final NikoCmTunnelLedger _nikoTunnels = NikoCmTunnelLedger(
      command: const NativeNikoCmTunnelTransport().send)
    ..addListener(notifyListeners);
  NikoCmTunnelModel? nikoTunnel(Client client) {
    if (!const bool.fromEnvironment('NIKODESK')) return null;
    final current = _nikoTunnels.model(client.id);
    return client.nikoTunnel != null && current?.status.identity
        .sameRequest(client.nikoTunnel!.identity) == true ? current : null;
  }

  bool _anchorNikoTunnel(Client client) {
    if (!const bool.fromEnvironment('NIKODESK')) return true;
    final status = client.nikoTunnel;
    final context = client.nikoTunnelContext;
    if (status == null || context == null) {
      if (_nikoTunnels.requiresRetention(client.id)) {
        _nikoTunnels.retire(client.id);
        return false;
      }
      return true;
    }
    return _nikoTunnels.anchor(status, context) ||
        _nikoTunnels.model(client.id) == null;
  }

  void _retainNikoTunnelClients(List<Client> previous) {
    for (final client in previous) {
      if (nikoTunnel(client) == null ||
          !_nikoTunnels.requiresRetention(client.id) ||
          _clients.any((c) => c.id == client.id)) continue;
      client.authorized = false;
      client.disconnected = true;
      _clients.add(client);
      _addTab(client, focusWindow: false);
    }
  }

  Future<bool> closeNikoTunnel(Client client) async {
    final current = nikoTunnel(client);
    if (current == null) return false;
    _nikoTunnels.retire(client.id);
    notifyListeners();
    try {
      await bind.cmCloseConnection(connId: client.id).timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _anchorNikoVoice(Client client) {
    if (!const bool.fromEnvironment('NIKODESK')) return;
    final status = client.nikoVoice;
    if (status != null) {
      _nikoVoices.anchor(status, cleanupOnly: client.nikoVoiceCleanup,
          catalog: client.nikoVoiceCatalog);
    }
  }

  void handleNikoVoice(Map<String, dynamic> event) {
    if (!const bool.fromEnvironment('NIKODESK')) return;
    final payload = event['payload'];
    if (payload is! String) return;
    final status = event['name'] == 'nikodesk_voice_status'
        ? NikoVoiceStatus.parse(payload) : null;
    final catalog = event['name'] == 'nikodesk_voice_catalog'
        ? NikoVoiceCatalog.parse(payload) : null;
    final identity = status?.identity ?? catalog?.identity;
    if (identity == null || event['namespace'] != identity.namespace ||
        event['peer_id'] != identity.peerId ||
        event['connection_nonce'] != identity.connectionNonce) return;
    final clients = _clients.where((client) => client.id == identity.connectionId &&
        client.peerId == identity.peerId && client.type_() == ClientType.remote &&
        (client.nikoVoiceCleanup || client.authorized && !client.disconnected));
    if (clients.isEmpty || _nikoVoices.model(identity.connectionId)?.status.identity
        .sameRequest(identity) != true) return;
    if (clients.first.nikoVoiceCleanup && (status == null ||
        !{'Revoking', 'RecoveryRequired', 'Stopped'}.contains(status.phase))) return;
    if (status != null) {
      _nikoVoices.status(status);
    } else if (catalog != null) {
      _nikoVoices.acceptCatalog(catalog);
    }
  }

  void _anchorNikoCamera(Client client) {
    if (!const bool.fromEnvironment('NIKODESK')) return;
    final status = client.nikoCamera;
    if ((!client.nikoCameraCleanup && (!client.authorized || client.disconnected)) || !client.isViewCamera || status == null) {
      _nikoCameras.remove(client.id);
      return;
    }
    _nikoCameras[client.id] = nikoCameraAnchor(_nikoCameras[client.id], status);
  }

  void markNikoCameraCleanup(NikoCameraStatus status) {
    if (_nikoCameras[status.identity.connectionId]?.markCleanup(status) == true) notifyListeners();
  }

  Future<bool> refreshNikoCamera(NikoCameraStatus captured) async {
    final state = _nikoCameras[captured.identity.connectionId];
    if (!const bool.fromEnvironment('NIKODESK') || state == null ||
        !state.status.identity.sameRequest(captured.identity)) return false;
    try {
      final raw = await bind.cmGetClientsState().timeout(const Duration(seconds: 5));
      if (raw.length > 1048576 || !identical(_nikoCameras[captured.identity.connectionId], state)) return false;
      final snapshots = jsonDecode(raw);
      if (snapshots is! List || snapshots.length > 256) return false;
      for (final snapshot in snapshots) {
        if (snapshot is! Map || snapshot['id'] != captured.identity.connectionId ||
            snapshot['peer_id'] != captured.identity.peerId ||
            !(snapshot['niko_camera_cleanup'] == true && snapshot['disconnected'] == true && snapshot['authorized'] == false || snapshot['authorized'] == true && snapshot['disconnected'] == false) || snapshot['is_view_camera'] != true ||
            snapshot['niko_camera'] is! Map) continue;
        final incoming = NikoCameraStatus.parse(jsonEncode(snapshot['niko_camera']));
        if (incoming != null && state.update(incoming)) {
          notifyListeners();
          return true;
        }
      }
    } catch (_) { }
    return false;
  }

  void handleNikoCamera(Map<String, dynamic> event) {
    if (!const bool.fromEnvironment('NIKODESK') || bind.mainGetAppNameSync() != 'NikoDesk') return;
    final payload = event['payload'];
    if (payload is! String) return;
    final status = event['name'] == 'nikodesk_camera_status' ? NikoCameraStatus.parse(payload) : null;
    final catalog = event['name'] == 'nikodesk_camera_catalog' ? NikoCameraCatalog.parse(payload) : null;
    final identity = status?.identity ?? catalog?.identity;
    if (identity == null) return;
    final clients = _clients.where((c) => c.id == identity.connectionId &&
        c.peerId == identity.peerId && c.isViewCamera && (c.nikoCameraCleanup || c.authorized && !c.disconnected));
    if (clients.isEmpty) return;
    if (clients.first.nikoCameraCleanup && (status == null || !{'Revoking', 'RecoveryRequired', 'Stopped'}.contains(status.phase))) return;
    final state = _nikoCameras[identity.connectionId];
    if (state == null || !state.status.identity.sameRequest(identity)) return;
    if (status != null ? state.update(status) : state.acceptCatalog(catalog!)) notifyListeners();
  }

  void handleNikoCapability(Map<String, dynamic> event) {
    if (bind.mainGetAppNameSync() != 'NikoDesk') return;
    final payload = event['payload'];
    if (payload is! String) return;
    final status = NikoCapabilityStatus.parse(payload);
    if (status == null) return;
    final clients = _clients.where((client) => client.id == status.identity.connectionId &&
        client.peerId == status.identity.peerId && client.isTerminal && !client.disconnected);
    if (clients.isEmpty) return;
    _nikoCapabilities[status.identity.connectionId] = status;
    notifyListeners();
  }

  Timer? cmHiddenTimer;

  final _wakelockKey = UniqueKey();

  bool get isStart => _isStart;

  bool get mediaOk => _mediaOk;

  bool get inputOk => _inputOk;

  bool get audioOk => _audioOk;

  bool get fileOk => _fileOk;

  bool get clipboardOk => _clipboardOk;

  bool get showElevation => _showElevation;

  int get connectStatus => _connectStatus;

  String get verificationMethod {
    final index = [
      kUseTemporaryPassword,
      kUsePermanentPassword,
      kUseBothPasswords
    ].indexOf(_verificationMethod);
    if (index < 0) {
      return kUseBothPasswords;
    }
    return _verificationMethod;
  }

  String get approveMode => _approveMode;

  setVerificationMethod(String method) async {
    await bind.mainSetOption(key: kOptionVerificationMethod, value: method);
    /*
    if (method != kUsePermanentPassword) {
      await bind.mainSetOption(
          key: 'allow-hide-cm', value: bool2option('allow-hide-cm', false));
    }
    */
  }

  String get temporaryPasswordLength {
    final lengthIndex = ["6", "8", "10"].indexOf(_temporaryPasswordLength);
    if (lengthIndex < 0) {
      return "6";
    }
    return _temporaryPasswordLength;
  }

  setTemporaryPasswordLength(String length) async {
    await bind.mainSetOption(key: "temporary-password-length", value: length);
  }

  setApproveMode(String mode) async {
    await bind.mainSetOption(key: kOptionApproveMode, value: mode);
    /*
    if (mode != 'password') {
      await bind.mainSetOption(
          key: 'allow-hide-cm', value: bool2option('allow-hide-cm', false));
    }
    */
  }

  bool get allowNumericOneTimePassword => _allowNumericOneTimePassword;
  switchAllowNumericOneTimePassword() async {
    await mainSetBoolOption(
        kOptionAllowNumericOneTimePassword, !_allowNumericOneTimePassword);
  }

  TextEditingController get serverId => _serverId;

  TextEditingController get serverPasswd => _serverPasswd;

  List<Client> get clients => _clients;

  final controller = ScrollController();

  WeakReference<FFI> parent;

  ServerModel(this.parent) {
    _emptyIdShow = translate("Generating ...");
    _serverId = IDTextEditingController(text: _emptyIdShow);

    /*
    // initital _hideCm at startup
    final verificationMethod =
        bind.mainGetOptionSync(key: kOptionVerificationMethod);
    final approveMode = bind.mainGetOptionSync(key: kOptionApproveMode);
    _hideCm = option2bool(
        'allow-hide-cm', bind.mainGetOptionSync(key: 'allow-hide-cm'));
    if (!(approveMode == 'password' &&
        verificationMethod == kUsePermanentPassword)) {
      _hideCm = false;
    }
    */

    timerCallback() async {
      final connectionStatus =
          jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
      final statusNum = connectionStatus['status_num'] as int;
      if (statusNum != _connectStatus) {
        _connectStatus = statusNum;
        notifyListeners();
      }

      if (desktopType == DesktopType.cm) {
        final res = await bind.cmCheckClientsLength(length: _clients.length);
        if (res != null) {
          debugPrint("clients not match!");
          updateClientState(res);
        } else {
          if (_clients.isEmpty) {
            hideCmWindow();
            if (_zeroClientLengthCounter++ == 12) {
              // 6 second
              windowManager.close();
            }
          } else {
            _zeroClientLengthCounter = 0;
            if (!hideCm) showCmWindow();
          }
        }
      }

      updatePasswordModel();
    }

    if (!isTest) {
      Future.delayed(Duration.zero, () async {
        if (await bind.optionSynced()) {
          await timerCallback();
        }
      });
      Timer.periodic(Duration(milliseconds: 500), (timer) async {
        await timerCallback();
      });
    }

    // Initial keyboard status is off on mobile
    if (isMobile) {
      bind.mainSetOption(key: kOptionEnableKeyboard, value: 'N');
    }
  }

  /// 1. check android permission
  /// 2. check config
  /// audio true by default (if permission on) (false default < Android 10)
  /// file true by default (if permission on)
  checkAndroidPermission() async {
    // audio
    if (androidVersion < 30 ||
        !await AndroidPermissionManager.check(kRecordAudio)) {
      _audioOk = false;
      bind.mainSetOption(key: kOptionEnableAudio, value: "N");
    } else {
      final audioOption = await bind.mainGetOption(key: kOptionEnableAudio);
      _audioOk = audioOption != 'N';
    }

    // Android file transfer is confined to app-specific storage. Files enter
    // and leave the workspace through Android's system document picker.
    final fileOption = await bind.mainGetOption(key: kOptionEnableFileTransfer);
    _fileOk = fileOption != 'N';

    // clipboard
    final clipOption = await bind.mainGetOption(key: kOptionEnableClipboard);
    _clipboardOk = clipOption != 'N';

    notifyListeners();
  }

  updatePasswordModel() async {
    var update = false;
    final temporaryPassword = await bind.mainGetTemporaryPassword();
    final verificationMethod =
        await bind.mainGetOption(key: kOptionVerificationMethod);
    final temporaryPasswordLength =
        await bind.mainGetOption(key: "temporary-password-length");
    final approveMode = await bind.mainGetOption(key: kOptionApproveMode);
    final numericOneTimePassword =
        await mainGetBoolOption(kOptionAllowNumericOneTimePassword);
    /*
    var hideCm = option2bool(
        'allow-hide-cm', await bind.mainGetOption(key: 'allow-hide-cm'));
    if (!(approveMode == 'password' &&
        verificationMethod == kUsePermanentPassword)) {
      hideCm = false;
    }
    */
    if (_approveMode != approveMode) {
      _approveMode = approveMode;
      update = true;
    }
    var stopped = await mainGetBoolOption(kOptionStopService);
    final oldPwdText = _serverPasswd.text;
    if (stopped ||
        verificationMethod == kUsePermanentPassword ||
        _approveMode == 'click') {
      _serverPasswd.text = '-';
    } else {
      if (_serverPasswd.text != temporaryPassword &&
          temporaryPassword.isNotEmpty) {
        _serverPasswd.text = temporaryPassword;
      }
    }
    if (oldPwdText != _serverPasswd.text) {
      update = true;
    }
    if (_verificationMethod != verificationMethod) {
      _verificationMethod = verificationMethod;
      update = true;
    }
    if (_temporaryPasswordLength != temporaryPasswordLength) {
      if (_temporaryPasswordLength.isNotEmpty) {
        bind.mainUpdateTemporaryPassword();
      }
      _temporaryPasswordLength = temporaryPasswordLength;
      update = true;
    }
    if (_allowNumericOneTimePassword != numericOneTimePassword) {
      _allowNumericOneTimePassword = numericOneTimePassword;
      update = true;
    }
    /*
    if (_hideCm != hideCm) {
      _hideCm = hideCm;
      if (desktopType == DesktopType.cm) {
        if (hideCm) {
          await hideCmWindow();
        } else {
          await showCmWindow();
        }
      }
      update = true;
    }
    */
    if (update) {
      notifyListeners();
    }
  }

  toggleAudio() async {
    if (clients.any((c) => !c.disconnected)) {
      await showClientsMayNotBeChangedAlert(parent.target);
    }
    if (!_audioOk && !await AndroidPermissionManager.check(kRecordAudio)) {
      final res = await AndroidPermissionManager.request(kRecordAudio);
      if (!res) {
        showToast(translate('Failed'));
        return;
      }
    }

    _audioOk = !_audioOk;
    bind.mainSetOption(
        key: kOptionEnableAudio, value: _audioOk ? defaultOptionYes : 'N');
    notifyListeners();
  }

  toggleFile() async {
    if (clients.any((c) => !c.disconnected)) {
      await showClientsMayNotBeChangedAlert(parent.target);
    }
    _fileOk = !_fileOk;
    bind.mainSetOption(
        key: kOptionEnableFileTransfer,
        value: _fileOk ? defaultOptionYes : 'N');
    notifyListeners();
  }

  toggleClipboard() async {
    _clipboardOk = !clipboardOk;
    bind.mainSetOption(
        key: kOptionEnableClipboard,
        value: clipboardOk ? defaultOptionYes : 'N');
    notifyListeners();
  }

  toggleInput() async {
    if (clients.any((c) => !c.disconnected)) {
      await showClientsMayNotBeChangedAlert(parent.target);
    }
    if (_inputOk) {
      parent.target?.invokeMethod("stop_input");
      bind.mainSetOption(key: kOptionEnableKeyboard, value: 'N');
    } else {
      if (parent.target != null) {
        /// the result of toggle-on depends on user actions in the settings page.
        /// handle result, see [ServerModel.changeStatue]
        showInputWarnAlert(parent.target!);
      }
    }
  }

  Future<bool> checkRequestNotificationPermission() async {
    debugPrint("androidVersion $androidVersion");
    if (androidVersion < 33) {
      return true;
    }
    if (await AndroidPermissionManager.check(kAndroid13Notification)) {
      debugPrint("notification permission already granted");
      return true;
    }
    var res = await AndroidPermissionManager.request(kAndroid13Notification);
    debugPrint("notification permission request result: $res");
    return res;
  }

  Future<bool> checkFloatingWindowPermission() async {
    debugPrint("androidVersion $androidVersion");
    if (androidVersion < 23) {
      return false;
    }
    if (await AndroidPermissionManager.check(kSystemAlertWindow)) {
      debugPrint("alert window permission already granted");
      return true;
    }
    var res = await AndroidPermissionManager.request(kSystemAlertWindow);
    debugPrint("alert window permission request result: $res");
    return res;
  }

  /// Toggle the screen sharing service.
  toggleService() async {
    if (_isStart) {
      final res = await parent.target?.dialogManager
          .show<bool>((setState, close, context) {
        submit() => close(true);
        return CustomAlertDialog(
          title: Row(children: [
            const Icon(Icons.warning_amber_sharp,
                color: Colors.redAccent, size: 28),
            const SizedBox(width: 10),
            Text(translate("Warning")),
          ]),
          content: Text(translate("android_stop_service_tip")),
          actions: [
            TextButton(onPressed: close, child: Text(translate("Cancel"))),
            TextButton(onPressed: submit, child: Text(translate("OK"))),
          ],
          onSubmit: submit,
          onCancel: close,
        );
      });
      if (res == true) {
        stopService();
      }
    } else {
      await checkRequestNotificationPermission();
      if (bind.mainGetLocalOption(key: kOptionDisableFloatingWindow) != 'Y') {
        await checkFloatingWindowPermission();
      }
      final res = await parent.target?.dialogManager
          .show<bool>((setState, close, context) {
        submit() => close(true);
        return CustomAlertDialog(
          title: Row(children: [
            const Icon(Icons.warning_amber_sharp,
                color: Colors.redAccent, size: 28),
            const SizedBox(width: 10),
            Text(translate("Warning")),
          ]),
          content: Text(translate("android_service_will_start_tip")),
          actions: [
            dialogButton("Cancel", onPressed: close, isOutline: true),
            dialogButton("OK", onPressed: submit),
          ],
          onSubmit: submit,
          onCancel: close,
        );
      });
      if (res == true) {
        startService();
      }
    }
  }

  /// Start the screen sharing service.
  Future<void> startService() async {
    _isStart = true;
    notifyListeners();
    parent.target?.ffiModel.updateEventListener(parent.target!.sessionId, "");
    await parent.target?.invokeMethod("init_service");
    // ugly is here, because for desktop, below is useless
    await bind.mainStartService();
    updateClientState();
    if (isAndroid) {
      androidUpdatekeepScreenOn();
    }
  }

  /// Stop the screen sharing service.
  Future<void> stopService() async {
    _isStart = false;
    closeAll();
    await parent.target?.invokeMethod("stop_service");
    await bind.mainStopService();
    notifyListeners();
    // for androidUpdatekeepScreenOn only
    WakelockManager.disable(_wakelockKey);
  }

  fetchID() async {
    final id = await bind.mainGetMyId();
    if (id != _serverId.id) {
      _serverId.id = id;
      notifyListeners();
    }
  }

  changeStatue(String name, bool value) {
    debugPrint("changeStatue value $value");
    switch (name) {
      case "media":
        _mediaOk = value;
        if (value && !_isStart) {
          startService();
        }
        break;
      case "input":
        if (_inputOk != value) {
          bind.mainSetOption(
              key: kOptionEnableKeyboard,
              value: value ? defaultOptionYes : 'N');
        }
        _inputOk = value;
        break;
      default:
        return;
    }
    notifyListeners();
  }

  // force
  updateClientState([String? json]) async {
    if (isTest) return;
    var res = await bind.cmGetClientsState();
    List<dynamic> clientsJson;
    try {
      clientsJson = jsonDecode(res);
    } catch (e) {
      debugPrint("Failed to decode clientsJson: '$res', error $e");
      return;
    }

    final oldClientLenght = _clients.length;
    final hadNikoCamera = _nikoCameras.isNotEmpty;
    final hadNikoVoice = const bool.fromEnvironment('NIKODESK') && _nikoVoices.isNotEmpty;
    final previousTunnels = const bool.fromEnvironment('NIKODESK')
        ? _clients.where((c) => nikoTunnel(c) != null).toList() : <Client>[];
    final cameraIds = const bool.fromEnvironment('NIKODESK') ? <int>{} : null;
    final voiceIds = const bool.fromEnvironment('NIKODESK') ? <int>{} : null;
    final tunnelIds = const bool.fromEnvironment('NIKODESK') ? <int>{} : null;
    _clients.clear();
    tabController.state.value.tabs.clear();

    for (var clientJson in clientsJson) {
      try {
        final client = Client.fromJson(clientJson);
        if (!_anchorNikoTunnel(client)) continue;
        _anchorNikoCamera(client);
        _anchorNikoVoice(client);
        cameraIds?.add(client.id);
        voiceIds?.add(client.id);
        if (nikoTunnel(client) != null) tunnelIds?.add(client.id);
        if (client.nikoCapability != null) _nikoCapabilities[client.id] = client.nikoCapability!;
        _clients.add(client);
        _addTab(client);
      } catch (e) {
        debugPrint("Failed to decode clientJson '$clientJson', error $e");
      }
    }
    if (cameraIds != null) _nikoCameras.removeWhere((id, _) => !cameraIds.contains(id));
    if (voiceIds != null) _nikoVoices.retain(voiceIds);
    if (tunnelIds != null) {
      _nikoTunnels.retain(tunnelIds);
      _retainNikoTunnelClients(previousTunnels);
    }
    if (desktopType == DesktopType.cm) {
      if (_clients.isEmpty) {
        hideCmWindow();
      } else if (!hideCm) {
        showCmWindow();
      }
    }
    if (_clients.length != oldClientLenght ||
        (const bool.fromEnvironment('NIKODESK') && (hadNikoCamera || _nikoCameras.isNotEmpty ||
            hadNikoVoice || _nikoVoices.isNotEmpty ||
            previousTunnels.isNotEmpty || _nikoTunnels.isNotEmpty))) {
      notifyListeners();
      if (isAndroid) androidUpdatekeepScreenOn();
    }
  }

  void addConnection(Map<String, dynamic> evt) {
    try {
      final client = Client.fromJson(jsonDecode(evt["client"]));
      if (const bool.fromEnvironment('NIKODESK')) {
        final existing = _clients.where((c) => c.id == client.id);
        if (existing.isNotEmpty) existing.first.applyNikoPermissions(client);
      }
      if (!_anchorNikoTunnel(client)) {
        notifyListeners();
        return;
      }
      _anchorNikoCamera(client);
      _anchorNikoVoice(client);
      if (client.nikoCapability != null) _nikoCapabilities[client.id] = client.nikoCapability!;
      if (const bool.fromEnvironment('NIKODESK') && client.nikoTunnel != null) {
        final index = _clients.indexWhere((c) => c.id == client.id);
        if (index >= 0) {
          _clients[index] = client;
          notifyListeners();
          return;
        }
      }
      if (client.nikoCameraCleanup || client.nikoVoiceCleanup || client.nikoTunnelCleanup) {
        final index = _clients.indexWhere((c) => c.id == client.id);
        if (index >= 0) {
          _clients[index] = client;
        } else {
          _clients.add(client);
          _addTab(client);
        }
        notifyListeners();
        return;
      }
      if (client.authorized) {
        parent.target?.dialogManager.dismissByTag(getLoginDialogTag(client.id));
        final index = _clients.indexWhere((c) => c.id == client.id);
        if (index < 0) {
          _clients.add(client);
        } else {
          if (_clients[index].authorized) {
            _clients[index].privacyMode = client.privacyMode;
            if (const bool.fromEnvironment('NIKODESK') && client.nikoVoice != null) {
              _clients[index].nikoVoice = client.nikoVoice;
              _clients[index].nikoVoiceCatalog = client.nikoVoiceCatalog;
            }
            notifyListeners();
            return;
          }
          _clients[index].authorized = true;
          _clients[index].privacyMode = client.privacyMode;
        }
      } else {
        final index = _clients.indexWhere((c) => c.id == client.id);
        if (index >= 0) {
          _clients[index].privacyMode = client.privacyMode;
          notifyListeners();
          return;
        }
        _clients.add(client);
      }
      _addTab(client);
      // remove disconnected
      final index_disconnected = _clients
          .indexWhere((c) => c.disconnected && !c.nikoCameraCleanup && !c.nikoVoiceCleanup &&
              !(const bool.fromEnvironment('NIKODESK') && _nikoTunnels.requiresRetention(c.id)) &&
              c.peerId == client.peerId);
      if (index_disconnected >= 0) {
        _clients.removeAt(index_disconnected);
        tabController.remove(index_disconnected);
      }
      if (desktopType == DesktopType.cm && !hideCm) {
        showCmWindow();
      }
      scrollToBottom();
      notifyListeners();
      if (isAndroid && !client.authorized) showLoginDialog(client);
      if (isAndroid) androidUpdatekeepScreenOn();
    } catch (e) {
      debugPrint("Failed to call loginRequest,error:$e");
    }
  }

  void _addTab(Client client, {bool focusWindow = true}) {
    tabController.add(TabInfo(
        key: client.id.toString(),
        label: client.name,
        closable: false,
        onTap: () {},
        page: desktop.buildConnectionCard(client)));
    Future.delayed(Duration.zero, () async {
      if (focusWindow && !hideCm) windowOnTop(null);
    });
    // Only do the hidden task when on Desktop.
    if (focusWindow && client.authorized && isDesktop) {
      cmHiddenTimer = Timer(const Duration(seconds: 3), () {
        if (!hideCm) windowManager.minimize();
        cmHiddenTimer = null;
      });
    }
    parent.target?.chatModel
        .updateConnIdOfKey(MessageKey(client.peerId, client.id));
  }

  void showLoginDialog(Client client) {
    showClientDialog(
      client,
      client.isFileTransfer
          ? "Transfer file"
          : client.isViewCamera
              ? "View camera"
              : client.isTerminal
                  ? "Terminal"
                  : "Share screen",
      'Do you accept?',
      'android_new_connection_tip',
      () => sendLoginResponse(client, false),
      () => sendLoginResponse(client, true),
    );
  }

  handleVoiceCall(Client client, bool accept) {
    parent.target?.invokeMethod("cancel_notification", client.id);
    bind.cmHandleIncomingVoiceCall(id: client.id, accept: accept);
  }

  showVoiceCallDialog(Client client) {
    showClientDialog(
      client,
      'Voice call',
      'Do you accept?',
      'android_new_voice_call_tip',
      () => handleVoiceCall(client, false),
      () => handleVoiceCall(client, true),
    );
  }

  showClientDialog(Client client, String title, String contentTitle,
      String content, VoidCallback onCancel, VoidCallback onSubmit) {
    parent.target?.dialogManager.show((setState, close, context) {
      cancel() {
        onCancel();
        close();
      }

      submit() {
        onSubmit();
        close();
      }

      return CustomAlertDialog(
        title:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(translate(title)),
          IconButton(onPressed: close, icon: const Icon(Icons.close))
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate(contentTitle)),
            ClientInfo(client),
            Text(
              translate(content),
              style: Theme.of(globalKey.currentContext!).textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          dialogButton("Dismiss", onPressed: cancel, isOutline: true),
          if (approveMode != 'password')
            dialogButton("Accept", onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    }, tag: getLoginDialogTag(client.id));
  }

  scrollToBottom() {
    if (isDesktop) return;
    Future.delayed(Duration(milliseconds: 200), () {
      controller.animateTo(controller.position.maxScrollExtent,
          duration: Duration(milliseconds: 200),
          curve: Curves.fastLinearToSlowEaseIn);
    });
  }

  void sendLoginResponse(Client client, bool res) async {
    if (res) {
      bind.cmLoginRes(connId: client.id, res: res);
      if (!client.isFileTransfer && !client.isTerminal) {
        parent.target?.invokeMethod("start_capture");
      }
      parent.target?.invokeMethod("cancel_notification", client.id);
      client.authorized = true;
      notifyListeners();
    } else {
      bind.cmLoginRes(connId: client.id, res: res);
      parent.target?.invokeMethod("cancel_notification", client.id);
      final index = _clients.indexOf(client);
      tabController.remove(index);
      _clients.remove(client);
      if (isAndroid) androidUpdatekeepScreenOn();
    }
  }

  void onClientRemove(Map<String, dynamic> evt) {
    final capabilityId = int.tryParse(evt['id']?.toString() ?? '');
    if (capabilityId != null) _nikoCapabilities.remove(capabilityId);
    if (capabilityId != null && !_clients.any((c) => c.id == capabilityId && c.nikoCameraCleanup) ) _nikoCameras.remove(capabilityId);
    try {
      final id = int.parse(evt['id'] as String);
      final close = (evt['close'] as String) == 'true';
      if (const bool.fromEnvironment('NIKODESK') &&
          _nikoTunnels.requiresRetention(id)) {
        _nikoTunnels.retire(id);
        for (final client in _clients.where((c) => c.id == id)) {
          client.authorized = false;
          client.disconnected = true;
        }
        notifyListeners();
        return;
      }
      if (const bool.fromEnvironment('NIKODESK') && _clients.any((c) =>
          c.id == id && c.nikoVoiceCleanup &&
          _nikoVoices.model(id)?.status.phase != 'Stopped')) {
        notifyListeners();
        return;
      }
      if (_clients.any((c) => c.id == id)) {
        final index = _clients.indexWhere((client) => client.id == id);
        if (index >= 0) {
          if (close) {
            _clients.removeAt(index);
            tabController.remove(index);
            if (const bool.fromEnvironment('NIKODESK')) _nikoVoices.remove(id);
            if (const bool.fromEnvironment('NIKODESK')) _nikoTunnels.remove(id);
          } else {
            _clients[index].disconnected = true;
          }
        }
        parent.target?.dialogManager.dismissByTag(getLoginDialogTag(id));
        parent.target?.invokeMethod("cancel_notification", id);
      }
      if (desktopType == DesktopType.cm && _clients.isEmpty) {
        hideCmWindow();
      }
      if (isAndroid) androidUpdatekeepScreenOn();
      notifyListeners();
    } catch (e) {
      debugPrint("onClientRemove failed,error:$e");
    }
  }

  /// `byOperator` false means the CM's window went away rather than a person asking for the
  /// peers to go. The sessions end either way; only the close reason differs, and with it
  /// whether the peer is allowed to reconnect. See `ipc::Data::CmWindowClosed`.
  Future<void> closeAll({bool byOperator = true}) async {
    if (const bool.fromEnvironment('NIKODESK')) {
      for (final client in _clients.where((c) => nikoTunnel(c) != null)) {
        _nikoTunnels.retire(client.id);
      }
    }
    await Future.wait(_clients.map((client) => byOperator
        ? bind.cmCloseConnection(connId: client.id)
        : bind.cmCloseConnectionWindow(connId: client.id)));
    final retainedTunnels = const bool.fromEnvironment('NIKODESK')
        ? _clients.where((c) => nikoTunnel(c) != null).toList() : <Client>[];
    if (const bool.fromEnvironment('NIKODESK')) _nikoTunnels.clear();
    _clients.clear();
    _nikoCameras.clear();
    if (const bool.fromEnvironment('NIKODESK')) _nikoVoices.clear();
    tabController.state.value.tabs.clear();
    _retainNikoTunnelClients(retainedTunnels);
    if (isAndroid) androidUpdatekeepScreenOn();
  }

  void jumpTo(int id) {
    final index = _clients.indexWhere((client) => client.id == id);
    tabController.jumpTo(index);
  }

  void setShowElevation(bool show) {
    if (_showElevation != show) {
      _showElevation = show;
      notifyListeners();
    }
  }

  void updateVoiceCallState(Map<String, dynamic> evt) {
    try {
      final client = Client.fromJson(jsonDecode(evt["client"]));
      final index = _clients.indexWhere((element) => element.id == client.id);
      if (index != -1) {
        _clients[index].inVoiceCall = client.inVoiceCall;
        _clients[index].incomingVoiceCall = client.incomingVoiceCall;
        if (client.incomingVoiceCall) {
          if (isAndroid) {
            showVoiceCallDialog(client);
          } else {
            // Has incoming phone call, let's set the window on top.
            Future.delayed(Duration.zero, () {
              windowOnTop(null);
            });
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint("updateVoiceCallState failed: $e");
    }
  }

  void androidUpdatekeepScreenOn() async {
    if (!isAndroid) return;
    var floatingWindowDisabled =
        bind.mainGetLocalOption(key: kOptionDisableFloatingWindow) == "Y" ||
            !await AndroidPermissionManager.check(kSystemAlertWindow);
    final keepScreenOn = floatingWindowDisabled
        ? KeepScreenOn.never
        : optionToKeepScreenOn(
            bind.mainGetLocalOption(key: kOptionKeepScreenOn));
    final on = ((keepScreenOn == KeepScreenOn.serviceOn) && _isStart) ||
        (keepScreenOn == KeepScreenOn.duringControlled &&
            _clients.map((e) => !e.disconnected).isNotEmpty);
    if (on) {
      WakelockManager.enable(_wakelockKey, isServer: true);
    } else {
      WakelockManager.disable(_wakelockKey);
    }
  }
}

enum ClientType {
  remote,
  file,
  camera,
  portForward,
  terminal,
}

class Client {
  int id = 0; // client connections inner count id
  bool authorized = false;
  bool isFileTransfer = false;
  bool isViewCamera = false;
  bool isTerminal = false;
  String portForward = "";
  String name = "";
  String avatar = "";
  String peerId = ""; // peer user's id,show at app
  bool keyboard = false;
  bool clipboard = false;
  bool audio = false;
  bool file = false;
  bool restart = false;
  bool recording = false;
  bool blockInput = false;
  bool privacyMode = false;
  bool disconnected = false;
  bool fromSwitch = false;
  bool inVoiceCall = false;
  bool incomingVoiceCall = false;
  NikoCapabilityStatus? nikoCapability;
  NikoCameraStatus? nikoCamera;
  bool nikoCameraCleanup = false;
  NikoVoiceStatus? nikoVoice;
  NikoCmVoiceStartContext? nikoVoiceContext;
  String? nikoVoicePrepareError;
  int? nikoVoicePrepareDeadline;
  NikoVoiceCatalog? nikoVoiceCatalog;
  bool nikoVoiceCleanup = false;
  NikoTunnelStatus? nikoTunnel;
  NikoTunnelCmContext? nikoTunnelContext;
  bool nikoTunnelCleanup = false;

  RxInt unreadChatMessageCount = 0.obs;

  Client(this.id, this.authorized, this.isFileTransfer, this.isViewCamera,
      this.name, this.peerId, this.keyboard, this.clipboard, this.audio);

  bool applyNikoPermissions(Client confirmed) {
    if (!const bool.fromEnvironment('NIKODESK') || id != confirmed.id ||
        peerId != confirmed.peerId || type_() != confirmed.type_() ||
        disconnected || confirmed.disconnected || confirmed.nikoCameraCleanup ||
        confirmed.nikoVoiceCleanup || confirmed.nikoTunnelCleanup) return false;
    keyboard = confirmed.keyboard;
    clipboard = confirmed.clipboard;
    audio = confirmed.audio;
    file = confirmed.file;
    restart = confirmed.restart;
    recording = confirmed.recording;
    blockInput = confirmed.blockInput;
    privacyMode = confirmed.privacyMode;
    return true;
  }

  Client.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    authorized = json['authorized'];
    isFileTransfer = json['is_file_transfer'];
    // TODO: no entry then default.
    isViewCamera = json['is_view_camera'];
    isTerminal = json['is_terminal'] ?? false;
    portForward = json['port_forward'];
    name = json['name'];
    avatar = json['avatar'] ?? '';
    peerId = json['peer_id'];
    keyboard = json['keyboard'];
    clipboard = json['clipboard'];
    audio = json['audio'];
    file = json['file'];
    restart = json['restart'];
    recording = json['recording'];
    blockInput = json['block_input'];
    privacyMode = json['privacy_mode'] ?? privacyMode;
    disconnected = json['disconnected'];
    fromSwitch = json['from_switch'];
    inVoiceCall = json['in_voice_call'];
    incomingVoiceCall = json['incoming_voice_call'];
    if (const bool.fromEnvironment('NIKODESK') && authorized && !disconnected &&
        type_() == ClientType.remote) {
      final context = NikoCmVoiceStartContext.parse(json['niko_voice_context']);
      if (context?.connectionId == id && context?.peerId == peerId) nikoVoiceContext = context;
      if (nikoVoiceContext != null && json['niko_voice_prepare_deadline'] is int &&
          json['niko_voice_prepare_deadline'] > 0 && json['niko_voice_prepare_error'] is String &&
          RegExp(r'^[a-z0-9_]{1,96}$').hasMatch(json['niko_voice_prepare_error'])) {
        nikoVoicePrepareError = json['niko_voice_prepare_error'];
        nikoVoicePrepareDeadline = json['niko_voice_prepare_deadline'];
      }
    }
    if (const bool.fromEnvironment('NIKODESK') && json['niko_tunnel'] is Map &&
        portForward.isNotEmpty && !isFileTransfer && !isViewCamera && !isTerminal) {
      final tunnel = NikoTunnelStatus.parse(jsonEncode(json['niko_tunnel']));
      final cleanup = json['niko_tunnel_cleanup'] == true && disconnected && !authorized &&
          tunnel != null && {'Revoking', 'RecoveryRequired', 'Stopped'}.contains(tunnel.phase);
      if (tunnel?.identity.connectionId == id && tunnel?.identity.peerId == peerId &&
          (cleanup || authorized && !disconnected) &&
          (json['niko_tunnel_cleanup'] == null || json['niko_tunnel_cleanup'] is bool) &&
          (json['niko_tunnel_cleanup'] != true || cleanup) &&
          (tunnel?.cleanupOnly != true || cleanup)) {
        nikoTunnel = tunnel;
        nikoTunnelCleanup = cleanup;
        nikoTunnelContext = NikoTunnelCmContext.verifiedNative(
            identity: tunnel!.identity, active: !cleanup, cleanupOnly: cleanup);
      }
    }
    if (const bool.fromEnvironment('NIKODESK') && json['niko_capability'] is Map) {
      final capability = NikoCapabilityStatus.parse(jsonEncode(json['niko_capability']));
      if (capability?.identity.connectionId == id && capability?.identity.peerId == peerId && isTerminal) nikoCapability = capability;
    }
    if (const bool.fromEnvironment('NIKODESK') && json['niko_camera'] is Map) {
      final camera = NikoCameraStatus.parse(jsonEncode(json['niko_camera']));
      final cleanup = json['niko_camera_cleanup'] == true && disconnected && !authorized &&
          camera != null && {'Revoking', 'RecoveryRequired', 'Stopped'}.contains(camera.phase);
      if (camera?.identity.connectionId == id && camera?.identity.peerId == peerId && isViewCamera && (cleanup || authorized && !disconnected)) {
        nikoCamera = camera;
        nikoCameraCleanup = cleanup;
      }
    }
    if (const bool.fromEnvironment('NIKODESK') && json['niko_voice'] is Map) {
      final voice = NikoVoiceStatus.parse(jsonEncode(json['niko_voice']));
      final cleanup = json['niko_voice_cleanup'] == true && disconnected && !authorized &&
          voice != null && {'Revoking', 'RecoveryRequired', 'Stopped'}.contains(voice.phase);
      if (voice?.identity.connectionId == id && voice?.identity.peerId == peerId &&
          type_() == ClientType.remote && (cleanup || authorized && !disconnected) &&
          (voice?.cleanupOnly != true || cleanup)) {
        nikoVoice = voice;
        nikoVoiceCleanup = cleanup;
        if (!cleanup && json['niko_voice_catalog'] is Map) {
          final catalog = NikoVoiceCatalog.parse(jsonEncode(json['niko_voice_catalog']));
          if (catalog != null && voice!.identity.sameRequest(catalog.identity) &&
              voice.revision == catalog.revision &&
              voice.microphonePermission == catalog.microphonePermission &&
              voice.phase == 'Pending') nikoVoiceCatalog = catalog;
        }
      }
    }
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['id'] = id;
    data['authorized'] = authorized;
    data['is_file_transfer'] = isFileTransfer;
    data['is_view_camera'] = isViewCamera;
    data['is_terminal'] = isTerminal;
    data['port_forward'] = portForward;
    data['name'] = name;
    data['avatar'] = avatar;
    data['peer_id'] = peerId;
    data['keyboard'] = keyboard;
    data['clipboard'] = clipboard;
    data['audio'] = audio;
    data['file'] = file;
    data['restart'] = restart;
    data['recording'] = recording;
    data['block_input'] = blockInput;
    data['privacy_mode'] = privacyMode;
    data['disconnected'] = disconnected;
    data['from_switch'] = fromSwitch;
    data['in_voice_call'] = inVoiceCall;
    data['incoming_voice_call'] = incomingVoiceCall;
    if (nikoVoiceContext != null) data['niko_voice_context'] = nikoVoiceContext!.toJson();
    return data;
  }

  ClientType type_() {
    if (isFileTransfer) {
      return ClientType.file;
    } else if (isViewCamera) {
      return ClientType.camera;
    } else if (isTerminal) {
      return ClientType.terminal;
    } else if (portForward.isNotEmpty) {
      return ClientType.portForward;
    } else {
      return ClientType.remote;
    }
  }
}

String getLoginDialogTag(int id) {
  return kLoginDialogTag + id.toString();
}

showInputWarnAlert(FFI ffi) {
  ffi.dialogManager.show((setState, close, context) {
    submit() {
      AndroidPermissionManager.startAction(kActionAccessibilitySettings);
      close();
    }

    return CustomAlertDialog(
      title: Text(translate("How to get Android input permission?")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("android_input_permission_tip1")),
          const SizedBox(height: 10),
          Text(translate("android_input_permission_tip2")),
        ],
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("Open System Setting", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}

Future<void> showClientsMayNotBeChangedAlert(FFI? ffi) async {
  await ffi?.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate("Permissions")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(translate("android_permission_may_not_change_tip")),
        ],
      ),
      actions: [
        dialogButton("OK", onPressed: close),
      ],
      onSubmit: close,
      onCancel: close,
    );
  });
}
