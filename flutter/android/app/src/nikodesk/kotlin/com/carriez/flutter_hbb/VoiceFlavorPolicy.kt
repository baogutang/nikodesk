package com.carriez.flutter_hbb

import android.app.Activity
import io.nikodesk.android.voice.NikoVoiceBridge
import io.nikodesk.android.credentials.NikoCredentialBridge

// Isolated connection-owned audio; never publish legacy raw frames.
internal object VoiceFlavorPolicy {
    const val legacyAudioAllowed = false
    fun initialize(activity: Activity) {
        NikoVoiceBridge.initContext(activity.applicationContext)
        NikoCredentialBridge.initialize(activity.applicationContext)
    }
    fun visible(activity: Activity, active: Boolean) { NikoVoiceBridge.setLocalActivityVisible(activity, active) }
    fun destroyed(activity: Activity) { NikoVoiceBridge.onActivityDestroyed(activity) }
    fun permissionResult(activity: Activity, code: Int, permissions: Array<out String>, results: IntArray): Boolean =
        NikoVoiceBridge.onPermissionResult(activity, code, permissions, results)
}
