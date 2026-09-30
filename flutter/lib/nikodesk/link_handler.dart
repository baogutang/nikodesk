import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';

import 'connect_dialog.dart';
import 'policy.dart';
import 'server_gateway.dart';
import 'ui.dart';

class NikoLinkRequest {
  final String id;
  final String mode;
  final String? password;
  final bool forceRelay;
  const NikoLinkRequest(this.id, this.mode, this.password, this.forceRelay);

  static const modes = {
    'connect',
    'play',
    'file-transfer',
    'view-camera',
    'terminal',
    'port-forward',
    'rdp',
  };

  static NikoLinkRequest? parse(
      {Uri? uri, String? uriString, List<String>? args}) {
    try {
      if (args != null && args.isNotEmpty) {
        if (args.first.startsWith('nikodesk:')) {
          uri = Uri.parse(args.first);
        } else {
          if (args.length < 2 || !args.first.startsWith('--')) return null;
          final mode = args.first.substring(2);
          if (!modes.contains(mode) || !validDeviceId(args[1])) return null;
          String? password;
          var relay = false;
          for (var i = 2; i < args.length; i++) {
            if (args[i] == '--relay') {
              relay = true;
            } else if (args[i] == '--password' && i + 1 < args.length) {
              password = args[++i];
            } else {
              return null;
            }
          }
          return NikoLinkRequest(
              normalizeDeviceId(args[1]), mode, password, relay);
        }
      }
      uri ??= uriString == null ? null : Uri.parse(uriString);
      if (uri == null ||
          uri.scheme != 'nikodesk' ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.fragment.isNotEmpty) return null;
      if (uri.authority.isEmpty && (uri.path.isEmpty || uri.path == '/') && !uri.hasQuery) {
        return const NikoLinkRequest('', 'open', null, false);
      }
      final query = uri.queryParametersAll;
      if (query.entries.any((entry) =>
          !{'password', 'relay'}.contains(entry.key) ||
          entry.value.length != 1)) return null;
      String id;
      String mode;
      if (modes.contains(uri.authority)) {
        mode = uri.authority;
        id = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
      } else if (uri.authority == 'connection' &&
          uri.path.startsWith('/new/')) {
        mode = 'connect';
        id = uri.path.substring(5);
      } else {
        mode = 'connect';
        id = uri.authority;
        if (uri.path != '' && uri.path != '/' && uri.path != '/r') return null;
      }
      if (!validDeviceId(id)) return null;
      return NikoLinkRequest(
          normalizeDeviceId(id),
          mode,
          query['password']?.single,
          query.containsKey('relay') || uri.path == '/r');
    } catch (_) {
      // Parsing failures may include the URL or credential in their exception.
      return null;
    }
  }
}

/// Cold links wait for the real home; hot links use the same handler. Only one
/// request is retained while starting, and no link text is written to logs.
class NikoLinkInbox {
  static Object? _owner;
  static Future<void> Function(NikoLinkRequest)? _handler;
  static NikoLinkRequest? _pending;
  static bool _busy = false;

  static void attach(
      Object owner, Future<void> Function(NikoLinkRequest) handler) {
    _owner = owner;
    _handler = handler;
    final pending = _pending;
    _pending = null;
    if (pending != null) receive(pending);
  }

  static void detach(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _handler = null;
  }

  static void receive(NikoLinkRequest request) async {
    if (_busy) return;
    final handler = _handler;
    if (handler == null) {
      _pending = request;
      return;
    }
    _busy = true;
    try {
      await handler(request);
    } catch (_) {
      // UI reports a generic failure without logging credential-bearing URLs.
    } finally {
      _busy = false;
    }
  }
}

Future<void> dispatchNikoLink(BuildContext context, NikoLinkRequest request,
    {ServerGateway? gateway,
    Future<void> Function(BuildContext, String, bool,
            {bool isFileTransfer, String? password})?
      onConnect}) async {
  if (request.mode == 'open') return;
  if (!validDeviceId(request.id)) {
    nikoNotice(context, nikoText('链接无效或不支持。请从设备页输入远端 ID。',
        'This link is invalid or unsupported. Enter the remote ID on Devices.'));
    return;
  }
  var password = request.password;
  if (password == null || password.isEmpty) {
    password = await nikoAskConnectPassword(context, request.id, '',
        fileTransfer: request.mode == 'file-transfer');
  }
  if (password == null || !context.mounted) return;
  await nikoDispatchConnection(context,
      id: request.id,
      password: password,
      fileTransfer: request.mode == 'file-transfer',
      forceRelay: request.forceRelay,
      gateway: gateway,
      onConnect: onConnect ??
          (ctx, id, relay, {isFileTransfer = false, password}) async {
            if (!isDesktop &&
                (request.mode == 'port-forward' || request.mode == 'rdp')) {
              nikoNotice(
                  ctx,
                  nikoText('手机暂不支持此会话类型。',
                      'This session type is not available on mobile.'));
              throw StateError('Unsupported session type');
            }
            await connect(ctx, id,
                forceRelay: relay,
                password: password,
                isFileTransfer: isFileTransfer,
                isViewCamera: request.mode == 'view-camera',
                isTerminal: request.mode == 'terminal',
                isTcpTunneling: request.mode == 'port-forward',
                isRDP: request.mode == 'rdp');
          });
}
