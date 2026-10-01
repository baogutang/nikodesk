package io.nikodesk.android.voice

internal object VoiceCode {
    const val OK = 0
    const val STARTING = 1
    const val RUNNING = 2
    const val PERMISSION = -1
    const val STALE = -2
    const val BUSY = -3
    const val UNSUPPORTED = -4
    const val DEVICE = -5
    const val CANCELLED = -6
    const val STOP_PENDING = -7
}
internal class VoiceFailure(val code: Int) : RuntimeException()
internal fun requireVoice(value: Boolean, code: Int) { if (!value) throw VoiceFailure(code) }

internal data class CallKey(val nonce: String, val epoch: Long, val lease: Long) {
    fun valid(): Boolean = nonce.length == 32 && nonce.all { it in '0'..'9' || it in 'a'..'f' } &&
        nonce.any { it != '0' } && epoch > 0 && lease > 0
}
internal enum class DeviceDirection { INPUT, OUTPUT }
internal data class DeviceIdentity(
    val id: Int, val direction: DeviceDirection, val type: Int, val address: String,
    val rates: List<Int>, val channels: List<Int>, val encodings: List<Int>
)
internal object VoicePolicy {
    const val RATE = 48_000
    const val SAMPLES = 480
    const val MAX_DEVICE_FRAMES = 4_800
    fun ordinary(uid: Int, appUid: Int, applicationUid: Boolean, isolated: Boolean): Boolean =
        uid == appUid && applicationUid && !isolated
    fun routes(approved: DeviceIdentity, actual: List<DeviceIdentity>): Boolean =
        actual.size == 1 && actual[0] == approved
    fun format(rate: Int, channels: Int, floatEncoding: Boolean, frames: Int): Boolean =
        rate == RATE && channels == 1 && floatEncoding && frames in 1..MAX_DEVICE_FRAMES
    fun validCount(count: Int, requested: Int): Boolean = requested in 1..SAMPLES && count in 0..requested
    fun approvalTime(now: Long, expires: Long): Boolean = now >= 0 && expires > 0 && now <= expires
    fun authorized(ordinary: Boolean, microphone: Boolean, visible: Boolean, exactForeground: Boolean): Boolean =
        ordinary && microphone && (visible || exactForeground)
}

// The production session uses these same ordered steps. Exceptions leave the
// failing step reachable for retry, and never produce a release acknowledgement.
internal class StopSequence(private val steps: List<() -> Unit>) {
    private var next = 0
    fun advance(): Boolean {
        while (next < steps.size) { steps[next](); next++ }
        return true
    }
    fun completed(): Boolean = next == steps.size
}
