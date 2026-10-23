import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/custom_scale_base.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/pages/remote_page.dart'
    show getResolutionMenu, getVirtualDisplayMenu;
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import 'display_options_view.dart';
import 'session_sheet.dart';
import 'session_tools.dart' show showNikoSessionTools;
import 'ui.dart';

/// Opens the display options of a phone or iPad session: the stock sheet's
/// menus, in the NikoDesk sheet. Completes when the sheet closes. The stock
/// privacy mode entry stays out, as in the desktop toolbar; the control
/// center holds the privacy screen.
Future<void> showNikoDisplayOptions(
    BuildContext context, String id, FFI ffi) async {
  if (ffi.closed || !ffi.ffiModel.pi.isSet.value) return;
  NikoLanguage.usePreference(bind.mainGetLocalOption(key: 'lang'));
  final model = ffi.ffiModel;
  final pi = model.pi;
  final privacy = PrivacyModeState.find(id);
  final switchable = pi.displays.length > 1 &&
      pi.currentDisplay != kAllDisplayValue &&
      (privacy.isEmpty || allowDisplaySwitchInPrivacyMode(pi, privacy.value));
  final viewStyles = await toolbarViewStyle(context, id, ffi);
  final qualities = await toolbarImageQuality(context, id, ffi);
  final codecs = await toolbarCodec(context, id, ffi);
  final cursors = await toolbarCursor(context, id, ffi);
  final toggles = await toolbarDisplayToggle(context, id, ffi);
  if (isMobile) {
    toggles.insert(
        0,
        TToggleMenu(
            child: Text(translate('Lock canvas')),
            value: ffi.canvasModel.locked,
            onChanged: (value) => ffi.canvasModel.setLocked(value == true)));
  }
  final resolution = getResolutionMenu(ffi, id);
  final virtualDisplay = getVirtualDisplayMenu(ffi, id);
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);
  final secure = model.secure;
  final direct = model.direct;
  if (ffi.closed) return;
  ffi.inputModel.enterOrLeave(false);
  await ffi.dialogManager.show((_, close, __) {
    // A stock dialog opens in place of this sheet.
    VoidCallback? instead(VoidCallback? open) => open == null
        ? null
        : () {
            close();
            open();
          };
    return NikoSessionSheet(
        onCancel: close,
        child: NikoDisplayOptionsPanel(
            connection: secure == null || direct == null
                ? null
                : getConnectionText(
                    secure, direct, model.cachedPeerData.streamType),
            secure: secure != false,
            displays: switchable ? pi.displays.length : 0,
            currentDisplay: pi.currentDisplay,
            onDisplay: (i) {
              openMonitorInTheSameTab(i, ffi, pi);
              ffi.dialogManager.dismissAll();
            },
            viewStyles: viewStyles,
            customScale: (_) => _NikoCustomScale(ffi: ffi),
            qualities: qualities,
            codecs: codecs,
            codecInUse: ffi.qualityMonitorModel.data.codecFormat,
            onPictureMode: instead(() => showNikoSessionTools(ffi)),
            resolution:
                display == null ? null : '${display.width}×${display.height}',
            onResolution: instead(resolution?.onPressed),
            onVirtualDisplay: instead(virtualDisplay?.onPressed),
            cursors: cursors,
            toggles: toggles,
            onDiagnostics:
                instead(() => showNikoSessionTools(ffi, diagnostics: true)),
            onClose: close));
  },
      clickMaskDismiss: true,
      backDismiss: true,
      tag: 'nikodesk-display-options');
}

class _NikoCustomScale extends StatefulWidget {
  final FFI ffi;
  const _NikoCustomScale({required this.ffi});

  @override
  State<_NikoCustomScale> createState() => _NikoCustomScaleState();
}

class _NikoCustomScaleState extends CustomScaleControls<_NikoCustomScale> {
  @override
  FFI get ffi => widget.ffi;

  @override
  ValueChanged<int>? get onScaleChanged => null;

  @override
  Widget build(BuildContext context) => NikoScaleSlider(
      percent: scaleValue,
      position: scalePos,
      divisions:
          (CustomScaleControls.maxPercent - CustomScaleControls.minPercent)
              .round(),
      onChanged: onSliderChanged,
      onStep: nudgeScale);
}
