import 'package:flutter_hbb/models/platform_model.dart';

import 'capability_policy.dart';

class NativeNikoCapabilityPolicyTransport
    implements NikoCapabilityPolicyTransport {
  const NativeNikoCapabilityPolicyTransport();
  @override
  Future<String> get(String namespace) =>
      bind.mainGetNikodeskCapabilityPolicy(expectedServerNamespace: namespace);
  @override
  Future<String> set(String namespace, String revision,
          NikoCapability capability, bool allowRequests) =>
      bind.mainSetNikodeskCapabilityPolicy(
          expectedServerNamespace: namespace,
          expectedRevision: revision,
          capability: capability.name,
          allowRequests: allowRequests);
}

final nativeNikoCapabilityPolicy =
    NikoCapabilityPolicy(const NativeNikoCapabilityPolicyTransport());
