package com.carriez.flutter_hbb

import android.app.Activity

internal object VoiceFlavorPolicy {
    const val legacyAudioAllowed = true
    @Suppress("UNUSED_PARAMETER") fun initialize(activity: Activity) { }
    @Suppress("UNUSED_PARAMETER") fun visible(activity: Activity, active: Boolean) { }
    @Suppress("UNUSED_PARAMETER") fun destroyed(activity: Activity) { }
    @Suppress("UNUSED_PARAMETER") fun permissionResult(activity: Activity, code: Int, permissions: Array<out String>, results: IntArray): Boolean = false
}
