import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show msgBox;
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart'
    show allowDisplaySwitchInPrivacyMode;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'privacy_screen_policy.dart';
import 'privacy_style.dart';
import 'privacy_style_events.dart';
import 'session_toolbar.dart';
import 'ui.dart';

export 'privacy_screen_policy.dart';

/// The implementation the controlled side reported as running for [peerId],
/// as an observable, or null outside a session page.
RxString? nikoPrivacyScreenActive(String peerId) =>
    Get.isRegistered<RxString>(tag: PrivacyModeState.tag(peerId))
        ? PrivacyModeState.find(peerId)
        : null;
bool nikoPrivacyPasswordExit(FFI ffi) =>
    ffi.ffiModel.pi.platformAdditions['nikodesk_privacy_password_exit'] == true;

NikoPrivacyScreenStatus nikoPrivacyScreenStatusOf(FFI ffi, String active) {
  final model = ffi.ffiModel;
  final offered =
      model.pi.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl];
  return nikoPrivacyScreenStatus(
      supported: ffi.connType == ConnType.defaultConn &&
          model.pi.features.privacyMode &&
          nikoPrivacyScreenImpl(offered, null) != null,
      allowed: model.permissions['privacy_mode'] != false && model.keyboard &&
          model.permissions['keyboard'] != false,
      viewOnly: model.viewOnly,
      active: active);
}

/// Asks the controlled side to switch its privacy screen. The answer arrives
/// later as a change of [nikoPrivacyScreenActive], or as a message from the
/// controlled side saying why not.
Future<void> nikoRequestPrivacyScreen(FFI ffi, {required bool on}) async {
  final active = nikoPrivacyScreenActive(ffi.id)?.value ?? '';
  final status = nikoPrivacyScreenStatusOf(ffi, active);
  if (ffi.closed || !nikoPrivacyScreenCanToggle(status)) {
    throw StateError('Privacy screen unavailable');
  }
  if (on && ffi.ffiModel.pi.features.privacyStyle) {
    await nikoApplyPrivacyStyle(ffi, await nikoReadPrivacyStyle(ffi));
    return;
  }
  if (on == active.isNotEmpty) return;
  final session = ffi.sessionId;
  final pi = ffi.ffiModel.pi;
  final offered =
      pi.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl];
  if (offered == null) {
    // Versions from before implementations were listed take a plain toggle.
    await bind.sessionToggleOption(sessionId: session, value: 'privacy-mode');
    return;
  }
  final key = on
      ? nikoPrivacyScreenImpl(
          offered,
          await bind.sessionGetOption(
              sessionId: session, arg: 'privacy-mode-impl-key'))
      : active;
  if (key == null || key.isEmpty) {
    throw StateError('Privacy screen unavailable');
  }
  // Some Windows implementations only protect the first display.
  if (on &&
      !allowDisplaySwitchInPrivacyMode(pi, key) &&
      !(pi.currentDisplay == 0 &&
          !bind.sessionIsMultiUiSession(sessionId: session))) {
    throw const NikoPrivacyScreenNeedsFirstDisplay();
  }
  await bind.sessionTogglePrivacyMode(
      sessionId: session, implKey: key, on: on);
}

class NikoPrivacyScreenNeedsFirstDisplay implements Exception {
  const NikoPrivacyScreenNeedsFirstDisplay();
}

/// A toolbar button that shows the state at a glance and switches it with one
/// click. When switching is not possible it opens [onExplain] instead, which
/// says why.
class NikoPrivacyScreenButton extends StatelessWidget {
  final FFI ffi;
  final VoidCallback onExplain;
  const NikoPrivacyScreenButton(
      {super.key, required this.ffi, required this.onExplain});

  @override
  Widget build(BuildContext context) {
    final active = nikoPrivacyScreenActive(ffi.id);
    if (active == null) return const Offstage();
    return AnimatedBuilder(
        animation: ffi.ffiModel,
        builder: (context, _) => Obx(() => NikoPrivacyScreenButtonView(
              status: nikoPrivacyScreenStatusOf(ffi, active.value),
              onSwitch: (on) async {
                final session = ffi.sessionId;
                try {
                  await nikoRequestPrivacyScreen(ffi, on: on);
                } on NikoPrivacyStyleError catch (error) {
                  if (!ffi.closed && ffi.sessionId == session)
                    msgBox(session, 'custom-nook-nocancel-hasclose', 'info',
                        nikoPrivacyStyleError(error), '', ffi.dialogManager);
                }
              },
              onExplain: onExplain,
            )));
  }
}

class NikoPrivacyScreenButtonView extends StatelessWidget {
  final NikoPrivacyScreenStatus status;
  final Future<void> Function(bool on) onSwitch;
  final VoidCallback onExplain;
  const NikoPrivacyScreenButtonView(
      {super.key,
      required this.status,
      required this.onSwitch,
      required this.onExplain});

  @override
  Widget build(BuildContext context) {
    // Nothing to show for a remote that has no privacy screen at all.
    if (status == NikoPrivacyScreenStatus.unsupported) return const Offstage();
    final on = status == NikoPrivacyScreenStatus.on;
    final hint = switch (status) {
      NikoPrivacyScreenStatus.on => nikoText('，点击关闭', '; click to turn off'),
      NikoPrivacyScreenStatus.off => nikoText('，点击开启', '; click to turn on'),
      _ => nikoText('，点击查看原因', '; click to see why'),
    };
    return NikoToolbarButton(
      key: const Key('nikodesk-privacy-screen-button'),
      icon: Icon(
          on ? Icons.visibility_off_rounded : Icons.visibility_off_outlined),
      label: '${nikoPrivacyScreenLabel(status)}$hint',
      tone: on ? NikoToolbarTone.danger : NikoToolbarTone.action,
      selected: on,
      onPressed: () {
        if (!nikoPrivacyScreenCanToggle(status)) return onExplain();
        // A request that could not be sent is explained in the same place.
        onSwitch(!on).catchError((_) => onExplain());
      },
    );
  }
}

/// A small label over the remote picture for as long as the privacy screen
/// is on, so the state is visible even with the toolbar folded away. It takes
/// no input.
class NikoPrivacyScreenBadge extends StatelessWidget {
  final String peerId;
  const NikoPrivacyScreenBadge({super.key, required this.peerId});

  @override
  Widget build(BuildContext context) {
    final active = nikoPrivacyScreenActive(peerId);
    if (active == null) return const Offstage();
    return Obx(() => active.value.isEmpty
        ? const Offstage()
        : Positioned(
            left: 12,
            bottom: 12,
            child: IgnorePointer(
              child: Semantics(
                label: nikoPrivacyScreenLabel(NikoPrivacyScreenStatus.on),
                child: DecoratedBox(
                  key: const Key('nikodesk-privacy-screen-badge'),
                  decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.72),
                      borderRadius: BorderRadius.circular(999)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.visibility_off_rounded,
                          size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                          nikoPrivacyScreenLabel(NikoPrivacyScreenStatus.on),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              decoration: TextDecoration.none,
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
              ),
            ),
          ));
  }
}
