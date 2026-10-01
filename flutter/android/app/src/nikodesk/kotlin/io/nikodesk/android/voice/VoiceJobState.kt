package io.nikodesk.android.voice

// Actual permission/approval jobs use this state. Completion cannot revive a
// cancelled/expired job, and a transferred proof remains bound to that job.
internal class VoiceJobState<T>(private val deadline: Long) {
    private var cancelled = false
    private var complete = false
    private var value: T? = null
    @Synchronized fun cancel() { cancelled = true; value = null }
    @Synchronized fun live(now: Long): Boolean {
        if (!VoicePolicy.approvalTime(now, deadline)) cancel()
        return !cancelled
    }
    @Synchronized fun complete(value: T, now: Long): Boolean {
        if (!live(now) || complete) return false
        this.value = value; complete = true; return true
    }
    @Synchronized fun poll(now: Long): T? {
        requireVoice(live(now), VoiceCode.CANCELLED)
        return if (complete) value else null
    }
}

internal object VoiceReadiness {
    // Activity visibility is a local-action/media permission condition, not a
    // bridge-existence check. The OS dialog itself temporarily removes focus.
    fun available(initialized: Boolean, ordinary: Boolean, sdk: Int, registeredActivity: Boolean, exactForegroundOwner: Boolean): Boolean =
        initialized && ordinary && sdk >= 36 && (registeredActivity || exactForegroundOwner)
}
