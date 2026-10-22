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

  /// Nightline: one chip per permission, as in the draft's visitor card. An
  /// unchecked chip is struck through so a revoked right reads as revoked.
  Widget _chips(BuildContext context) => NlPanel(
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NlMonoLabel(nikoText('此会话的权限', 'Session permissions')),
            const SizedBox(height: NlSpace.s3),
            Wrap(spacing: NlSpace.s2, runSpacing: NlSpace.s2, children: [
              for (final permission in permissions)
                NlChip(
                    key: ValueKey('cm-permission-${permission.name}'),
                    label: permission.label,
                    icon: permission.icon,
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
  const NikoCmRequestHeader({super.key, required this.requester,
    required this.peerId, required this.action, required this.status,
    this.duration, this.trailing});

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

  /// Nightline visitor card: what is asked, who asks, and the state.
  Widget _visitorCard(BuildContext context, NlColors nl) => NlPanel(
      padding: const EdgeInsets.all(NlSpace.s4),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(child: NlMonoLabel(action, tone: NlTone.accent)),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: NlSpace.s3),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: nl.surface2,
                      borderRadius: BorderRadius.circular(NlRadius.r2)),
                  child: Icon(Icons.laptop_mac_rounded,
                      size: 20, color: nl.accentText)),
              const SizedBox(width: NlSpace.s3),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        requester.isEmpty
                            ? nikoText('远程设备', 'Remote device')
                            : requester,
                        style: NlType.text(NlType.s4,
                            weight: FontWeight.w600, color: nl.fg)),
                    SelectableText(peerId,
                        style: NlType.monoText(NlType.s2, color: nl.fg2)),
                  ])),
            ]),
            const SizedBox(height: NlSpace.s3),
            Wrap(
                spacing: NlSpace.s3,
                runSpacing: NlSpace.s1,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(status, style: NlType.text(NlType.s3, color: nl.fg2)),
                  if (duration != null)
                    DefaultTextStyle.merge(
                        style: NlType.monoText(NlType.s5,
                            weight: FontWeight.w500, color: nl.fg),
                        child: duration!),
                ]),
          ]));
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
