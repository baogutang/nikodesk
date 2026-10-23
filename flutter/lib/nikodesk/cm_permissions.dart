import 'package:flutter/material.dart';

import 'nightline.dart';
import 'theme.dart';
import 'ui.dart';

class NikoCmPermission {
  final String name;
  final String label;
  final IconData icon;
  final bool enabled;
  const NikoCmPermission(this.name, this.label, this.icon, this.enabled);
}

/// The design system's icon for a permission the connection manager names.
IconData? _permissionIcon(String name) => switch (name) {
      'keyboard' => NlIcons.keyboard,
      'clipboard' => NlIcons.clipboard,
      'audio' => NlIcons.volume2,
      'file' => NlIcons.files,
      'restart' => NlIcons.rotateCcw,
      'recording' => NlIcons.circleDot,
      'block_input' => NlIcons.lock,
      'privacy_mode' => NlIcons.eyeOff,
      _ => null,
    };

class NikoCmPermissions extends StatelessWidget {
  final List<NikoCmPermission> permissions;
  final bool canModify;
  final void Function(String, bool) onChange;
  const NikoCmPermissions({super.key, required this.permissions,
    required this.canModify, required this.onChange});

  @override
  Widget build(BuildContext context) {
    if (NlColors.maybeOf(context) != null) return _chips(context);
    return NikoCard(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(nikoText('此会话的权限', 'Session permissions'),
              style: Theme.of(context).textTheme.titleSmall)),
          for (final permission in permissions)
            CheckboxListTile(
              key: ValueKey('cm-permission-${permission.name}'),
              value: permission.enabled,
              onChanged: canModify ? (value) {
                if (value != null) onChange(permission.name, value);
              } : null,
              title: Text(permission.label),
              secondary: ExcludeSemantics(child: Icon(permission.icon)),
              controlAffinity: ListTileControlAffinity.trailing,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.standard,
            ),
        ]));
  }

  /// Design system: one chip per permission. An unchecked chip is struck
  /// through so a revoked right reads as revoked.
  Widget _chips(BuildContext context) => NlPanel(
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NlSectionLabel(nikoText('此会话的权限', 'Session permissions'),
                padding: const EdgeInsets.only(bottom: NlSpace.s3)),
            Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
              for (final permission in permissions)
                NlChip(
                    key: ValueKey('cm-permission-${permission.name}'),
                    label: permission.label,
                    icon: _permissionIcon(permission.name) ?? permission.icon,
                    selected: permission.enabled,
                    strikeWhenOff: true,
                    onChanged: canModify
                        ? (value) => onChange(permission.name, value)
                        : null),
            ]),
          ]));
}

class NikoCmRequestHeader extends StatelessWidget {
  final String requester;
  final String peerId;
  final String action;
  final String status;
  final Widget? duration;
  final Widget? trailing;

  /// The state's light in the design system: green while connected by
  /// default, off otherwise.
  final NlTone? tone;
  const NikoCmRequestHeader({super.key, required this.requester,
    required this.peerId, required this.action, required this.status,
    this.duration, this.trailing, this.tone});

  @override
  Widget build(BuildContext context) {
    final nightline = NlColors.maybeOf(context);
    if (nightline != null) return _visitorCard(context, nightline);
    return NikoGlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(requester.isEmpty
                ? nikoText('远程设备', 'Remote device') : requester,
              style: Theme.of(context).textTheme.titleMedium)),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 4),
          SelectableText(peerId, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text(action, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            Text(status, style: Theme.of(context).textTheme.bodyMedium),
            if (duration != null) duration!,
          ]),
        ]));
  }

  /// Design-system visitor card: who connects, what they reach, and the
  /// state with its time.
  Widget _visitorCard(BuildContext context, NlColors nl) {
    final light = switch (tone ?? (duration != null ? NlTone.ok : NlTone.neutral)) {
      NlTone.ok => NlLedState.ok,
      NlTone.warn || NlTone.accent => NlLedState.warn,
      NlTone.danger => NlLedState.danger,
      NlTone.neutral => NlLedState.off,
    };
    return NlPanel(
        padding: const EdgeInsets.all(NlSpace.s4),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                NlIconTile(icon: NlIcons.monitor, color: nl.accent, size: 40),
                const SizedBox(width: NlSpace.s3),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Text(
                          requester.isEmpty
                              ? nikoText('远程设备', 'Remote device')
                              : requester,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NlType.text(NlType.s5,
                              weight: FontWeight.w600, color: nl.fg)),
                      SelectableText(peerId,
                          style: NlType.monoText(NlType.s2, color: nl.fg3)),
                    ])),
                if (trailing != null) trailing!,
              ]),
              const SizedBox(height: NlSpace.s4),
              // A tinted label rather than a badge: a tunnel's target can be
              // long, and large text wraps it.
              DecoratedBox(
                  decoration: BoxDecoration(
                      color: nl.accentSoft,
                      borderRadius: BorderRadius.circular(NlRadius.r1)),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: NlSpace.s2, vertical: 3),
                      child: Text(action,
                          style: NlType.text(NlType.s2,
                              weight: FontWeight.w500, color: nl.accentText)))),
              const SizedBox(height: NlSpace.s3),
              Wrap(
                  spacing: NlSpace.s3,
                  runSpacing: NlSpace.s1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      NlLed(light),
                      const SizedBox(width: NlSpace.s2),
                      Flexible(
                          child: Text(status,
                              style: NlType.text(NlType.s3, color: nl.fg2))),
                    ]),
                    if (duration != null)
                      DefaultTextStyle.merge(
                          style: NlType.monoText(NlType.s3,
                              weight: FontWeight.w500, color: nl.fg),
                          child: duration!),
                  ]),
            ]));
  }
}

class NikoCmSessionLayout extends StatelessWidget {
  final Widget header;
  final Widget? permissions;
  final Widget controls;
  const NikoCmSessionLayout({super.key, required this.header,
    this.permissions, required this.controls});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, bounds) {
    return SingleChildScrollView(
      key: const ValueKey('cm-session-scroll'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: bounds.hasBoundedHeight
            ? (bounds.maxHeight - 24).clamp(0, double.infinity).toDouble() : 0),
        child: Column(mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Column(mainAxisSize: MainAxisSize.min, children: [
              header,
              if (permissions != null) ...[
                const SizedBox(height: 12), permissions!,
              ],
            ]),
            Padding(padding: const EdgeInsets.only(top: 16), child: controls),
          ]),
      ),
    );
  });
}

class NikoCmActionButton extends StatelessWidget {
  final String label;
  final Widget? icon;
  final bool outlined;
  final bool danger;
  final VoidCallback onPressed;
  const NikoCmActionButton({super.key, required this.label,
    required this.onPressed, this.icon, this.outlined = false, this.danger = false});

  @override
  Widget build(BuildContext context) {
    if (NlColors.maybeOf(context) != null) {
      // Text only, as the stock dialogs' buttons are.
      return outlined
          ? NlButton.ghost(label: label, onPressed: onPressed, large: true, expand: true)
          : danger
              ? NlButton.danger(label: label, onPressed: onPressed, large: true, expand: true)
              : NlButton(label: label, onPressed: onPressed, large: true, expand: true);
    }
    final colors = Theme.of(context).colorScheme;
    final foreground = outlined ? colors.onSurface
        : danger ? colors.onError : colors.onPrimary;
    final style = FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      backgroundColor: outlined
          ? Colors.transparent
          : danger
              ? NlColors.maybeOf(context)?.dangerFill ?? colors.error
              : colors.primary,
      foregroundColor: foreground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NikoShapes.control)),
    );
    final child = Row(mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          ExcludeSemantics(child: ColorFiltered(
            colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn), child: icon!)),
          const SizedBox(width: 8),
        ],
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ]);
    return outlined ? OutlinedButton(onPressed: onPressed, style: style, child: child)
        : FilledButton(onPressed: onPressed, style: style, child: child);
  }
}
