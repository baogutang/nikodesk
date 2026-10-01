import 'package:flutter_hbb/models/platform_model.dart';

import 'cm_tunnel.dart';

/// Native replies only acknowledge a command; Client snapshots confirm state.
class NativeNikoCmTunnelTransport {
  const NativeNikoCmTunnelTransport();
  Future<String> send(NikoTunnelCommand command) =>
      bind.cmTunnelCommand(json: command.json);
}
