import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'theme.dart';
import 'ui.dart';

enum PublishedVersionRelation { newerRelease, sameVersion, localAhead, unknown }

/// Installed package metadata and native protocol version are separate facts.
class ProductBuildInfo {
  static const sourceReadTimeout = Duration(seconds: 2);
  static const loadTimeout = Duration(seconds: 3);
  final String? version;
  final String? buildNumber;
  final String? nativeVersion;
  const ProductBuildInfo({this.version, this.buildNumber, this.nativeVersion});
  static const unknown = ProductBuildInfo();

  static String? _version(String? value) {
    final text = value?.trim() ?? '';
    return text.length <= 64 &&
            RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$').hasMatch(text)
        ? text
        : null;
  }

  static Future<ProductBuildInfo> read({
    Future<PackageInfo> Function()? packageLoader,
    Future<String> Function()? nativeVersionLoader,
    Duration timeout = sourceReadTimeout,
  }) async {
    Future<(String?, String?)> packageInfo() async {
      try {
        final package = await Future<PackageInfo>.sync(
                packageLoader ?? PackageInfo.fromPlatform)
            .timeout(timeout);
        final build = package.buildNumber.trim();
        return (
          _version(package.version),
          RegExp(r'^[0-9]{1,20}$').hasMatch(build) ? build : null
        );
      } catch (_) {
        // A timeout does not discard a separately confirmed native version.
        return (null, null);
      }
    }

    Future<String?> nativeInfo() async {
      final loader = nativeVersionLoader;
      if (loader == null) return null;
      try {
        return _version(await Future<String>.sync(loader).timeout(timeout));
      } catch (_) {
        return null;
      }
    }

    // Start both reads before awaiting either; each has its own deadline.
    final packageFuture = packageInfo();
    final nativeFuture = nativeInfo();
    final package = await packageFuture;
    return ProductBuildInfo(
        version: package.$1,
        buildNumber: package.$2,
        nativeVersion: await nativeFuture);
  }

  bool get hasUnknown =>
      version == null || buildNumber == null || nativeVersion == null;

  String get fullVersion {
    final value = version ?? nikoText('未知', 'Unknown');
    final build = buildNumber;
    return build == null
        ? '$value (${nikoText('构建号未知', 'build unknown')})'
        : '$value+$build';
  }

  // Build 9 used the old preview numbering scheme. This is a manual channel
  // transition, so keep numeric ordering (relationTo) unchanged.
  bool canMigrateLegacyPreviewTo(String releaseTag) =>
      version == '1.1.0' && buildNumber == '9' && releaseTag == 'v1.0.7';

  /// Release tags do not identify an installed build number or its provenance.
  PublishedVersionRelation relationTo(String releaseTag) {
    List<int>? stable(String? value) {
      final text = value?.replaceFirst(RegExp(r'^[vV]'), '') ?? '';
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(text)) return null;
      return text.split('.').map(int.tryParse).whereType<int>().toList();
    }

    final local = stable(version);
    final release = stable(releaseTag);
    if (local?.length != 3 || release?.length != 3) {
      return PublishedVersionRelation.unknown;
    }
    for (var i = 0; i < 3; i++) {
      if (local![i] < release![i]) return PublishedVersionRelation.newerRelease;
      if (local[i] > release[i]) return PublishedVersionRelation.localAhead;
    }
    return PublishedVersionRelation.sameVersion;
  }

  String updateStatus(String releaseTag) {
    final heading = nikoText('当前本机版本：$fullVersion；公开最新：$releaseTag。',
        'Installed: $fullVersion; latest published: $releaseTag.');
    final status = switch (relationTo(releaseTag)) {
      PublishedVersionRelation.localAhead => nikoText(
          '本机版本号高于公开版本，不代表本机构建已公开发布。',
          'The installed version is ahead of the published version; this does not establish that this build is published.'),
      PublishedVersionRelation.sameVersion => nikoText(
          '没有更高版本号的公开版本；版本号相同不能确认构建号或发布状态。',
          'No higher published version. A matching version does not confirm the build number or publication status.'),
      PublishedVersionRelation.newerRelease =>
        nikoText('有更高版本号的公开版本。', 'A higher published version is available.'),
      PublishedVersionRelation.unknown => nikoText('版本信息未确认，无法判断是否需要更新。',
          'Version information is unconfirmed; update availability is unknown.'),
    };
    return '$heading\n$status';
  }
}

class NikoProductInfoRows extends StatelessWidget {
  final ProductBuildInfo info;
  final String? buildDate;
  const NikoProductInfoRows({super.key, required this.info, this.buildDate});

  @override
  Widget build(BuildContext context) {
    final muted =
        nikoIsLight(context) ? NikoPalette.lightMuted : NikoPalette.darkMuted;
    Widget row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: muted, fontSize: 12)),
          SelectableText(value,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      row(nikoText('产品版本 / 构建号', 'Product version / build'),
          'NikoDesk ${info.fullVersion}'),
      row(nikoText('上游内核 / 协议版本', 'Upstream core / protocol version'),
          'RustDesk ${info.nativeVersion ?? nikoText('未知', 'Unknown')}'),
      if (buildDate?.isNotEmpty == true)
        row(nikoText('原生构建日期', 'Native build date'), buildDate!),
      row(nikoText('许可', 'License'),
          'AGPL-3.0 · RustDesk · Copyright Purslane Tech Pte. Ltd.'),
      const SizedBox(height: 8),
      Text(
          nikoText('本机包版本不代表已公开发布或完成真实会话验收。',
              'Installed package metadata does not establish publication or real-session acceptance.'),
          style: TextStyle(color: muted, fontSize: 12)),
    ]);
  }
}

/// Shared desktop/Android about card, with explicit injection for UI tests.
class NikoProductAbout extends StatefulWidget {
  final Future<ProductBuildInfo> Function() loadInfo;
  final Duration timeout;
  const NikoProductAbout(
      {super.key,
      required this.loadInfo,
      this.timeout = ProductBuildInfo.loadTimeout});

  @override
  State<NikoProductAbout> createState() => _NikoProductAboutState();
}

class _NikoProductAboutState extends State<NikoProductAbout> {
  late var _info = _read();

  Future<ProductBuildInfo> _read() async {
    try {
      return await Future<ProductBuildInfo>.sync(widget.loadInfo)
          .timeout(widget.timeout);
    } catch (_) {
      return ProductBuildInfo.unknown;
    }
  }

  void _retry() {
    final info = _read();
    setState(() {
      _info = info;
    });
  }

  @override
  Widget build(BuildContext context) => NikoGlassCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(nikoText('关于 NikoDesk', 'About NikoDesk'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        FutureBuilder<ProductBuildInfo>(
            future: _info,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Semantics(
                    liveRegion: true,
                    child: Text(
                        nikoText('正在读取版本信息…', 'Reading version information…')));
              }
              final info = snapshot.data ?? ProductBuildInfo.unknown;
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NikoProductInfoRows(info: info),
                    if (info.hasUnknown)
                      TextButton(
                          onPressed: _retry,
                          child:
                              Text(nikoText('重试读取版本', 'Retry version read'))),
                  ]);
            }),
      ]));
}
