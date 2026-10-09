import 'dart:async';
import 'dart:convert';

class NikoPrivacyStyleError implements Exception {
  final String reason;
  const NikoPrivacyStyleError(this.reason);
}

/// Replies are bound to the captured session ID and request. A late reply from
/// a previous session cannot confirm a new controller's selection.
class NikoPrivacyStyleReplies {
  static int _next = 1;
  static final Map<(Object, int), Completer<void>> _pending = {};
  static int nextId() {
    if (_next > 0xfffffffe) throw const NikoPrivacyStyleError('request_limit');
    return _next++;
  }

  static Future<void> wait(Object owner, int request) {
    final reply = Completer<void>();
    _pending[(owner, request)] = reply;
    return reply.future
        .timeout(const Duration(seconds: 20),
            onTimeout: () =>
                throw const NikoPrivacyStyleError('confirmation_timeout'))
        .whenComplete(() => _pending.remove((owner, request)));
  }

  static void reject(Object owner, int request, String error) {
    _pending
        .remove((owner, request))?.completeError(NikoPrivacyStyleError(error));
  }

  static void handle(Object owner, Object? payload) {
    try {
      final value = jsonDecode(payload as String) as Map<String, dynamic>;
      final id = value['request_id'];
      if (id is! int || value['applied'] is! bool || value['active'] is! bool) {
        return;
      }
      final pending = _pending.remove((owner, id));
      if (pending == null) return;
      if (value['applied'] == true && value['active'] == true) {
        pending.complete();
      } else {
        pending.completeError(NikoPrivacyStyleError(
            value['error'] is String ? value['error'] : 'unconfirmed'));
      }
    } catch (_) {/* Malformed/unsolicited replies do not confirm anything. */}
  }
}
