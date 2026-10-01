package io.nikodesk.android.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.AudioRouting
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// One Rust VoiceOwner thread is the only PCM/start/stop caller. Android callbacks
// only close this object's gate; they never route, resume or stop another call.
class NikoVoiceSession internal constructor(internal val key: CallKey, internal val roster: DeviceRoster,
    private val captureDevice: FrozenDevice, private val playbackDevice: FrozenDevice,
    private val approvalDeadline: Long, internal val backgroundApproved: Boolean = false) {
    private val cancelled = AtomicBoolean(false)
    private val cancellationCode = AtomicInteger(VoiceCode.CANCELLED)
    private val callbacks = AtomicInteger(0)
    private var claimed = false
    private var phase = 0
    private var deadline = 0L
    private var context: Context? = null
    private var manager: AudioManager? = null
    private var pump: HandlerThread? = null
    private var handler: Handler? = null
    private var focus: AudioFocusRequest? = null
    @Volatile private var record: AudioRecord? = null
    @Volatile private var track: AudioTrack? = null
    @Volatile private var routesConfirmed = false
    private var recordReleased = false
    private var trackReleased = false
    private var recordRouting = false
    private var trackRouting = false
    private var recordCallback = false
    private var deviceCallback = false
    private var stopSequence: StopSequence? = null
    private fun callback(action: () -> Unit) {
        callbacks.incrementAndGet()
        try { if (!cancelled.get()) action() }
        catch (_: RuntimeException) { cancel() }
        finally { callbacks.decrementAndGet() }
    }
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change -> callback {
        if (change != AudioManager.AUDIOFOCUS_GAIN) cancel()
    } }
    private val deviceListener = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(devices: Array<AudioDeviceInfo>) = callback {
            if (devices.any { it.id == captureDevice.identity.id || it.id == playbackDevice.identity.id }) cancel()
        }
        override fun onAudioDevicesAdded(devices: Array<AudioDeviceInfo>) = callback {
            devices.forEach { d ->
                if (d.id == captureDevice.identity.id && d.isSource && identity(d, DeviceDirection.INPUT) != captureDevice.identity) cancel()
                if (d.id == playbackDevice.identity.id && d.isSink && identity(d, DeviceDirection.OUTPUT) != playbackDevice.identity) cancel()
            }
        }
    }
    private val routeListener = AudioRouting.OnRoutingChangedListener { routing -> callback {
        val direction = if (routing is AudioRecord) DeviceDirection.INPUT else DeviceDirection.OUTPUT
        val approved = if (direction == DeviceDirection.INPUT) captureDevice.identity else playbackDevice.identity
        val actual = routing.routedDevices.map { identity(it, direction) }
        if ((routesConfirmed || actual.isNotEmpty()) && !VoicePolicy.routes(approved, actual)) {
            cancel(if (routesConfirmed) VoiceCode.STALE else VoiceCode.UNSUPPORTED)
        }
    } }
    private val recordingListener = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) = callback {
            val id = record?.audioSessionId
            val actual = configs.singleOrNull { it.clientAudioSessionId == id }
            if (routesConfirmed && actual == null) cancel(VoiceCode.PERMISSION)
            actual?.let {
                if (it.isClientSilenced || it.clientFormat.sampleRate != VoicePolicy.RATE ||
                    it.clientFormat.channelCount != 1 || it.clientFormat.encoding != AudioFormat.ENCODING_PCM_FLOAT) cancel(VoiceCode.PERMISSION)
            }
        }
    }
    fun cancel(code: Int = VoiceCode.CANCELLED) {
        if (cancelled.compareAndSet(false, true)) {
            cancellationCode.set(code)
            NikoVoiceBridge.publishCancellation(key, code)
        }
    }
    internal fun isCancelled(): Boolean = cancelled.get()
    @Synchronized fun permissionStatus(): Int = status {
        requireVoice(!cancelled.get(), cancellationCode.get())
        requireVoice(NikoVoiceBridge.permission(key), VoiceCode.PERMISSION)
        if (claimed) requireVoice(NikoVoiceBridge.owns(this), VoiceCode.STALE)
        VoiceCode.OK
    }
    private fun guard() {
        requireVoice(!cancelled.get(), cancellationCode.get())
        requireVoice(NikoVoiceBridge.permission(key), VoiceCode.PERMISSION)
        if (!routesConfirmed) requireVoice(VoicePolicy.approvalTime(SystemClock.elapsedRealtime(), approvalDeadline), VoiceCode.STALE)
        if (claimed) requireVoice(NikoVoiceBridge.owns(this), VoiceCode.STALE)
    }
    @Synchronized fun pollStatus(): Int = status {
        guard()
        // Each poll has at most one startup phase. Handles are stored before
        // querying them; a late/partial failure remains reachable by stop().
        when (phase) {
            0 -> {
                NikoVoiceBridge.claim(this); claimed = true; guard()
                deadline = SystemClock.elapsedRealtime() + 2_000
                context = dedicatedAudioContext(NikoVoiceBridge.appContext())
                manager = audioManager(context!!)
                requireVoice(manager !== audioManager(NikoVoiceBridge.appContext()), VoiceCode.UNSUPPORTED)
                pump = HandlerThread("niko-voice-callbacks"); pump!!.start()
                handler = Handler(pump!!.looper)
                deviceCallback = true; manager!!.registerAudioDeviceCallback(deviceListener, handler)
                phase = 1
            }
            1 -> {
                verifyDevices()
                val attributes = attributes()
                focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    .setAudioAttributes(attributes).setAcceptsDelayedFocusGain(false).setWillPauseWhenDucked(true)
                    .setOnAudioFocusChangeListener(focusListener, handler!!).build()
                requireVoice(manager!!.requestAudioFocus(focus!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED, VoiceCode.PERMISSION)
                guard(); phase = 2
            }
            2 -> {
                verifyDevices(); guard()
                // AudioService mode ownership is PID-wide and communication
                // clear has no public per-request completion ACK. Stage 1 uses
                // only stream-owned preferred routes; unsupported BT/SCO pairs
                // fail the actual route readback instead of changing global mode.
                phase = 3
            }
            3 -> {
                verifyDevices(); guard()
                val size = boundedBuffer(AudioTrack.getMinBufferSize(VoicePolicy.RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT))
                track = AudioTrack.Builder().setContext(context!!).setAudioAttributes(attributes())
                    .setAudioFormat(format(AudioFormat.CHANNEL_OUT_MONO)).setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(size).build()
                requireVoice(track!!.state == AudioTrack.STATE_INITIALIZED && VoicePolicy.format(track!!.sampleRate,
                    track!!.channelCount, track!!.audioFormat == AudioFormat.ENCODING_PCM_FLOAT, track!!.bufferSizeInFrames), VoiceCode.UNSUPPORTED)
                requireVoice(track!!.setPreferredDevice(playbackDevice.native) && identity(track!!.preferredDevice ?: throw VoiceFailure(VoiceCode.STALE), DeviceDirection.OUTPUT) == playbackDevice.identity, VoiceCode.STALE)
                trackRouting = true; track!!.addOnRoutingChangedListener(routeListener, handler)
                phase = 4
            }
            4 -> {
                verifyDevices(); guard()
                val size = boundedBuffer(AudioRecord.getMinBufferSize(VoicePolicy.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT))
                record = AudioRecord.Builder().setContext(context!!).setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                    .setPrivacySensitive(true).setAudioFormat(format(AudioFormat.CHANNEL_IN_MONO)).setBufferSizeInBytes(size).build()
                requireVoice(record!!.state == AudioRecord.STATE_INITIALIZED && VoicePolicy.format(record!!.sampleRate,
                    record!!.channelCount, record!!.audioFormat == AudioFormat.ENCODING_PCM_FLOAT, record!!.bufferSizeInFrames), VoiceCode.UNSUPPORTED)
                requireVoice(record!!.setPreferredDevice(captureDevice.native) && identity(record!!.preferredDevice ?: throw VoiceFailure(VoiceCode.STALE), DeviceDirection.INPUT) == captureDevice.identity, VoiceCode.STALE)
                recordRouting = true; record!!.addOnRoutingChangedListener(routeListener, handler)
                val callbackHandler = handler!!
                recordCallback = true; record!!.registerAudioRecordingCallback({ task ->
                    if (!callbackHandler.post(task) && !cancelled.get()) cancel()
                }, recordingListener)
                phase = 5
            }
            5 -> { verifyDevices(); guard(); track!!.play(); guard(); phase = 6 }
            6 -> { verifyDevices(); guard(); record!!.startRecording(); guard(); phase = 7 }
        }
        if (phase < 7) { requireVoice(SystemClock.elapsedRealtime() <= deadline, VoiceCode.DEVICE); VoiceCode.STARTING }
        else if (verifyRoutesAndRecording()) {
            if (backgroundApproved && !NikoVoiceBridge.requestForeground(this)) VoiceCode.STARTING
            else { routesConfirmed = true; VoiceCode.RUNNING }
        }
        else { requireVoice(!routesConfirmed && SystemClock.elapsedRealtime() <= deadline, VoiceCode.UNSUPPORTED); VoiceCode.STARTING }
    }
    private fun verifyDevices() {
        guard(); roster.verify(manager!!, captureDevice); roster.verify(manager!!, playbackDevice)
    }
    private fun verifyRoutesAndRecording(): Boolean {
        verifyDevices()
        val input = record ?: throw VoiceFailure(VoiceCode.DEVICE)
        val output = track ?: throw VoiceFailure(VoiceCode.DEVICE)
        requireVoice(input.recordingState == AudioRecord.RECORDSTATE_RECORDING && output.playState == AudioTrack.PLAYSTATE_PLAYING, VoiceCode.DEVICE)
        val actualInput = input.routedDevices.map { identity(it, DeviceDirection.INPUT) }
        val actualOutput = output.routedDevices.map { identity(it, DeviceDirection.OUTPUT) }
        if (actualInput.isEmpty() || actualOutput.isEmpty()) return false
        requireVoice(VoicePolicy.routes(captureDevice.identity, actualInput) && VoicePolicy.routes(playbackDevice.identity, actualOutput),
            if (routesConfirmed) VoiceCode.STALE else VoiceCode.UNSUPPORTED)
        val config = input.activeRecordingConfiguration ?: return false
        requireVoice(!config.isClientSilenced && config.clientAudioSessionId == input.audioSessionId &&
            VoicePolicy.format(config.clientFormat.sampleRate, config.clientFormat.channelCount,
                config.clientFormat.encoding == AudioFormat.ENCODING_PCM_FLOAT, input.bufferSizeInFrames), VoiceCode.PERMISSION)
        guard(); return true
    }
    @Synchronized fun readPcm(buffer: FloatArray): Int = status {
        requireVoice(buffer.size == VoicePolicy.SAMPLES && routesConfirmed && verifyRoutesAndRecording(), VoiceCode.STALE)
        buffer.fill(0f)
        val count = record!!.read(buffer, 0, buffer.size, AudioRecord.READ_NON_BLOCKING)
        requireVoice(VoicePolicy.validCount(count, buffer.size), VoiceCode.DEVICE)
        requireVoice(buffer.take(count).all { it.isFinite() && it >= -1f && it <= 1f }, VoiceCode.DEVICE)
        requireVoice(verifyRoutesAndRecording(), VoiceCode.STALE)
        count
    }
    @Synchronized fun writePcm(buffer: FloatArray, offset: Int, count: Int): Int = status {
        requireVoice(buffer.size == VoicePolicy.SAMPLES && offset >= 0 && count in 1..VoicePolicy.SAMPLES && offset <= buffer.size - count && routesConfirmed, VoiceCode.STALE)
        requireVoice(buffer.sliceArray(offset until offset + count).all { it.isFinite() && it >= -1f && it <= 1f }, VoiceCode.DEVICE)
        requireVoice(verifyRoutesAndRecording(), VoiceCode.STALE)
        val written = track!!.write(buffer, offset, count, AudioTrack.WRITE_NON_BLOCKING)
        requireVoice(VoicePolicy.validCount(written, count), VoiceCode.DEVICE)
        requireVoice(verifyRoutesAndRecording(), VoiceCode.STALE)
        written
    }
    @Synchronized fun stopStatus(): Int {
        // The Rust owner has already closed its publication gate before this
        // worker cleanup entry. External recovery must call cancel() first.
        cancelled.set(true)
        if (stopSequence == null) stopSequence = StopSequence(listOf(
            { detachCallbacks() }, { releaseRecord() }, { releaseTrack() }, { releaseFocus() },
            { drainAndJoin() }, {
                requireVoice(NikoVoiceBridge.stopForegroundOwner(this), VoiceCode.STOP_PENDING)
            }, {
                requireVoice(record == null && track == null && focus == null &&
                    !recordRouting && !trackRouting && !recordCallback && !deviceCallback && pump == null && callbacks.get() == 0, VoiceCode.STOP_PENDING)
                if (claimed) { NikoVoiceBridge.released(this); claimed = false }
                context = null; manager = null; routesConfirmed = false; phase = 8
            }))
        return try { stopSequence!!.advance(); VoiceCode.OK } catch (_: RuntimeException) { VoiceCode.STOP_PENDING }
    }
    private fun detachCallbacks() {
        if (recordCallback) { record?.unregisterAudioRecordingCallback(recordingListener); recordCallback = false }
        if (recordRouting) { record?.removeOnRoutingChangedListener(routeListener); recordRouting = false }
        if (trackRouting) { track?.removeOnRoutingChangedListener(routeListener); trackRouting = false }
        if (deviceCallback) { manager?.unregisterAudioDeviceCallback(deviceListener); deviceCallback = false }
    }
    private fun releaseRecord() {
        val value = record ?: return
        if (value.state != AudioRecord.STATE_UNINITIALIZED) {
            if (value.recordingState == AudioRecord.RECORDSTATE_RECORDING) value.stop()
            requireVoice(value.recordingState == AudioRecord.RECORDSTATE_STOPPED, VoiceCode.STOP_PENDING)
        }
        if (!recordReleased) { value.release(); recordReleased = true }
        requireVoice(value.state == AudioRecord.STATE_UNINITIALIZED, VoiceCode.STOP_PENDING); record = null
    }
    private fun releaseTrack() {
        val value = track ?: return
        if (value.state != AudioTrack.STATE_UNINITIALIZED) {
            if (value.playState == AudioTrack.PLAYSTATE_PLAYING) value.pause()
            requireVoice(value.playState != AudioTrack.PLAYSTATE_PLAYING, VoiceCode.STOP_PENDING)
            value.flush()
        }
        if (!trackReleased) { value.release(); trackReleased = true }
        requireVoice(value.state == AudioTrack.STATE_UNINITIALIZED, VoiceCode.STOP_PENDING); track = null
    }
    private fun releaseFocus() {
        focus?.let { requireVoice(manager!!.abandonAudioFocusRequest(it) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED, VoiceCode.STOP_PENDING); focus = null }
    }
    private fun drainAndJoin() {
        val worker = pump ?: return
        val callbackHandler = handler
        if (worker.isAlive && callbackHandler != null) {
            val barrier = CountDownLatch(1)
            if (callbackHandler.post { barrier.countDown() }) requireVoice(barrier.await(250, TimeUnit.MILLISECONDS), VoiceCode.STOP_PENDING)
            worker.quitSafely(); worker.join(250)
        }
        requireVoice(!worker.isAlive && callbacks.get() == 0, VoiceCode.STOP_PENDING); handler = null; pump = null
    }
    private fun boundedBuffer(min: Int): Int {
        requireVoice(min > 0, VoiceCode.UNSUPPORTED)
        val bytes = maxOf(min, VoicePolicy.SAMPLES * 4 * 4)
        requireVoice(bytes <= VoicePolicy.MAX_DEVICE_FRAMES * 4, VoiceCode.UNSUPPORTED); return bytes
    }
    private fun attributes(): AudioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private fun format(mask: Int): AudioFormat = AudioFormat.Builder().setSampleRate(VoicePolicy.RATE).setChannelMask(mask).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build()
    private fun status(action: () -> Int): Int = try { action() }
        catch (e: VoiceFailure) { e.code } catch (_: SecurityException) { VoiceCode.PERMISSION }
        catch (_: RuntimeException) { VoiceCode.DEVICE }
}
