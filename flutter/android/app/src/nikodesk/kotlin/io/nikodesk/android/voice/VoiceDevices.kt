package io.nikodesk.android.voice

import android.content.Context
import android.content.ContextParams
import android.media.AudioDeviceInfo
import android.media.AudioManager
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

internal fun newToken(): String {
    val bytes = ByteArray(16); SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
}
internal fun identity(device: AudioDeviceInfo, direction: DeviceDirection): DeviceIdentity {
    requireVoice(device.id > 0 && device.address.length <= 256, VoiceCode.UNSUPPORTED)
    requireVoice(if (direction == DeviceDirection.INPUT) device.isSource else device.isSink, VoiceCode.STALE)
    return DeviceIdentity(device.id, direction, device.type, device.address,
        device.sampleRates.sorted(), device.channelCounts.sorted(), device.encodings.sorted())
}
internal data class FrozenDevice(val token: String, val native: AudioDeviceInfo, val identity: DeviceIdentity, val label: String)
internal class DeviceRoster(val revision: Long, val devices: List<FrozenDevice>, val formatToken: String) {
    fun selected(token: String, direction: DeviceDirection): FrozenDevice =
        devices.singleOrNull { it.token == token && it.identity.direction == direction } ?: throw VoiceFailure(VoiceCode.STALE)
    fun verify(manager: AudioManager, selected: FrozenDevice) {
        val actual = manager.getDevices(AudioManager.GET_DEVICES_ALL).filter {
            it.id == selected.identity.id && if (selected.identity.direction == DeviceDirection.INPUT) it.isSource else it.isSink
        }
        requireVoice(actual.size == 1 && identity(actual[0], selected.identity.direction) == selected.identity, VoiceCode.STALE)
    }
    fun json(): String {
        val list = JSONArray()
        devices.forEach { d -> list.put(JSONObject().put("token", d.token).put("id", d.identity.id).put("direction",
            if (d.identity.direction == DeviceDirection.INPUT) "capture" else "playback").put("label", d.label)) }
        val formats = JSONArray().put(JSONObject().put("token", formatToken).put("sample_rate", VoicePolicy.RATE)
            .put("channels", 1).put("encoding", "f32").put("support", "client_format_requires_start_readback"))
        return JSONObject().put("ok", true).put("revision", revision).put("devices", list).put("formats", formats).toString()
    }
}
internal fun dedicatedAudioContext(context: Context): Context = context.createContext(ContextParams.Builder().build())
internal fun audioManager(context: Context): AudioManager = context.getSystemService(AudioManager::class.java)
    ?: throw VoiceFailure(VoiceCode.UNSUPPORTED)
internal fun enumerateRoster(context: Context, revision: Long): DeviceRoster {
    val manager = audioManager(context)
    val devices = ArrayList<FrozenDevice>()
    // getDevices reads port metadata; no recorder, track, supported-config probe,
    // route/focus request or microphone permission request occurs here.
    manager.getDevices(AudioManager.GET_DEVICES_ALL).forEach { d ->
        val label = d.productName.toString().filterNot { it.isISOControl() }.take(128)
        if (d.isSource) devices.add(FrozenDevice(newToken(), d, identity(d, DeviceDirection.INPUT), label))
        if (d.isSink) devices.add(FrozenDevice(newToken(), d, identity(d, DeviceDirection.OUTPUT), label))
    }
    requireVoice(devices.size <= 64 && devices.map { it.identity }.distinct().size == devices.size, VoiceCode.UNSUPPORTED)
    return DeviceRoster(revision, devices, newToken())
}
