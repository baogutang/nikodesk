/// What the controller can say and do about the controlled side's privacy
/// screen, from what the session already knows. No widgets and no session
/// calls here.
library;

import 'ui.dart';

enum NikoPrivacyScreenStatus {
  /// The controlled side has no privacy screen (or its version is too old).
  unsupported,

  /// It has one, but its owner has not allowed controllers to use it.
  notAllowed,

  /// This session only watches.
  viewOnly,
  off,
  on,
}

/// [active] is the implementation the controlled side reported as running, or
/// empty. A running privacy screen is always shown as on, whatever else has
/// changed since, so that it can still be turned off.
NikoPrivacyScreenStatus nikoPrivacyScreenStatus(
    {required bool supported,
    required bool allowed,
    required bool viewOnly,
    required String active}) {
  if (active.isNotEmpty) return NikoPrivacyScreenStatus.on;
  if (!supported) return NikoPrivacyScreenStatus.unsupported;
  if (!allowed) return NikoPrivacyScreenStatus.notAllowed;
  if (viewOnly) return NikoPrivacyScreenStatus.viewOnly;
  return NikoPrivacyScreenStatus.off;
}

/// Which implementation to ask the controlled side for.
///
/// [offered] is what it listed at login: pairs of key and description, in its
/// own order of preference. Null means it listed nothing, which only versions
/// before the list existed do; they take a plain toggle, returned here as an
/// empty key. An empty list means it has none. The one this device used last
/// is kept while it is still offered.
String? nikoPrivacyScreenImpl(Object? offered, String? remembered) {
  if (offered == null) return '';
  if (offered is! List) return null;
  final keys = <String>[
    for (final entry in offered)
      if (entry is List && entry.isNotEmpty && entry.first is String)
        entry.first as String
  ];
  if (keys.isEmpty) return null;
  return keys.contains(remembered) ? remembered : keys.first;
}

bool nikoPrivacyScreenCanToggle(NikoPrivacyScreenStatus status) =>
    status == NikoPrivacyScreenStatus.on ||
    status == NikoPrivacyScreenStatus.off;

String nikoPrivacyScreenLabel(NikoPrivacyScreenStatus status) =>
    switch (status) {
      NikoPrivacyScreenStatus.on => nikoText('隐私屏已开启', 'Privacy screen is on'),
      NikoPrivacyScreenStatus.off => nikoText('隐私屏已关闭', 'Privacy screen is off'),
      NikoPrivacyScreenStatus.notAllowed =>
        nikoText('隐私屏：被控端未允许', 'Privacy screen: not allowed by the remote'),
      NikoPrivacyScreenStatus.viewOnly =>
        nikoText('隐私屏：只读会话不可用', 'Privacy screen: unavailable in a view-only session'),
      NikoPrivacyScreenStatus.unsupported =>
        nikoText('隐私屏：被控端不支持', 'Privacy screen: not supported by the remote'),
    };

/// What each state means for the person at the controller, and what to do
/// about the ones that are not a simple switch.
String nikoPrivacyScreenDetail(
    NikoPrivacyScreenStatus status, String peerPlatform, {bool styled = false}) {
  final mac = peerPlatform == 'Mac OS';
  final black = mac && !styled;
  final exit = mac
      ? nikoText('Control + Option + Shift + Esc', 'Control + Option + Shift + Esc')
      : 'Esc';
  switch (status) {
    case NikoPrivacyScreenStatus.on:
      return nikoText(
          '被控电脑的屏幕现在${black ? '是黑的' : '被遮住'}，它本机的键盘鼠标被暂停；你这边的画面和操作不受影响。在那台电脑上按 $exit 可以恢复，断开连接也会自动恢复。',
          'The remote screen is ${black ? 'black' : 'covered'} and its own keyboard and mouse are paused; your picture and input are unaffected. Pressing $exit at that computer restores it, and so does disconnecting.');
    case NikoPrivacyScreenStatus.off:
      return nikoText(
          '被控电脑的屏幕正常显示，旁边的人能看到你的操作。开启后它的屏幕${black ? '变黑' : '被遮住'}、本机键鼠暂停。',
          'The remote screen shows normally, so anyone beside it can watch. Turning this on ${black ? 'blacks out' : 'covers'} that screen and pauses its own keyboard and mouse.');
    case NikoPrivacyScreenStatus.notAllowed:
      return nikoText(
          '需要先在被控电脑上允许：打开它的 NikoDesk「设置 → 会话安全」，开启"允许新连接使用隐私屏"，然后重新连接；或者在它的连接窗口里给本次连接打开隐私屏权限。这两步都可以通过当前的远程画面去操作。',
          'Allow it on the remote computer first: in its NikoDesk Settings → Session security, turn on "Allow privacy screen for new connections" and reconnect; or grant this connection the privacy screen permission in its connection window. Both can be done through this remote session.');
    case NikoPrivacyScreenStatus.viewOnly:
      return nikoText('当前是只读会话，不能开关隐私屏。',
          'This session is view-only and cannot switch the privacy screen.');
    case NikoPrivacyScreenStatus.unsupported:
      return nikoText('被控端的系统或版本没有隐私屏。',
          'The remote system or version has no privacy screen.');
  }
}
