import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/platform_model.dart';
import '../models/model.dart' show FFI;
import 'privacy_screen.dart';
import 'privacy_style_events.dart';
import 'privacy_style_image.dart';
import 'privacy_style_model.dart';
import 'privacy_wallpaper.dart';
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
      ? const SizedBox(
          height: 40,
          child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))))
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
  @override
  void initState() {
    super.initState();
    _style = widget.initial;
  }

  String _name(NikoPrivacyPreset preset) => switch (preset) {
        NikoPrivacyPreset.snow => nikoText('雪岭', 'Snow ridge'),
        NikoPrivacyPreset.paper => nikoText('纸光', 'Paper light'),
        NikoPrivacyPreset.rain => nikoText('像素雨夜', 'Pixel rain'),
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
            effect: _style.preset == NikoPrivacyPreset.custom
                ? _style.effect
                : NikoPrivacyEffect.none,
            image: normalized));
      }
    } catch (error) {
      if (mounted) setState(() => _feedback = nikoPrivacyStyleError(error));
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
      if (mounted) setState(() => _feedback = nikoText('已应用', 'Applied'));
    } catch (error) {
      if (mounted) setState(() => _feedback = nikoPrivacyStyleError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _toggle(String label, bool value, void Function(bool) change) =>
      SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: value,
          onChanged: _busy ? null : (value) => setState(() => change(value)));
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 12),
        Text(nikoText('样式', 'Style'),
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        LayoutBuilder(
            builder: (context, bounds) =>
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final preset in NikoPrivacyPreset.values)
                    SizedBox(
                        width: (bounds.maxWidth - 10) / 2,
                        child: InkWell(
                            key: ValueKey('privacy-preset-${preset.name}'),
                            borderRadius: BorderRadius.circular(10),
                            onTap: _busy
                                ? null
                                : () => setState(() {
                                      _feedback = null;
                                      _style = _style.copyWith(
                                          preset: preset,
                                          effect: NikoPrivacyStyle.effectFor(
                                              preset));
                                    }),
                            child: Container(
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: _style.preset == preset
                                            ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                            : Theme.of(context).dividerColor,
                                        width:
                                            _style.preset == preset ? 2 : 1)),
                                padding: const EdgeInsets.all(3),
                                child: Column(children: [
                                  ClipRRect(
                                      borderRadius: BorderRadius.circular(7),
                                      child: AspectRatio(
                                          aspectRatio: 1.6,
                                          child: NikoPrivacyWallpaper(
                                              animate: false,
                                              passwordExit: false,
                                              style: _style.copyWith(
                                                  preset: preset,
                                                  effect: NikoPrivacyStyle
                                                      .effectFor(preset),
                                                  hint: false,
                                                  clock: false)))),
                                  Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Text(_name(preset),
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium))
                                ])))),
                ])),
        const SizedBox(height: 12),
        ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
                aspectRatio: 1.6,
                child: NikoPrivacyWallpaper(
                    key: const Key('privacy-motion-preview'),
                    style: _style,
                    passwordExit: widget.passwordExit,
                    mac: widget.mac))),
        if (_style.preset == NikoPrivacyPreset.custom) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
              key: const Key('privacy-custom-image'),
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(nikoText('选择图片', 'Choose image'))),
          DropdownButtonFormField<NikoPrivacyEffect>(
              value: _style.effect,
              decoration: InputDecoration(labelText: nikoText('动效', 'Motion')),
              items: [
                for (final effect in NikoPrivacyEffect.values)
                  DropdownMenuItem(
                      value: effect,
                      child: Text(switch (effect) {
                        NikoPrivacyEffect.fog => nikoText('山雾', 'Mist'),
                        NikoPrivacyEffect.light => nikoText('光影', 'Light'),
                        NikoPrivacyEffect.rain => nikoText('雨滴', 'Rain'),
                        NikoPrivacyEffect.none => nikoText('无', 'None'),
                      }))
              ],
              onChanged: _busy
                  ? null
                  : (effect) {
                      if (effect != null) {
                        setState(
                            () => _style = _style.copyWith(effect: effect));
                      }
                    }),
        ],
        _toggle(nikoText('动效', 'Animate'), _style.motion,
            (value) => _style = _style.copyWith(motion: value)),
        if (_style.motion && _style.effect != NikoPrivacyEffect.none)
          Row(children: [
            Text(nikoText('强度', 'Intensity')),
            Expanded(
                child: Slider(
                    value: _style.intensity.toDouble(),
                    min: 50,
                    max: 200,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _style =
                            _style.copyWith(intensity: value.round()))))
          ]),
        Row(children: [
          Text(nikoText('亮度', 'Brightness')),
          Expanded(
              child: Slider(
                  value: _style.brightness.toDouble(),
                  min: 40,
                  max: 100,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() =>
                          _style = _style.copyWith(brightness: value.round()))))
        ]),
        if (!widget.passwordExit)
          _toggle(nikoText('恢复提示', 'Restore hint'), _style.hint,
              (value) => _style = _style.copyWith(hint: value)),
        _toggle(nikoText('时钟', 'Clock'), _style.clock,
            (value) => _style = _style.copyWith(clock: value)),
        const SizedBox(height: 4),
        FilledButton(
            key: const Key('privacy-apply-style'),
            onPressed:
                _busy || !widget.allowed || !_style.valid ? null : _apply,
            child: Text(_busy
                ? nikoText('应用中…', 'Applying…')
                : widget.active
                    ? nikoText('应用', 'Apply')
                    : nikoText('应用并开启', 'Apply and turn on'))),
        if (_feedback != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_feedback!,
                  style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 12),
      ]);
}
