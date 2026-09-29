import 'package:flutter/material.dart';

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
  const PrivateServerForm(
      {super.key, required this.gateway, required this.initial});
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

  @override
  void dispose() {
    _id.dispose();
    _relay.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.gateway.save(PrivateServerConfig(
          _id.text.trim(), _relay.text.trim(), _key.text.trim()));
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = nikoText('保存或回读失败。客户端保持停止；请检查本地配置目录是否可写，再重试。',
              'Save or read-back failed. The client stays stopped. Check local configuration permissions and retry.');
        });
      }
    }
  }

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
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(nikoText('连接自己的服务器', 'Connect to your server'),
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(nikoText(
                    '填写你已有 NAS / OSS 服务端的配置。保存后仅启用当前应用进程内的私服注册；不会安装系统服务或授予系统权限。',
                    'Use your existing NAS / OSS server settings. Saving enables private registration in this app; it does not install a system service or grant permissions.')),
                _field(
                    _id,
                    nikoText('ID 服务器', 'ID server'),
                    (v) => validServerEndpoint(v!.trim())
                        ? null
                        : nikoText('使用主机名或 IP，可带端口；不支持 URL 或公共服务。',
                            'Enter a host/IP with an optional port, without a URL or public service.'),
                    hint: 'nas.example.net:21116',
                    autofocus: true),
                _field(
                    _relay,
                    nikoText('中继服务器', 'Relay server'),
                    (v) => validServerEndpoint(v!.trim())
                        ? null
                        : nikoText('填写有效主机名 / IP 和 1–65535 范围的端口。',
                            'Use a valid host/IP and a port between 1 and 65535.'),
                    hint: 'nas.example.net:21117'),
                _field(
                    _key,
                    nikoText('服务端公钥', 'Server public key'),
                    (v) => validServerKey(v!.trim())
                        ? null
                        : nikoText('需要标准 Base64 编码的 32 字节公钥（44 个字符）。',
                            'Use the 32-byte public key in standard Base64 (44 characters).')),
                Text(
                    nikoText('公钥用于核验服务器身份，不是远端设备的控制密码。配置完整不代表服务器已注册或远端在线。',
                        'The public key checks server identity; it is not a remote-control password. Valid settings do not prove registration or device availability.'),
                    style: Theme.of(context).textTheme.bodySmall),
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
                              : () => Navigator.of(context).pop(false),
                          child: Text(nikoText('取消', 'Cancel'))),
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
}

class NikoNetworkSettings extends StatefulWidget {
  const NikoNetworkSettings({super.key});
  @override
  State<NikoNetworkSettings> createState() => _NikoNetworkSettingsState();
}

class _NikoNetworkSettingsState extends State<NikoNetworkSettings> {
  final _gateway = NativeServerGateway();
  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(24), children: [
        Text(nikoText('私有网络', 'Private network'),
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        Text(nikoText(
            'NikoDesk 仅使用你配置的 OSS ID / 中继服务器。设备连接仍需独立认证与加密；系统权限由你在系统设置中授予。',
            'NikoDesk uses your configured OSS ID / relay servers. Sessions still require authentication and encryption. Grant operating-system permissions in System Settings.')),
        const SizedBox(height: 24),
        FutureBuilder<ServerSnapshot>(
            future: _gateway.read(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text(nikoText('无法读取配置，请返回首页重试。',
                    'Cannot read settings. Return to Devices and retry.'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final value = snapshot.data!;
              return NikoCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(value.config.isValid
                        ? nikoText('配置完整', 'Configuration complete')
                        : nikoText('尚未配置', 'Setup required')),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: () async {
                          await showNikoServerSettings(
                              context, _gateway, value.config);
                          if (mounted) setState(() {});
                        },
                        child: Text(nikoText('配置服务器', 'Configure server'))),
                  ]));
            }),
      ]);
}
