import '../desktop/pages/terminal_connection_manager.dart';
import '../models/model.dart';
import 'server_scope.dart';

typedef NikoTerminalLookup = FFI? Function(String peerId,
    {String? serverNamespace});

FFI? nikoTerminalOptionOwner({
  required String peerId,
  required String? serverNamespace,
  NikoTerminalLookup? lookup,
}) {
  final namespace = NikoServerScope.validate(serverNamespace);
  if (namespace == null) return null;
  final ffi = (lookup ?? TerminalConnectionManager.getExistingConnection)(
      peerId,
      serverNamespace: namespace);
  return ffi != null &&
          !ffi.closed &&
          ffi.id == peerId &&
          ffi.serverNamespace == namespace
      ? ffi
      : null;
}
