import 'package:flutter_hbb/models/platform_model.dart';

/// This API only queues a typed local command. Native events confirm resources.
class NativeNikoCameraTransport {
  const NativeNikoCameraTransport();
  Future<String> send(String json) =>
      Future<String>.sync(() => bind.cmNikodeskCameraCommand(json: json));
}
