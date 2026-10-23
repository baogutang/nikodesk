import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/platform_model.dart';
import '../models/model.dart' show FFI;
import 'nightline.dart';
import 'privacy_screen.dart';
import 'privacy_style_events.dart';
import 'privacy_style_image.dart';
import 'privacy_style_model.dart';
import 'privacy_wallpaper.dart';
import 'settings_kit.dart';
import 'ui.dart';

Future<NikoPrivacyStyle> nikoReadPrivacyStyle(FFI ffi) async =>
    NikoPrivacyStyle.read(await bind.sessionGetPeerOption(
        sessionId: ffi.sessionId, name: nikoPrivacyStyleOption)) ??
    const NikoPrivacyStyle();

bool nikoPrivacyStyleAllowed(FFI ffi) =>
    !ffi.closed &&
    ffi.ffiModel.pi.features.privacyStyle &&
    !ffi.ffiModel.viewOnly &&
    ffi.ffiModel.keyboard &&
    ffi.ffiModel.permissions['keyboard'] != false &&
    ffi.ffiModel.permissions['privacy_mode'] != false;

Future<void> nikoApplyPrivacyStyle(FFI ffi, NikoPrivacyStyle style) async {
  if (!nikoPrivacyStyleAllowed(ffi) || !style.valid) {
    throw const NikoPrivacyStyleError('privacy_permission_required');
  }
  final owner = ffi.sessionId, id = NikoPrivacyStyleReplies.nextId();
  final reply = NikoPrivacyStyleReplies.wait(owner, id);
  // Install an error listener before the native call: a fast remote reply can
  // otherwise complete the future before this caller reaches its await.
  final observed =
      reply.then<Object?>((_) => null, onError: (Object error) => error);
  try {
    final result = jsonDecode(await bind.sessionPrivacyStyle(
        sessionId: owner,
        json: jsonEncode(style.command(id)))) as Map<String, dynamic>;
    if (result['ok'] != true) {
      NikoPrivacyStyleReplies.reject(
          owner, id, result['error'] as String? ?? 'unconfirmed');
    }
  } catch (_) {
    NikoPrivacyStyleReplies.reject(owner, id, 'session_closed');
  }
  final error = await observed;
  if (error != null) throw error;
  if (ffi.closed || ffi.sessionId != owner) {
    throw const NikoPrivacyStyleError('session_closed');
  }
  await bind.sessionPeerOption(
      sessionId: owner, name: nikoPrivacyStyleOption, value: style.saved());
}

String nikoPrivacyStyleError(Object error) {
  final reason = error is NikoPrivacyStyleError ? error.reason : '';
  return switch (reason) {
    'close_legacy_privacy_first' => nikoText('请先关闭当前黑屏，再应用样式。',
        'Turn off the current black screen before applying a style.'),
    'image_size_limit' =>
      nikoText('图片过大，请换一张较小的图片。', 'Choose a smaller image.'),
    'image_dimensions_limit' => nikoText('图片最长边需在 4096 像素以内，总像素不超过 800 万。',
        'Use an image within 4096 pixels per edge and 8 megapixels.'),
    'invalid_image' ||
    'unsupported_image_format' =>
      nikoText('请选择 PNG、JPG 或 WebP 图片。', 'Choose a PNG, JPG or WebP image.'),
    'privacy_permission_required' || 'input_permission_required' => nikoText(
        '需要被控端允许隐私屏和键鼠控制。',
        'Remote privacy and input permission are required.'),
    'style_unsupported' => nikoText('被控端暂不支持样式，请检查版本和系统权限。',
        'Check the remote version and system permissions for wallpaper support.'),
    'excluded_capture_content_timeout' ||
    'excluded_capture_start_timeout' ||
    'excluded_capture_not_ready' =>
      nikoText('被控端屏幕采集尚未就绪。如果电脑上有屏幕录制提示，请先确认，再重试。',
          'Remote screen capture is not ready. Confirm any screen-recording prompt on the computer, then retry.'),
    'excluded_capture_content_failed' ||
    'excluded_capture_helper_unavailable' ||
    'excluded_capture_output_failed' ||
    'excluded_capture_start_failed' =>
      nikoText('被控端未能启动隐私屏采集，请检查电脑的屏幕录制权限后重试。',
          'Remote privacy capture could not start. Check screen-recording permission on the computer, then retry.'),
    'confirmation_timeout' => nikoText('未收到应用确认，请查看隐私屏状态后重试。',
        'No confirmation received. Check privacy screen status before retrying.'),
    _ => nikoText('样式未确认应用，请检查会话后重试。',
        'The style was not confirmed. Check the session and retry.'),
  };
}

class NikoPrivacyStylePanel extends StatefulWidget {
  final FFI ffi;
  const NikoPrivacyStylePanel({super.key, required this.ffi});
  @override
  State<NikoPrivacyStylePanel> createState() => _PanelState();
}

class _PanelState extends State<NikoPrivacyStylePanel> {
  NikoPrivacyStyle? _initial;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final style = await nikoReadPrivacyStyle(widget.ffi)
        .catchError((_) => const NikoPrivacyStyle());
    if (mounted) setState(() => _initial = style);
  }

  @override
  Widget build(BuildContext context) => _initial == null
      ? const SizedBox(height: 40, child: Center(child: NlSpinner(size: 18)))
      : NikoPrivacyStyleEditor(
          initial: _initial!,
          allowed: nikoPrivacyStyleAllowed(widget.ffi),
          active:
              (nikoPrivacyScreenActive(widget.ffi.id)?.value ?? '').isNotEmpty,
          mac: widget.ffi.ffiModel.pi.platform == 'Mac OS',
          passwordExit: nikoPrivacyPasswordExit(widget.ffi),
          onApply: (style) => nikoApplyPrivacyStyle(widget.ffi, style));
}

class NikoPrivacyStyleEditor extends StatefulWidget {
  final NikoPrivacyStyle initial;
  final bool allowed, active, mac;
  final bool passwordExit;
  final Future<void> Function(NikoPrivacyStyle) onApply;
  const NikoPrivacyStyleEditor(
      {super.key,
      this.initial = const NikoPrivacyStyle(),
      required this.allowed,
      required this.active,
      this.mac = true,
      this.passwordExit = true,
      required this.onApply});
  @override
  State<NikoPrivacyStyleEditor> createState() => _EditorState();
}

class _EditorState extends State<NikoPrivacyStyleEditor> {
  late NikoPrivacyStyle _style;
  bool _busy = false;
  String? _feedback;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _style = widget.initial;
  }

  String _name(NikoPrivacyPreset preset) => switch (preset) {
        NikoPrivacyPreset.nightline => nikoText('夜航', 'Nightline'),
        NikoPrivacyPreset.deepfield => nikoText('深空', 'Deep field'),
        NikoPrivacyPreset.aurora => nikoText('极光', 'Aurora'),
        NikoPrivacyPreset.graphite => nikoText('石墨', 'Graphite'),
        NikoPrivacyPreset.custom => nikoText('自定义', 'Custom'),
      };
  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final selected = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
          withData: false,
          withReadStream: true);
      if (selected == null) return;
      final file = selected.files.single;
      if (file.size <= 0 || file.size > 12 * 1024 * 1024) {
        throw const NikoPrivacyStyleError('image_size_limit');
      }
      Uint8List bytes;
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else {
        final builder = BytesBuilder(copy: false), stream = file.readStream;
        if (stream == null) throw const NikoPrivacyStyleError('invalid_image');
        await for (final chunk in stream) {
          if (builder.length + chunk.length > 12 * 1024 * 1024) {
            throw const NikoPrivacyStyleError('image_size_limit');
          }
          builder.add(chunk);
        }
        bytes = builder.takeBytes();
      }
      final normalized = await nikoNormalizePrivacyImage(bytes);
      if (mounted) {
        setState(() => _style = _style.copyWith(
            preset: NikoPrivacyPreset.custom,
            effect: NikoPrivacyEffect.none,
            image: normalized));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _feedback = nikoPrivacyStyleError(error);
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await widget.onApply(_style);
      if (mounted) {
        setState(() {
          _feedback = nikoText('已应用', 'Applied');
          _failed = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _feedback = nikoPrivacyStyleError(error);
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A setting of the style, switched by a tap anywhere on its line.
  Widget _toggle(String label, bool value, void Function(bool) change,
      {Key? key}) {
    final nl = NlColors.of(context);
    void flip() => setState(() => change(!value));
    return NlPressable(
        key: key,
        onTap: _busy ? null : flip,
        pressScale: 1,
        builder: (context, states) => ConstrainedBox(
            constraints: BoxConstraints(minHeight: _rowHeight),
            child: Row(children: [
              Expanded(
                  child: Text(label,
                      style: NlType.text(NlType.s3, color: nl.fg))),
              const SizedBox(width: NlSpace.s3),
              NlSwitch(value: value, onChanged: _busy ? null : (_) => flip()),
            ])));
  }

  /// Switch and slider lines share one height, so the list keeps an even
  /// rhythm; a slider would otherwise take its taller hover halo's.
  double get _rowHeight => NlLayout.touch(context) ? 48 : 40;

  Widget _slider(String label, int value, double min, double max,
      void Function(int) change) {
    final nl = NlColors.of(context);
    return Row(children: [
      SizedBox(
          width: MediaQuery.textScalerOf(context).scale(72),
          child: Text(label, style: NlType.text(NlType.s3, color: nl.fg))),
      Expanded(
          child: SizedBox(
              height: _rowHeight,
              child: Slider(
              value: value.toDouble(),
              min: min,
              max: max,
              onChanged: _busy
                  ? null
                  : (next) => setState(() => change(next.round()))))),
    ]);
  }

  /// Accent corner brackets that frame the live preview.
  Widget _framed(Widget preview) {
    Widget corner(Alignment at) => Align(
        alignment: at,
        child: Padding(
            padding: const EdgeInsets.all(NlSpace.s2),
            child: SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(painter: _Bracket(at)))));
    return Stack(children: [
      preview,
      for (final at in const [
        Alignment.topLeft,
        Alignment.topRight,
        Alignment.bottomLeft,
        Alignment.bottomRight
      ])
        Positioned.fill(child: IgnorePointer(child: corner(at))),
    ]);
  }

  Widget _preset(NikoPrivacyPreset preset, double width) {
    final nl = NlColors.of(context);
    final selected = _style.preset == preset;
    return SizedBox(
        width: width,
        child: NlPressable(
            key: ValueKey('privacy-preset-${preset.name}'),
            selected: selected,
            pressScale: .98,
            onTap: _busy
                ? null
                : () => setState(() {
                      _feedback = null;
                      _style = _style.copyWith(
                          preset: preset,
                          effect: NikoPrivacyStyle.effectFor(preset));
                    }),
            builder: (context, states) => AnimatedContainer(
                duration: NlMotion.of(context, NlMotion.fast),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                    // The glow is a filled shadow; an opaque tile keeps it
                    // outside the frame.
                    color: nl.surface,
                    borderRadius: BorderRadius.circular(NlRadius.r3),
                    border: Border.all(
                        color: selected
                            ? nl.accent
                            : states.contains(WidgetState.hovered)
                                ? nl.line2
                                : nl.line,
                        width: selected ? 2 : 1),
                    boxShadow: selected
                        ? nl.glow
                        : states.contains(WidgetState.focused)
                            ? nl.focusRing
                            : null),
                child: Column(children: [
                  ClipRRect(
                      borderRadius: BorderRadius.circular(NlRadius.r2),
                      child: AspectRatio(
                          aspectRatio: 1.6,
                          child: NikoPrivacyWallpaper(
                              animate: false,
                              passwordExit: false,
                              style: _style.copyWith(
                                  preset: preset,
                                  effect: NikoPrivacyStyle.effectFor(preset),
                                  hint: false,
                                  clock: false)))),
                  Padding(
                      padding: const EdgeInsets.all(NlSpace.s2 - 2),
                      child: Text(_name(preset),
                          style: NlType.text(NlType.s2,
                              weight:
                                  selected ? FontWeight.w600 : FontWeight.w500,
                              color: selected ? nl.accentText : nl.fg2))),
                ]))));
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: NlSpace.s2),
      // Small swatches in one row where they fit; the preview below shows
      // the chosen one large.
      LayoutBuilder(builder: (context, bounds) {
        const gap = NlSpace.s2;
        final room =
            bounds.maxWidth / MediaQuery.textScalerOf(context).scale(1);
        final columns = room >= 460 ? 5 : (room >= 300 ? 3 : 2);
        final width =
            ((bounds.maxWidth - gap * (columns - 1)) / columns).floorToDouble();
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final preset in NikoPrivacyPreset.values) _preset(preset, width),
        ]);
      }),
      const SizedBox(height: NlSpace.s3),
      ClipRRect(
          borderRadius: BorderRadius.circular(NlRadius.r3),
          child: AspectRatio(
              aspectRatio: 1.6,
              child: _framed(NikoPrivacyWallpaper(
                  key: const Key('privacy-motion-preview'),
                  style: _style,
                  passwordExit: widget.passwordExit,
                  mac: widget.mac)))),
      if (_style.preset == NikoPrivacyPreset.custom) ...[
        const SizedBox(height: NlSpace.s2),
        Align(
            alignment: Alignment.centerLeft,
            child: NlButton.ghost(
                key: const Key('privacy-custom-image'),
                small: true,
                icon: NlIcons.image,
                label: nikoText('选择图片', 'Choose image'),
                onPressed: _busy ? null : _pick)),
      ],
      const SizedBox(height: NlSpace.s2),
      _toggle(nikoText('动效', 'Animate'), _style.motion,
          (value) => _style = _style.copyWith(motion: value)),
      if (_style.preset != NikoPrivacyPreset.custom)
        _slider(nikoText('光感', 'Glow'), _style.intensity, 50, 200,
            (value) => _style = _style.copyWith(intensity: value)),
      _slider(nikoText('亮度', 'Brightness'), _style.brightness, 40, 100,
          (value) => _style = _style.copyWith(brightness: value)),
      if (!widget.passwordExit)
        _toggle(nikoText('恢复提示', 'Restore hint'), _style.hint,
            (value) => _style = _style.copyWith(hint: value)),
      _toggle(nikoText('时钟', 'Clock'), _style.clock,
          (value) => _style = _style.copyWith(clock: value)),
      const SizedBox(height: NlSpace.s3),
      Align(
          alignment: Alignment.centerRight,
          child: NlButton(
              key: const Key('privacy-apply-style'),
              loading: _busy,
              label: _busy
                  ? nikoText('应用中…', 'Applying…')
                  : widget.active
                      ? nikoText('应用', 'Apply')
                      : nikoText('应用并开启', 'Apply and turn on'),
              onPressed:
                  _busy || !widget.allowed || !_style.valid ? null : _apply)),
      if (_feedback != null)
        Padding(
            padding: const EdgeInsets.only(top: NlSpace.s3),
            child: NikoSettingNote(_feedback!,
                tone: _failed ? NlTone.danger : NlTone.ok)),
      const SizedBox(height: NlSpace.s2),
    ]);
  }
}

/// One accent corner of the preview frame, drawn at [corner].
class _Bracket extends CustomPainter {
  final Alignment corner;
  const _Bracket(this.corner);

  @override
  void paint(Canvas canvas, Size size) {
    final x = corner.x < 0 ? 0.0 : size.width;
    final y = corner.y < 0 ? 0.0 : size.height;
    final paint = Paint()
      ..color = NlColors.dark.accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    canvas.drawPath(
        Path()
          ..moveTo(size.width - x, y)
          ..lineTo(x, y)
          ..lineTo(x, size.height - y),
        paint);
  }

  @override
  bool shouldRepaint(_Bracket old) => old.corner != corner;
}
