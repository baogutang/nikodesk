import 'package:flutter/material.dart';

import 'home_chrome.dart';
import 'nightline.dart';
import 'server_gateway.dart';
import 'server_settings.dart';
import 'theme.dart';
import 'ui.dart';

class NikoFirstServerSetup extends StatefulWidget {
  final ServerGateway gateway;
  final Widget child;
  final VoidCallback onSaved;
  final Future<void> Function() onLanguageChanged;

  /// Keeps a macOS title strip above the setup page.
  final bool macTitleBar;

  const NikoFirstServerSetup({
    super.key,
    required this.gateway,
    required this.child,
    required this.onSaved,
    required this.onLanguageChanged,
    this.macTitleBar = false,
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

  void _retry() {
    final snapshot = _read();
    setState(() {
      _snapshot = snapshot;
    });
  }

  /// Nightline: the unknown state said plainly, with the same two ways on.
  Widget _readFailed(NlColors nl) => SingleChildScrollView(
      padding: const EdgeInsets.all(NlSpace.s6),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const NlLed(NlLedState.warn),
              const SizedBox(width: NlSpace.s2),
              Expanded(
                  child: Text(
                      nikoText('无法读取私服配置', 'Could not read server settings'),
                      style: NlType.text(NlType.s5,
                          weight: FontWeight.w600, color: nl.fg))),
            ]),
            const SizedBox(height: NlSpace.s2),
            Text(
                nikoText('当前配置状态未知。请重试，或进入首页查看连接状态。',
                    'Configuration status is unknown. Retry or open Home to check connection status.'),
                style: NlType.text(NlType.s3, color: nl.fg2)),
            const SizedBox(height: NlSpace.s6),
            Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                    spacing: NlSpace.s2,
                    runSpacing: NlSpace.s2,
                    children: [
                      NlButton.ghost(
                          onPressed: _defer,
                          label: nikoText('进入首页', 'Open Home')),
                      NlButton(
                          onPressed: _retry,
                          icon: NlIcons.refreshCw,
                          label: nikoText('重试', 'Retry')),
                    ])),
          ]));

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
        final nl = NlColors.maybeOf(context);
        final Widget content;
        if (nl != null && snapshot.connectionState != ConnectionState.done) {
          content = const Padding(
            padding: EdgeInsets.all(NlSpace.s10),
            child: Center(child: NlSpinner(size: 20)),
          );
        } else if (nl != null && snapshot.hasError) {
          content = _readFailed(nl);
        } else if (snapshot.connectionState != ConnectionState.done) {
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
        // The desktop home hosts this in Nightline; mobile keeps its card.
        if (nl != null) {
          final page = ColoredBox(
              color: nl.page,
              child: SafeArea(
                  child: Center(
                      child: Padding(
                          padding: const EdgeInsets.all(NlSpace.s6),
                          child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(children: [
                                      const NlMark(size: 32),
                                      const SizedBox(width: NlSpace.s3),
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                            Text('NikoDesk',
                                                style: NlType.text(NlType.s4,
                                                    weight: FontWeight.w600,
                                                    color: nl.fg)),
                                            Text(
                                                nikoText(
                                                    '首次设置', 'First-time setup'),
                                                style: NlType.text(NlType.s2,
                                                    color: nl.fg3)),
                                          ])),
                                      NlButton.ghost(
                                          small: true,
                                          onPressed: widget.onLanguageChanged,
                                          label: NikoLanguage.english
                                              ? '中文'
                                              : 'English'),
                                    ]),
                                    const SizedBox(height: NlSpace.s5),
                                    Flexible(
                                        child: NlPanel(
                                            padding: EdgeInsets.zero,
                                            child: content)),
                                  ]))))));
          return NikoTitleStrip(enabled: widget.macTitleBar, child: page);
        }
        final light = nikoIsLight(context);
        return DecoratedBox(
          decoration: BoxDecoration(
              color: light ? NikoPalette.lightScaffold : NikoPalette.darkScaffold),
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
