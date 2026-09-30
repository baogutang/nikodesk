import '../models/model.dart';
import '../models/platform_model.dart';

/// An Android file page owns a new native session and a new path receipt ledger.
/// Global account/server models remain with the main mobile FFI.
class NikoMobileFileOwner {
  static NikoMobileFileOwner? _active;
  static bool get hasActiveSession => _active != null;

  final FFI ffi;
  final Future<void> Function(FFI) _closeFfi;
  Future<void>? _closing;

  NikoMobileFileOwner._(this.ffi, this._closeFfi);

  static NikoMobileFileOwner open({
    required FFI globalOwner,
    FFI Function(FFI)? createFfi,
    Future<void> Function(FFI)? closeFfi,
  }) {
    if (hasActiveSession) {
      throw StateError('Close the current mobile file session first');
    }
    final ffi = (createFfi ?? _newFfi)(globalOwner);
    final owner = NikoMobileFileOwner._(ffi, closeFfi ?? _closeOwnedFfi);
    _active = owner;
    return owner;
  }

  static FFI _newFfi(FFI globalOwner) => FFI(null, globalOwner: globalOwner);

  static Future<void> _closeOwnedFfi(FFI ffi) async {
    final sessionId = ffi.sessionId;
    try {
      await ffi.fileModel.close();
    } finally {
      try {
        await ffi.close();
      } finally {
        // Cleanup of options/images may fail; native teardown still targets
        // this page's immutable UUID rather than the main or next mobile FFI.
        try {
          await bind.sessionClose(sessionId: sessionId);
        } finally {
          ffi.dialogManager.dismissAll();
        }
      }
    }
  }

  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    ffi.closed = true;
    try {
      await _closeFfi(ffi);
    } finally {
      // A repeated/late dispose belongs to this page, never to its successor.
      if (identical(_active, this)) _active = null;
    }
  }
}
