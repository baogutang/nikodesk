// Development only: a build made with --dart-define=NIKODESK_PROBE=true opens
// the session named in its launch environment, so scripts/ipad-probe.sh can
// measure a real session with nobody at the iPad. The core's probe
// (src/nikodesk/probe.rs) does the measuring once the picture arrives.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

Future<void> nikoProbeBoot(BuildContext context) async {
  String env(String key) => bind.mainGetEnv(key: key);
  final peer = env('NIKODESK_PROBE_PEER');
  if (peer.isEmpty) return;
  final reply = jsonDecode(await bind.mainNikoSavePrivateServer(
      config: jsonEncode({
    'idServer': env('NIKODESK_PROBE_ID_SERVER'),
    'relayServer': env('NIKODESK_PROBE_RELAY_SERVER'),
    'publicKey': env('NIKODESK_PROBE_SERVER_KEY'),
  }))) as Map<String, dynamic>;
  if (reply['ok'] != true || reply['state'] != 'enabled') {
    debugPrint('NIKODESK-PROBE failed: private server not saved');
    return;
  }
  if (!context.mounted) return;
  await connect(context, peer, password: env('NIKODESK_PROBE_PASSWORD'));
}
