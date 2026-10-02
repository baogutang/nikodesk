// Turns one "allow requests" capability switch on or off for the live host
// profile, through the production policy client and the real bridge.
import 'package:flutter_hbb/nikodesk/capability_policy.dart';

import 'native.dart';

class _BridgeTransport implements NikoCapabilityPolicyTransport {
  _BridgeTransport(this.native);
  final NikoNative native;
  @override
  Future<String> get(String namespace) => native.bind
      .mainGetNikodeskCapabilityPolicy(expectedServerNamespace: namespace);
  @override
  Future<String> set(String namespace, String revision,
          NikoCapability capability, bool allowRequests) =>
      native.bind.mainSetNikodeskCapabilityPolicy(
          expectedServerNamespace: namespace,
          expectedRevision: revision,
          capability: capability.name,
          allowRequests: allowRequests);
}

Future<void> allowRequests(
    NikoNative native, NikoCapability capability, bool allowed) async {
  final namespace = await native.configureServer();
  final policy = NikoCapabilityPolicy(_BridgeTransport(native),
      currentNamespace: () => namespace);
  final current = await policy.get(namespace);
  if (current.allowRequests[capability] == allowed) return;
  final saved =
      await policy.set(namespace, current.revision, capability, allowed);
  if (saved.conflict || saved.allowRequests[capability] != allowed) {
    throw StateError('The ${capability.name} policy was not saved');
  }
}
