import '../../nikodesk/window_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import '../../models/model.dart';

/// Manages terminal connections to ensure one FFI instance per peer
class TerminalConnectionManager {
  static final Map<String, FFI> _connections = {};
  static String _key(String peerId, String? namespace) =>
      const bool.fromEnvironment('NIKODESK')
          ? nikoConnectionStorageKey(peerId, namespace ?? NikoWindowScope.current)
          : peerId;

  static final Map<String, int> _connectionRefCount = {};
  
  // Track service IDs per peer
  static final Map<String, String> _serviceIds = {};

  /// Get or create an FFI instance for a peer
  static FFI getConnection({
    required String peerId,
    String? serverNamespace,
    required String? password,
    required bool? isSharedPassword,
    required bool? forceRelay,
    required String? connToken,
  }) {
    final connectionKey = _key(peerId, serverNamespace);
    final existingFfi = _connections[connectionKey];
    if (existingFfi != null && !existingFfi.closed) {
      // Increment reference count
      _connectionRefCount[connectionKey] = (_connectionRefCount[connectionKey] ?? 0) + 1;
      debugPrint('[TerminalConnectionManager] Reusing existing connection for peer $peerId. Reference count: ${_connectionRefCount[connectionKey]}');
      return existingFfi;
    }

    // Create new FFI instance for first terminal
    debugPrint('[TerminalConnectionManager] Creating new terminal connection for peer $peerId');
    final ffi = FFI(null);
    ffi.start(
      peerId,
      password: password,
      serverNamespace: serverNamespace ?? NikoWindowScope.current,
      isSharedPassword: isSharedPassword,
      forceRelay: forceRelay,
      connToken: connToken,
      isTerminal: true,
    );
    
    _connections[connectionKey] = ffi;
    _connectionRefCount[connectionKey] = 1;
    
    // Register the FFI instance with Get for dependency injection
    Get.put<FFI>(ffi, tag: 'terminal_$connectionKey');
    
    debugPrint('[TerminalConnectionManager] New connection created. Total connections: ${_connections.length}');
    return ffi;
  }

  /// Release a connection reference
  static void releaseConnection(String peerId, {String? serverNamespace}) {
    final connectionKey = _key(peerId, serverNamespace);
    final refCount = _connectionRefCount[connectionKey] ?? 0;
    debugPrint('[TerminalConnectionManager] Releasing connection for peer $peerId. Current ref count: $refCount');
    
    if (refCount <= 1) {
      // Last reference, close the connection
      final ffi = _connections[connectionKey];
      if (ffi != null) {
        debugPrint('[TerminalConnectionManager] Closing connection for peer $peerId (last reference)');
        ffi.close();
        _connections.remove(connectionKey);
        _connectionRefCount.remove(connectionKey);
        Get.delete<FFI>(tag: 'terminal_$connectionKey');
      }
    } else {
      // Decrement reference count
      _connectionRefCount[connectionKey] = refCount - 1;
      debugPrint('[TerminalConnectionManager] Connection still in use. New ref count: ${_connectionRefCount[connectionKey]}');
    }
  }

  /// Check if a connection exists for a peer
  static bool hasConnection(String peerId, {String? serverNamespace}) {
    final connectionKey = _key(peerId, serverNamespace);
    final ffi = _connections[connectionKey];
    return ffi != null && !ffi.closed;
  }
  
  /// Get existing connection without creating new one
  static FFI? getExistingConnection(String peerId, {String? serverNamespace}) {
    final connectionKey = _key(peerId, serverNamespace);
    return _connections[connectionKey];
  }

  /// Get connection count for debugging
  static int getConnectionCount() => _connections.length;
  
  /// Get terminal count for a peer
  static int getTerminalCount(String peerId, {String? serverNamespace}) {
    final connectionKey = _key(peerId, serverNamespace);
    return _connectionRefCount[connectionKey] ?? 0;
  }
  
  /// Get service ID for a peer
  static String? getServiceId(String peerId, {String? serverNamespace}) {
    final connectionKey = _key(peerId, serverNamespace);
    return _serviceIds[connectionKey];
  }
  
  /// Set service ID for a peer
  static void setServiceId(String peerId, String serviceId, {String? serverNamespace}) {
    final connectionKey = _key(peerId, serverNamespace);
    _serviceIds[connectionKey] = serviceId;
    debugPrint('[TerminalConnectionManager] Service ID for $peerId: $serviceId');
  }
}