// A connection manager card in the NikoDesk layout with one capability panel
// in its controls: terminal, camera, voice or tunnel, either waiting for a
// local decision or running, or the offer to call the controller. Statuses
// come from the panels' own test fixtures; a command is only answered as
// queued when a button is pressed.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/nikodesk/cm_camera.dart';
import 'package:flutter_hbb/nikodesk/cm_camera_panel.dart';
import 'package:flutter_hbb/nikodesk/cm_capabilities.dart';
import 'package:flutter_hbb/nikodesk/cm_capability_panel.dart';
import 'package:flutter_hbb/nikodesk/cm_permissions.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel.dart';
import 'package:flutter_hbb/nikodesk/cm_tunnel_panel.dart';
import 'package:flutter_hbb/nikodesk/cm_voice_panel.dart';
import 'package:flutter_hbb/nikodesk/cm_voice_start.dart';
import 'package:flutter_hbb/nikodesk/ui.dart';
import 'package:flutter_hbb/nikodesk/voice_session_model.dart';

import '../nikodesk_cm_camera_test.dart'
    show cameraCatalog, cameraStatus, macFormat;
import '../nikodesk_cm_tunnel_test.dart' show tunnelModel, tunnelStatus;
import '../nikodesk_voice_session_model_test.dart'
    show voiceCatalog, voiceQueued, voiceStatus;

enum NikoTestCmPanel { terminal, camera, voice, tunnel, voiceStart }

class NikoTestCmCard extends StatefulWidget {
  final NikoTestCmPanel panel;
  final bool running;
  const NikoTestCmCard(this.panel, {super.key, this.running = false});
  @override
  State<NikoTestCmCard> createState() => _NikoTestCmCardState();
}

class _NikoTestCmCardState extends State<NikoTestCmCard> {
  NikoVoiceSessionModel? _voice;
  NikoCmTunnelModel? _tunnel;

  @override
  void initState() {
    super.initState();
    final running = widget.running;
    if (widget.panel == NikoTestCmPanel.voice) {
      final status = voiceStatus(
          phase: running ? 'Running' : 'Pending', peerAccepted: running);
      if (running) status['reason'] = '';
      _voice = NikoVoiceSessionModel(
          anchor: NikoVoiceStatus.parse(jsonEncode(status))!,
          availability: NikoVoiceAvailability.enabled,
          transport: (command) async => voiceQueued(command));
      if (!running) {
        final catalog = voiceCatalog();
        final devices = catalog['devices'] as List;
        devices[0]['label'] = 'MacBook Pro Microphone';
        devices[1]['label'] = 'MacBook Pro Speakers';
        _voice!.applyCatalog(NikoVoiceCatalog.parse(jsonEncode(catalog))!);
      }
    }
    if (widget.panel == NikoTestCmPanel.tunnel) {
      _tunnel = tunnelModel(running
          ? tunnelStatus(
              phase: 'Running',
              reason: 'running',
              addresses: const ['127.0.0.1:23456'],
              selected: '127.0.0.1:23456')
          : tunnelStatus(
              revision: '2',
              reason: 'select_exact_address',
              addresses: const ['127.0.0.1:23456', '192.168.1.20:23456']));
    }
  }

  @override
  void dispose() {
    _voice?.dispose();
    _tunnel?.dispose();
    super.dispose();
  }

  NikoCapabilityStatus get _terminal => NikoCapabilityStatus(
      NikoCapabilityIdentity(
          12, 'a' * 64, '418223905', 'b' * 32, 'c' * 32, '1'),
      'Local user UID 501',
      widget.running ? 'Running' : 'Pending',
      widget.running
          ? 'Terminal resource status'
          : 'Waiting for local terminal approval (expires in 120 seconds)',
      '1');

  NikoCameraStatus get _cameraStatus {
    final status = cameraStatus(phase: widget.running ? 'Running' : 'Pending');
    if (widget.running) {
      status['reason'] = 'camera_running';
      status['selection'] = {
        'uid': 'native-exact-uid',
        'format_token': 'e' * 32,
        'format_schema': 'mac-fps-range-v1',
        'width': 1280,
        'height': 720,
        'fps_num': 30,
        'fps_den': 1,
      };
    }
    return NikoCameraStatus.parse(jsonEncode(status))!;
  }

  NikoCameraCatalog get _cameraCatalog {
    final catalog = cameraCatalog(formats: [macFormat()]);
    catalog['reason'] = 'camera_catalog_ready';
    (catalog['devices'] as List)[0]['name'] = 'FaceTime HD Camera';
    return NikoCameraCatalog.parse(jsonEncode(catalog))!;
  }

  static Future<String> _queued(String request) async =>
      jsonEncode({'ok': true, 'status': 'queued'});

  @override
  Widget build(BuildContext context) {
    final (action, panel) = switch (widget.panel) {
      NikoTestCmPanel.terminal => (
          nikoText('终端访问', 'Terminal access'),
          NikoTerminalCapabilityPanel(
              status: _terminal, sendDecision: _queued, sendRevoke: _queued)
        ),
      NikoTestCmPanel.camera => (
          nikoText('摄像头访问', 'Camera access'),
          NikoCameraCapabilityPanel(
              status: _cameraStatus,
              catalog: widget.running ? null : _cameraCatalog,
              canRequestSystemPermission: true,
              refreshStatus: () async => true,
              sendCommand: _queued)
        ),
      NikoTestCmPanel.voice => (
          nikoText('画面与键鼠控制', 'Screen and input control'),
          NikoCmVoicePanel(model: _voice!)
        ),
      NikoTestCmPanel.tunnel => (
          '${nikoText('隧道目标', 'Tunnel target')}: '
              '${_tunnel!.status.target.label}',
          NikoCmTunnelPanel(model: _tunnel!)
        ),
      NikoTestCmPanel.voiceStart => (
          nikoText('画面与键鼠控制', 'Screen and input control'),
          NikoCmVoiceStart(
              context: NikoCmVoiceStartContext.parse({
                'schema': 1,
                'connection_id': 12,
                'namespace': 'a' * 64,
                'peer_id': '418223905',
                'connection_nonce': 'b' * 32
              })!,
              availability: (_) async => jsonEncode({
                    'supported': true,
                    'requests_allowed': true,
                    'peer_supported': true,
                    'peer_requests_allowed': true,
                    'reason': ''
                  }),
              prepare: _queued)
        ),
    };
    return NikoCmSessionLayout(
        header: NikoCmRequestHeader(
            requester: 'Studio Mac',
            peerId: '418 223 905',
            action: action,
            status: nikoText('已连接', 'Connected'),
            duration: const Text('00:03:12')),
        controls: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
          panel,
          // The tunnel card ends with its own leave button; the others end
          // with Disconnect, as the card's controls do.
          if (widget.panel == NikoTestCmPanel.tunnel)
            Row(children: [
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: NikoCmActionButton(
                          danger: true,
                          label: nikoText('退出连接', 'Leave connection'),
                          icon: const Icon(Icons.link_off_rounded, size: 14),
                          onPressed: () {}))),
            ])
          else
            Row(children: [
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: NikoCmActionButton(
                          danger: true,
                          label: nikoText('断开连接', 'Disconnect'),
                          icon: const Icon(Icons.link_off_rounded, size: 14),
                          onPressed: () {}))),
            ]),
        ]));
  }
}
