import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/nikodesk/tunnel_controller_view.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup.dart';
import 'package:flutter_hbb/nikodesk/tunnel_cleanup_view.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:get/get.dart';

const double _kColumn1Width = 30;
const double _kColumn4Width = 100;
const double _kRowHeight = 60;
const double _kTextLeftMargin = 20;

class _PortForward {
  int localPort;
  String remoteHost;
  int remotePort;

  _PortForward.fromJson(List<dynamic> json)
      : localPort = json[0] as int,
        remoteHost = json[1] as String,
        remotePort = json[2] as int;
}

class PortForwardPage extends StatefulWidget {
  PortForwardPage({
    Key? key,
    required this.id,
    required this.password,
    required this.tabController,
    required this.isRDP,
    required this.isSharedPassword,
    this.forceRelay,
    this.serverNamespace,
    this.connToken,
  }) : super(key: key);
  final String id;
  final String? serverNamespace;
  final String? password;
  final DesktopTabController tabController;
  final bool isRDP;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final SimpleWrapper<State<PortForwardPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _PortForwardPageState)._ffi;
  Future<bool> requestNikoClose() async {
    final state = _lastState.value;
    if (state is _PortForwardPageState && state.mounted) return state.requestNikoClose();
    return false;
  }

  @override
  State<PortForwardPage> createState() {
    final state = _PortForwardPageState();
    _lastState.value = state;
    return state;
  }
}

class _PortForwardPageState extends State<PortForwardPage>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController localPortController = TextEditingController();
  final TextEditingController remoteHostController = TextEditingController();
  final TextEditingController remotePortController = TextEditingController();
  RxList<_PortForward> pfs = RxList.empty(growable: true);
  late FFI _ffi;
  bool _nikoClosing = false, _nikoCloseUnconfirmed = false;

  Future<bool> requestNikoClose({bool query = false}) async {
    if (_nikoClosing) return false;
    final scope = _ffi.serverNamespace;
    final peer = _ffi.nikoTunnelController?.peerId ?? widget.id;
    if (scope == null) return false;
    final owner = NikoTunnelOwnerIdentity(_ffi.sessionId.toString(), scope, peer);
    setState(() => _nikoClosing = true);
    _ffi.nikoTunnelController?.invalidate();
    NikoTunnelCleanupReply? reply;
    try {
      const transport = NativeNikoTunnelCleanupTransport();
      reply = NikoTunnelCleanupReply.parse(await (query ? transport.query(owner) : transport.close(owner))
          .timeout(const Duration(seconds: 5)), owner);
    } catch (_) { /* No timeout or raw error is a cleanup proof. */ }
    final detachable = reply?.confirmed == true || reply?.reason == 'cleanup_pending' ||
        (reply?.ok == true && reply?.reason == 'ui_detached');
    if (reply?.confirmed == true) NikoTunnelCleanupProofs.record(reply!);
    if (detachable) {
      try { await _ffi.close(closeSession: false).timeout(const Duration(seconds: 5)); }
      catch (_) { /* The native original owner remains the cleanup authority. */ }
    }
    if (mounted) setState(() { _nikoClosing = false; _nikoCloseUnconfirmed = !detachable; });
    return detachable;
  }

  Future<void> _retryNikoClose({bool query = false}) async {
    if (!await requestNikoClose(query: query) || !mounted) return;
    final index = widget.tabController.state.value.tabs.indexWhere((tab) => identical(tab.page, widget));
    if (index >= 0) widget.tabController.remove(index);
  }

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    _ffi.start(widget.id,
        isPortForward: true,
        password: widget.password,
        serverNamespace: widget.serverNamespace,
        isSharedPassword: widget.isSharedPassword,
        forceRelay: widget.forceRelay,
        connToken: widget.connToken,
        isRdp: widget.isRDP);
    Get.put<FFI>(_ffi, tag: 'pf_${widget.id}');
    debugPrint("Port forward page init success with id ${widget.id}");
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController.onSelected?.call(widget.id);
    });
  }

  @override
  void dispose() {
    _ffi.close();
    _ffi.dialogManager.dismissAll();
    Get.delete<FFI>(tag: 'pf_${widget.id}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (const bool.fromEnvironment('NIKODESK')) {
      final controller = _ffi.nikoTunnelController;
      return Scaffold(body: Column(children: [
        if (_nikoClosing || _nikoCloseUnconfirmed) Padding(padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Semantics(liveRegion: true, child: Text(_nikoClosing
                ? nikoText('正在退出，等待本机资源确认。', 'Exiting; waiting for local resource confirmation.')
                : nikoText('此会话尚未能退出，窗口已保留。请重试退出或查询清理。',
                    'This session could not exit. The window is retained. Retry exit or check cleanup.'))),
            if (!_nikoClosing) Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _retryNikoClose, child: Text(nikoText('重试退出', 'Retry exit'))),
              OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _retryNikoClose(query: true), child: Text(nikoText('查询清理', 'Check cleanup'))),
            ]),
          ])),
        Expanded(child: controller == null || widget.isRDP
          ? Padding(padding: const EdgeInsets.all(16), child: Text(nikoText(
              '此隧道会话未能创建。请关闭窗口，检查私服与密码后重试。RDP 暂不支持。',
              'The tunnel session could not be created. Close this window, check the private server and password, and retry. RDP is not supported.')))
          : NikoTunnelControllerView(controller: controller,
              sendCommand: _ffi.sendNikoTunnelCommand)),
      ]));
    }
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: FutureBuilder(future: () async {
        if (!widget.isRDP) {
          refreshTunnelConfig();
        }
      }(), builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return Container(
            decoration: BoxDecoration(
                border: Border.all(
                    width: 20,
                    color: Theme.of(context).scaffoldBackgroundColor)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                buildPrompt(context),
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.background,
                        border: Border.all(width: 1, color: MyTheme.border)),
                    child:
                        widget.isRDP ? buildRdp(context) : buildTunnel(context),
                  ),
                ),
              ],
            ),
          );
        }
        return const Offstage();
      }),
    );
  }

  buildPrompt(BuildContext context) {
    return Obx(() => Offstage(
          offstage: pfs.isEmpty && !widget.isRDP,
          child: Container(
              height: 45,
              color: const Color(0xFF007F00),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      translate('Listening ...'),
                      style: const TextStyle(fontSize: 16, color: Colors.white),
                    ),
                    Text(
                      translate('not_close_tcp_tip'),
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFFDDDDDD), height: 1.2),
                    )
                  ])).marginOnly(bottom: 8),
        ));
  }

  buildTunnel(BuildContext context) {
    text(String label) => Expanded(
        child: Text(translate(label)).marginOnly(left: _kTextLeftMargin));

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme,
      ),
      child: Obx(() => ListView.builder(
          controller: ScrollController(),
          itemCount: pfs.length + 2,
          itemBuilder: ((context, index) {
            if (index == 0) {
              return Container(
                height: 25,
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Row(children: [
                  text('Local Port'),
                  const SizedBox(width: _kColumn1Width),
                  text('Remote Host'),
                  text('Remote Port'),
                  SizedBox(
                      width: _kColumn4Width, child: Text(translate('Action')))
                ]),
              );
            } else if (index == 1) {
              return buildTunnelAddRow(context);
            } else {
              return buildTunnelDataRow(context, pfs[index - 2], index - 2);
            }
          }))),
    );
  }

  buildTunnelAddRow(BuildContext context) {
    var portInputFormatter = [
      FilteringTextInputFormatter.allow(RegExp(
          r'^([0-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$'))
    ];

    return Container(
      height: _kRowHeight,
      decoration:
          BoxDecoration(color: Theme.of(context).colorScheme.background),
      child: Row(children: [
        buildTunnelInputCell(context,
            controller: localPortController,
            inputFormatters: portInputFormatter),
        const SizedBox(
            width: _kColumn1Width, child: Icon(Icons.arrow_forward_sharp)),
        buildTunnelInputCell(context,
            controller: remoteHostController, hint: 'localhost'),
        buildTunnelInputCell(context,
            controller: remotePortController,
            inputFormatters: portInputFormatter),
        ElevatedButton(
          onPressed: () async {
            int? localPort = int.tryParse(localPortController.text);
            int? remotePort = int.tryParse(remotePortController.text);
            if (localPort != null &&
                remotePort != null &&
                (remoteHostController.text.isEmpty ||
                    remoteHostController.text.trim().isNotEmpty)) {
              await bind.sessionAddPortForward(
                  sessionId: _ffi.sessionId,
                  localPort: localPort,
                  remoteHost: remoteHostController.text.trim().isEmpty
                      ? 'localhost'
                      : remoteHostController.text.trim(),
                  remotePort: remotePort);
              localPortController.clear();
              remoteHostController.clear();
              remotePortController.clear();
              refreshTunnelConfig();
            }
          },
          child: Text(
            translate('Add'),
          ),
        ).marginSymmetric(horizontal: 10),
      ]),
    );
  }

  buildTunnelInputCell(BuildContext context,
      {required TextEditingController controller,
      List<TextInputFormatter>? inputFormatters,
      String? hint}) {
    return Expanded(
      child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: TextField(
              controller: controller,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                hintText: hint,
              )).workaroundFreezeLinuxMint()),
    );
  }

  Widget buildTunnelDataRow(BuildContext context, _PortForward pf, int index) {
    text(String label) => Expanded(
        child: Text(label, style: const TextStyle(fontSize: 20))
            .marginOnly(left: _kTextLeftMargin));

    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
          color: index % 2 == 0
              ? MyTheme.currentThemeMode() == ThemeMode.dark
                  ? const Color(0xFF202020)
                  : const Color(0xFFF4F5F6)
              : Theme.of(context).colorScheme.background),
      child: Row(children: [
        text(pf.localPort.toString()),
        const SizedBox(width: _kColumn1Width),
        text(pf.remoteHost),
        text(pf.remotePort.toString()),
        SizedBox(
          width: _kColumn4Width,
          child: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              await bind.sessionRemovePortForward(
                  sessionId: _ffi.sessionId, localPort: pf.localPort);
              refreshTunnelConfig();
            },
          ),
        ),
      ]),
    );
  }

  void refreshTunnelConfig() async {
    String peer = bind.mainGetPeerSync(id: widget.id);
    Map<String, dynamic> config = jsonDecode(peer);
    List<dynamic> infos = config['port_forwards'] as List;
    List<_PortForward> result = List.empty(growable: true);
    for (var e in infos) {
      result.add(_PortForward.fromJson(e));
    }
    pfs.value = result;
  }

  buildRdp(BuildContext context) {
    text1(String label) => Expanded(
        child: Text(translate(label)).marginOnly(left: _kTextLeftMargin));
    text2(String label) => Expanded(
            child: Text(
          label,
          style: const TextStyle(fontSize: 20),
        ).marginOnly(left: _kTextLeftMargin));
    return Theme(
      data: Theme.of(context)
          .copyWith(colorScheme: Theme.of(context).colorScheme),
      child: ListView.builder(
          controller: ScrollController(),
          itemCount: 2,
          itemBuilder: ((context, index) {
            if (index == 0) {
              return Container(
                height: 25,
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Row(children: [
                  text1('Local Port'),
                  const SizedBox(width: _kColumn1Width),
                  text1('Remote Host'),
                  text1('Remote Port'),
                ]),
              );
            } else {
              return Container(
                height: _kRowHeight,
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.background),
                child: Row(children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 120,
                        child: ElevatedButton(
                          onPressed: () =>
                              bind.sessionNewRdp(sessionId: _ffi.sessionId),
                          child: Text(
                            translate('New RDP'),
                          ),
                        ).marginSymmetric(vertical: 10),
                      ).marginOnly(left: 20),
                    ),
                  ),
                  const SizedBox(
                      width: _kColumn1Width,
                      child: Icon(Icons.arrow_forward_sharp)),
                  text2('localhost'),
                  text2('RDP'),
                ]),
              );
            }
          })),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
