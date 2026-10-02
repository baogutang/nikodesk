import 'package:flutter/material.dart';

import 'server_gateway.dart';
import 'server_settings.dart';
import 'theme.dart';
import 'ui.dart';

class NikoFirstServerSetup extends StatefulWidget {
  final ServerGateway gateway;
  final Widget child;
  final VoidCallback onSaved;
  final Future<void> Function() onLanguageChanged;

  const NikoFirstServerSetup({
    super.key,
    required this.gateway,
    required this.child,
    required this.onSaved,
    required this.onLanguageChanged,
  });

  @override
  State<NikoFirstServerSetup> createState() => _NikoFirstServerSetupState();
}

class _NikoFirstServerSetupState extends State<NikoFirstServerSetup> {
  late Future<ServerSnapshot> _snapshot = _read();
  bool _finished = false;

  Future<ServerSnapshot> _read() async =>
      await widget.gateway.read().timeout(const Duration(seconds: 8));

  void _defer() => setState(() => _finished = true);

  void _saved() {
    setState(() => _finished = true);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) return widget.child;
    return FutureBuilder<ServerSnapshot>(
      future: _snapshot,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.data?.config.isValid == true) {
          return widget.child;
        }
        final Widget content;
        if (snapshot.connectionState != ConnectionState.done) {
          content = const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (snapshot.hasError) {
          content = SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(nikoText('无法读取私服配置', 'Could not read server settings'),
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(nikoText('当前配置状态未知。请重试，或进入首页查看连接状态。',
                  'Configuration status is unknown. Retry or open Home to check connection status.')),
              const SizedBox(height: 24),
              Wrap(spacing: 12, runSpacing: 8, children: [
                TextButton(
                    onPressed: _defer,
                    child: Text(nikoText('进入首页', 'Open Home'))),
                FilledButton(
                    onPressed: () {
                      final snapshot = _read();
                      setState(() {
                        _snapshot = snapshot;
                      });
                    },
                    child: Text(nikoText('重试', 'Retry'))),
              ]),
            ]),
          );
        } else {
          content = PrivateServerForm(
            gateway: widget.gateway,
            initial: snapshot.data!.config,
            onSaved: _saved,
            onCancelled: _defer,
          );
        }
        final light = nikoIsLight(context);
        return DecoratedBox(
          decoration: BoxDecoration(
              gradient: light ? NikoPalette.lightCanvas : null,
              color: light ? null : NikoPalette.darkScaffold),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: const Text('NikoDesk'),
              actions: [
                TextButton(
                    onPressed: widget.onLanguageChanged,
                    child: Text(NikoLanguage.english ? '中文' : 'English')),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: NikoGlassCard(padding: EdgeInsets.zero, child: content),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
