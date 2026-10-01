package io.nikodesk.android.voice

// Pure identity/ACK state used by the actual framework bridge. A submitted
// request cannot become empty merely because stopSelf/startForeground returned.
internal class ForegroundLease {
    private var key: CallKey? = null
    private var dispatched = false
    private var submitted = false
    private var attached = false
    private var finishing = false
    @Synchronized fun request(value: CallKey): Boolean {
        if (key != null) { requireVoice(key == value, VoiceCode.BUSY); return false }
        key = value; return true
    }
    @Synchronized fun matches(value: CallKey) = key == value
    @Synchronized fun dispatch(value: CallKey): Boolean {
        if (key != value || dispatched) return false
        dispatched = true; return true
    }
    @Synchronized fun submit(value: CallKey) { requireVoice(key == value && dispatched && !submitted, VoiceCode.STALE); submitted = true }
    @Synchronized fun undispatched(value: CallKey) { if (key == value && !submitted && !attached) { key = null; dispatched = false; finishing = false } }
    @Synchronized fun attach(value: CallKey): Boolean {
        if (key != value || !submitted || attached) return false
        attached = true; return true
    }
    @Synchronized fun clearIfUnsubmitted(value: CallKey): Boolean {
        if (key == null) return true
        requireVoice(key == value, VoiceCode.BUSY)
        if (submitted) return false
        key = null; dispatched = false; return true
    }
    @Synchronized fun finish(value: CallKey): Boolean {
        if (key != value || !attached || finishing) return false
        finishing = true; return true
    }
    @Synchronized fun retryFinish(value: CallKey) { if (key == value) finishing = false }
    @Synchronized fun destroy(value: CallKey): Boolean {
        if (key != value || !attached) return false
        key = null; dispatched = false; submitted = false; attached = false; finishing = false; return true
    }
}
