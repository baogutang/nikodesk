import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'ui.dart';

/// Windows shows the lock screen, the sign-in screen and UAC prompts on its
/// secure desktop. Only the installed NikoDesk service reaches it; a
/// portable host never elevates (src/server/portable_service.rs refuses),
/// so the controller explains instead of offering an elevation request
/// that cannot succeed.
bool nikoPortableWindows(PeerInfo pi) =>
    pi.platform == kPeerPlatformWindows && !pi.isInstalled;

/// Replaces the stock "request elevation" prompt for [type] 'on-uac',
/// 'on-foreground-elevated' and 'elevation-error'.
void showNikoSecureDesktopNotice(
    SessionID sessionId, String type, OverlayDialogManager dialogManager,
    {required bool portable}) {
  final tag = '$sessionId-nikodesk-secure-desktop';
  if (dialogManager.existing(tag)) return;
  final foreground = type == 'on-foreground-elevated';
  final title = foreground
      ? nikoText('对方的窗口以管理员身份运行', 'The window is running as administrator')
      : nikoText('要在对方电脑上确认', 'Confirm on the other computer');
  final text = foreground
      ? portable
          ? nikoText(
              '对方最前面的窗口以管理员身份运行，Windows 便携版 NikoDesk 不能操作它。请切换到别的窗口，或者在那台电脑上安装正式版 NikoDesk。',
              'The front window on the other computer runs as administrator, and portable NikoDesk for Windows cannot operate it. Switch to another window, or install NikoDesk on that computer.')
          : nikoText('对方最前面的窗口以管理员身份运行，暂时不能操作它。',
              'The front window on the other computer runs as administrator and cannot be operated for now.')
      : portable
          ? nikoText(
              '对方弹出了管理员确认窗口（UAC）。这台 Windows 用的是便携版 NikoDesk，远程看不到也点不了这个窗口。请在那台电脑前点“是”，或者在那台电脑上安装正式版 NikoDesk。',
              'The other computer is showing an administrator prompt (UAC). It runs portable NikoDesk for Windows, which cannot see or click that prompt. Answer it at that computer, or install NikoDesk there.')
          : nikoText('对方弹出了管理员确认窗口（UAC）。如果一直看不到它，请在那台电脑前处理。',
              'The other computer is showing an administrator prompt (UAC). If it does not appear here, answer it at that computer.');
  dialogManager.show(
      tag: tag,
      (setState, close, context) => CustomAlertDialog(
            title: null,
            content: msgboxContent('info', title, text),
            actions: [
              dialogButton(nikoText('知道了', 'OK'), onPressed: close),
            ],
            onSubmit: close,
            onCancel: close,
          ));
}

const _lockAcknowledged = 'nikodesk-portable-lock-acknowledged';

/// The session toggle's own name; [kOptionLockAfterSessionEnd] is the
/// user default's, which the session getter does not know.
const nikoLockAfterSessionToggle = 'lock-after-session-end';

/// Locking a portable Windows when the session ends leaves it unreachable
/// until someone signs in at it, so a session to such a computer with that
/// option on says so, until the user keeps or drops locking for it.
void nikoWarnPortableLock(FFI ffi) {
  final sessionId = ffi.sessionId;
  if (!nikoPortableWindows(ffi.ffiModel.pi)) return;
  try {
    if (!bind.sessionGetToggleOptionSync(
            sessionId: sessionId, arg: nikoLockAfterSessionToggle) ||
        bind.sessionGetPeerOptionSync(
                sessionId: sessionId, name: _lockAcknowledged) ==
            'Y') {
      return;
    }
  } catch (_) {
    return;
  }
  final tag = '$sessionId-nikodesk-portable-lock';
  if (ffi.dialogManager.existing(tag)) return;
  ffi.dialogManager.show(tag: tag, (setState, close, context) {
    void keep() {
      bind.sessionPeerOption(
          sessionId: sessionId, name: _lockAcknowledged, value: 'Y');
      close();
    }

    void drop() {
      bind.sessionToggleOption(
          sessionId: sessionId, value: nikoLockAfterSessionToggle);
      close();
    }

    return CustomAlertDialog(
      title: null,
      content: msgboxContent(
          'info',
          nikoText(
              '这台电脑锁上后无法远程解锁', 'This computer cannot be unlocked remotely'),
          nikoText(
              '结束控制后会锁定这台电脑。它用的是 Windows 便携版 NikoDesk，锁上后要有人在电脑前登录，才能再连上。在那台电脑上安装正式版 NikoDesk 就能远程解锁。',
              'It will lock when you end the session. It runs portable NikoDesk for Windows, so after locking someone must sign in at it before you can connect again. Installing NikoDesk there lets you unlock it remotely.')),
      actions: [
        dialogButton(nikoText('仍然锁定', 'Keep locking'),
            onPressed: keep, isOutline: true),
        dialogButton(nikoText('这台以后不锁', 'Stop locking this one'),
            onPressed: drop),
      ],
      onSubmit: drop,
      onCancel: close,
    );
  });
}

/// The menu label of "lock after session end" for a portable Windows host.
Widget nikoPortableLockLabel(BuildContext context, String label) {
  final style = DefaultTextStyle.of(context).style;
  return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        Text(
            nikoText('便携版锁上后无法远程解锁',
                'Portable host: cannot be unlocked remotely'),
            style: style.copyWith(
                fontSize: (style.fontSize ?? 14) - 2,
                color: style.color?.withOpacity(.7))),
      ]);
}
