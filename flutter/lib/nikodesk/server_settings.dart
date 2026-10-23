import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nightline.dart';
import 'nightline_settings.dart';
import 'policy.dart';
import 'server_gateway.dart';
import 'ui.dart';

Future<bool?> showNikoServerSettings(BuildContext context,
        ServerGateway gateway, PrivateServerConfig config) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: PrivateServerForm(gateway: gateway, initial: config),
      )),
    );

class PrivateServerForm extends StatefulWidget {
  final ServerGateway gateway;
  final PrivateServerConfig initial;
  final VoidCallback? onSaved;
  final VoidCallback? onCancelled;
  const PrivateServerForm(
      {super.key,
      required this.gateway,
      required this.initial,
      this.onSaved,
      this.onCancelled});
  @override
  State<PrivateServerForm> createState() => _PrivateServerFormState();
}

class _PrivateServerFormState extends State<PrivateServerForm> {
  final _form = GlobalKey<FormState>();
  late final _id = TextEditingController(text: widget.initial.idServer);
  late final _relay = TextEditingController(text: widget.initial.relayServer);
  late final _key = TextEditingController(text: widget.initial.publicKey);
  bool _saving = false;
  String? _error;

  /// Nightline shows each field's check under it; the Material form keeps
  /// them in its FormState.
  final _errors = <TextEditingController, String>{};

  @override
  void dispose() {
    _id.dispose();
    _relay.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.gateway.save(PrivateServerConfig(
          _id.text.trim(), _relay.text.trim(), _key.text.trim()));
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is PrivateServerSaveException && error.stoppedVerified
              ? nikoText('保存或启用失败，已确认连接处于暂停状态。请检查配置目录权限后重试。',
                  'Save or activation failed. Connections are confirmed paused. Check configuration permissions and retry.')
              : nikoText('保存未确认，停止状态未知。请核对连接状态并暂停客户端后重试。',
                  'Save was not confirmed; the stopped state is unknown. Check connection status and pause the client before retrying.');
        });
      }
      return;
    }
    if (!mounted) return;
    if (widget.onSaved != null) {
      widget.onSaved!();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  bool _validate() {
    final form = _form.currentState;
    if (form != null) return form.validate();
    setState(() {
      _errors.clear();
      for (final (controller, check) in [
        (_id, _idError),
        (_relay, _relayError),
        (_key, _keyError),
      ]) {
        final error = check(controller.text);
        if (error != null) _errors[controller] = error;
      }
    });
    return _errors.isEmpty;
  }

  String? _idError(String? value) => validServerEndpoint(value!.trim())
      ? null
      : nikoText('使用主机名或 IP，可带端口；不支持 URL 或公共服务。',
          'Enter a host/IP with an optional port, without a URL or public service.');

  String? _relayError(String? value) => validServerEndpoint(value!.trim())
      ? null
      : nikoText('填写有效主机名 / IP 和 1–65535 范围的端口。',
          'Use a valid host/IP and a port between 1 and 65535.');

  String? _keyError(String? value) => validServerKey(value!.trim())
      ? null
      : nikoText('需要标准 Base64 编码的 32 字节公钥（44 个字符）。',
          'Use the 32-byte public key in standard Base64 (44 characters).');

  String get _title => nikoText('连接自己的服务器', 'Connect to your server');

  String get _intro => nikoText(
      '填写你已有 NAS / OSS 服务端的配置，远端电脑需要使用相同私服。保存后启用本应用的私服配置，不会安装系统服务或授予系统权限。',
      'Use your existing NAS / OSS server settings. The remote computer needs the same server. Saving enables this app’s private-server configuration; it does not install a system service or grant permissions.');

  String get _keyNote => nikoText(
      '公钥用于核验服务器身份，不是远端设备的控制密码。配置完整不代表服务器已注册或远端在线。',
      'The public key checks server identity; it is not a remote-control password. Valid settings do not prove registration or device availability.');

  Widget _field(TextEditingController controller, String label,
          String? Function(String?) validator,
          {String? hint, bool autofocus = false}) =>
      Padding(
          padding: const EdgeInsets.only(top: 18),
          child: TextFormField(
            controller: controller,
            decoration: nikoInput(label, hint: hint),
            validator: validator,
            enabled: !_saving,
            autofocus: autofocus,
            keyboardType: TextInputType.visiblePassword,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            maxLength: controller == _key ? 44 : 260,
            textInputAction: controller == _key
                ? TextInputAction.done
                : TextInputAction.next,
            onFieldSubmitted: controller == _key ? (_) => _save() : null,
          ));

  @override
  Widget build(BuildContext context) {
    final nl = NlColors.maybeOf(context);
    return nl == null ? _material(context) : _nightline(context, nl);
  }

  Widget _material(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(_intro),
                _field(_id, nikoText('ID 服务器', 'ID server'), _idError,
                    hint: 'nas.example.net:21116', autofocus: true),
                _field(_relay, nikoText('中继服务器', 'Relay server'), _relayError,
                    hint: 'nas.example.net:21117'),
                _field(_key, nikoText('服务端公钥', 'Server public key'), _keyError),
                Text(_keyNote, style: Theme.of(context).textTheme.bodySmall),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 24),
                Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                          onPressed: _saving
                              ? null
                              : widget.onCancelled ??
                                  () => Navigator.of(context).pop(false),
                          child: Text(widget.onCancelled == null
                              ? nikoText('取消', 'Cancel')
                              : nikoText('稍后配置', 'Set up later'))),
                      FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.check, size: 18),
                          label: Text(nikoText(
                              '保存并启用私服', 'Save and enable private server'))),
                    ]),
              ],
            )),
      );

  /// Nightline: the title and what saving does, the three fields with their
  /// checks under them, and the actions at the end, the main one last.
  Widget _nightline(BuildContext context, NlColors nl) {
    Widget field(TextEditingController controller, String label,
            {String? hint, String? helper, bool autofocus = false}) =>
        Padding(
            padding: const EdgeInsets.only(top: NlSpace.s4),
            child: NlTextField(
                fieldKey: ValueKey('niko-server-${_fieldName(controller)}'),
                controller: controller,
                label: label,
                hint: hint,
                helper: helper,
                error: _errors[controller],
                enabled: !_saving,
                autofocus: autofocus,
                mono: true,
                keyboardType: TextInputType.visiblePassword,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(controller == _key ? 44 : 260)
                ],
                textInputAction: controller == _key
                    ? TextInputAction.done
                    : TextInputAction.next,
                onSubmitted: controller == _key ? (_) => _save() : null,
                onChanged: (_) {
                  if (_errors.containsKey(controller)) {
                    setState(() => _errors.remove(controller));
                  }
                }));
    return SingleChildScrollView(
        padding: const EdgeInsets.all(NlSpace.s6),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                  header: true,
                  child: Text(_title,
                      style: NlType.text(NlType.s6,
                          weight: FontWeight.w600, color: nl.fg))),
              const SizedBox(height: NlSpace.s2),
              Text(_intro,
                  style: NlType.text(NlType.s3, color: nl.fg2)
                      .copyWith(height: 20 / 13)),
              const SizedBox(height: NlSpace.s2),
              field(_id, nikoText('ID 服务器', 'ID server'),
                  hint: 'nas.example.net:21116', autofocus: true),
              field(_relay, nikoText('中继服务器', 'Relay server'),
                  hint: 'nas.example.net:21117'),
              field(_key, nikoText('服务端公钥', 'Server public key'),
                  helper: _keyNote),
              if (_error != null) ...[
                const SizedBox(height: NlSpace.s4),
                Semantics(
                    liveRegion: true,
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(NlIcons.circleAlert,
                                  size: 16, color: nl.dangerText)),
                          const SizedBox(width: NlSpace.s2),
                          Expanded(
                              child: Text(_error!,
                                  style: NlType.text(NlType.s3,
                                      color: nl.dangerText))),
                        ])),
              ],
              const SizedBox(height: NlSpace.s6),
              Wrap(
                  spacing: NlSpace.s2,
                  runSpacing: NlSpace.s2,
                  alignment: WrapAlignment.end,
                  children: [
                    NlButton.ghost(
                        onPressed: _saving
                            ? null
                            : widget.onCancelled ??
                                () => Navigator.of(context).pop(false),
                        label: widget.onCancelled == null
                            ? nikoText('取消', 'Cancel')
                            : nikoText('稍后配置', 'Set up later')),
                    NlButton(
                        onPressed: _saving ? null : _save,
                        loading: _saving,
                        icon: NlIcons.check,
                        label: nikoText('保存并启用私服', 'Save and enable private server')),
                  ]),
            ]));
  }

  String _fieldName(TextEditingController controller) => controller == _id
      ? 'id'
      : controller == _relay
          ? 'relay'
          : 'key';
}

class NikoNetworkSettings extends StatefulWidget {
  final ServerGateway? gateway;
  const NikoNetworkSettings({super.key, this.gateway});
  @override
  State<NikoNetworkSettings> createState() => _NikoNetworkSettingsState();
}

class _NikoNetworkSettingsState extends State<NikoNetworkSettings> {
  late final _gateway = widget.gateway ?? NativeServerGateway();
  late Future<ServerSnapshot> _snapshot = _read();

  Future<ServerSnapshot> _read() =>
      _gateway.read().timeout(const Duration(seconds: 8));

  void _reload() {
    final snapshot = _read();
    setState(() {
      _snapshot = snapshot;
    });
  }

  String get _summaryText => nikoText(
      'NikoDesk 仅使用你配置的 OSS ID / 中继服务器。设备连接仍需独立认证与加密；系统权限由你在系统设置中授予。',
      'NikoDesk uses your configured OSS ID / relay servers. Sessions still require authentication and encryption. Grant operating-system permissions in System Settings.');

  @override
  Widget build(BuildContext context) {
    final nightline = NlColors.maybeOf(context);
    if (nightline != null) return _nightline(context, nightline);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(nikoText('私有网络', 'Private network'),
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        Text(_summaryText),
        const SizedBox(height: 24),
        FutureBuilder<ServerSnapshot>(
            future: _snapshot,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return NikoCard(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(nikoText('无法读取配置', 'Cannot read settings')),
                      const SizedBox(height: 12),
                      Text(nikoText('现有配置状态未知，未进行更改。请重试读取。',
                          'The existing configuration is unknown and has not been changed. Retry reading it.')),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh),
                          label: Text(nikoText('重试', 'Retry'))),
                    ]));
              }
              final value = snapshot.data!;
              return NikoCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(value.config.isValid
                        ? nikoText('配置完整', 'Configuration complete')
                        : nikoText('尚未配置', 'Setup required')),
                    if (value.config.isValid &&
                        value.registrationStatus == null) ...[
                      const SizedBox(height: 12),
                      Text(nikoText('注册状态未知。配置完整不代表远端在线。',
                          'Registration status is unknown. Valid settings do not prove remote availability.')),
                    ],
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: () async {
                          final saved = await showNikoServerSettings(
                              context, _gateway, value.config);
                          if (mounted && saved == true) _reload();
                        },
                        child: Text(nikoText('配置服务器', 'Configure server'))),
                  ]));
            }),
      ]));
  }

  /// Nightline: one settings card, like the other tabs of the hosted page;
  /// the same read, retry and configure paths as above.
  Widget _nightline(BuildContext context, NlColors nl) => SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: NlSpace.s4),
      child: NikoSettingsCard(title: nikoText('私有网络', 'Private network'), children: [
        Text(_summaryText, style: NlType.text(NlType.s3, color: nl.fg2)),
        const SizedBox(height: NlSpace.s3),
        FutureBuilder<ServerSnapshot>(
            future: _snapshot,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const NlLed(NlLedState.warn),
                    const SizedBox(width: NlSpace.s2),
                    Text(nikoText('无法读取配置', 'Cannot read settings'),
                        style: NlType.text(NlType.s3, weight: FontWeight.w500, color: nl.fg)),
                  ]),
                  const SizedBox(height: NlSpace.s1),
                  Text(nikoText('现有配置状态未知，未进行更改。请重试读取。',
                      'The existing configuration is unknown and has not been changed. Retry reading it.'),
                      style: NlType.text(NlType.s3, color: nl.fg2)),
                  const SizedBox(height: NlSpace.s3),
                  NlButton.ghost(
                      onPressed: _reload,
                      icon: Icons.refresh,
                      label: nikoText('重试', 'Retry')),
                ]);
              }
              final value = snapshot.data!;
              final valid = value.config.isValid;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  NlLed(valid ? NlLedState.ok : NlLedState.warn),
                  const SizedBox(width: NlSpace.s2),
                  Text(valid
                      ? nikoText('配置完整', 'Configuration complete')
                      : nikoText('尚未配置', 'Setup required'),
                      style: NlType.text(NlType.s3, weight: FontWeight.w500, color: nl.fg)),
                ]),
                if (valid && value.registrationStatus == null) ...[
                  const SizedBox(height: NlSpace.s2),
                  Text(nikoText('注册状态未知。配置完整不代表远端在线。',
                      'Registration status is unknown. Valid settings do not prove remote availability.'),
                      style: NlType.text(NlType.s2, color: nl.fg2)),
                ],
                const SizedBox(height: NlSpace.s3),
                NlButton(
                    onPressed: () async {
                      final saved = await showNikoServerSettings(
                          context, _gateway, value.config);
                      if (mounted && saved == true) _reload();
                    },
                    label: nikoText('配置服务器', 'Configure server')),
              ]);
            }),
      ]));
}
