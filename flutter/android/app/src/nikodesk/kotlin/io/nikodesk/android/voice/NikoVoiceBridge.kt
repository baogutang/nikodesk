package io.nikodesk.android.voice

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.content.pm.PackageManager
import android.os.Build
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.lang.ref.WeakReference

class NikoVoicePreparation internal constructor(private val status: Int, private val value: NikoVoiceSession?) {
    fun code(): Int = status
    fun session(): NikoVoiceSession? = value
}
internal data class LocalApproval(val token: String, val key: CallKey, val revision: Long,
    val input: String, val output: String, val format: String, val expires: Long, val background: Boolean)

// Only the explicit local authorization job may mint a call approval. Loading
// this bridge and Activity lifecycle hooks never request permission or devices.
object NikoVoiceBridge {
    private val lock = Any()
    private var context: Context? = null
    private var initialized = false
    private var roster: DeviceRoster? = null
    private var revision = 0L
    private var lastLease = 0L
    private var approval: LocalApproval? = null
    private var visibleActivity = WeakReference<Activity>(null)
    private var resumed = false
    private var foreground: CallKey? = null
    private var owner: NikoVoiceSession? = null
    private var prepared: NikoVoiceSession? = null
    private var lastStopped: CallKey? = null
    private val main = Handler(Looper.getMainLooper())
    private val foregroundLease = ForegroundLease()
    private var foregroundService: NikoVoiceService? = null
    @JvmStatic private external fun nativeInitialize(): Boolean
    @JvmStatic private external fun nativeCancelled(nonce: String, epoch: Long, lease: Long, code: Int)
    internal fun publishCancellation(key: CallKey, code: Int) {
        // Rust first closes the exact owner's atomic publication gate. Do not
        // describe/log JNI exceptions or raw device identifiers.
        try { nativeCancelled(key.nonce, key.epoch, key.lease, code) } catch (_: LinkageError) { }
    }

    @JvmStatic fun initContext(value: Context): Boolean = try {
        requireVoice(Build.VERSION.SDK_INT >= 36 && ordinary(value), VoiceCode.UNSUPPORTED)
        val app = value.applicationContext
        requireVoice(app.packageName == "io.nikodesk.android" || app.packageName == "io.nikodesk.android.dev", VoiceCode.PERMISSION)
        synchronized(lock) {
            requireVoice(context == null || context === app, VoiceCode.BUSY)
            context = app
        }
        nativeInitialize().also { ready -> synchronized(lock) { initialized = ready } }
    } catch (_: RuntimeException) { false } catch (_: LinkageError) { false }

    internal fun appContext(): Context = synchronized(lock) { context ?: throw VoiceFailure(VoiceCode.UNSUPPORTED) }
    internal fun ordinary(value: Context): Boolean = VoicePolicy.ordinary(Process.myUid(), value.applicationInfo.uid,
        Process.isApplicationUid(Process.myUid()), Process.isIsolated())
    internal fun visible(): Boolean = synchronized(lock) {
        val activity = visibleActivity.get()
        resumed && activity != null && !activity.isFinishing && !activity.isDestroyed && activity.hasWindowFocus()
    }
    internal fun localActivity(): Activity? = synchronized(lock) {
        visibleActivity.get()?.takeIf { visible() }
    }
    @JvmStatic fun available(): Boolean = try {
        synchronized(lock) { VoiceReadiness.available(initialized, ordinary(appContext()), android.os.Build.VERSION.SDK_INT,
            visibleActivity.get()?.let { !it.isFinishing && !it.isDestroyed } == true, foreground != null && foregroundService != null) }
    } catch (_: RuntimeException) { false }
    @JvmStatic fun normalUserUid(): Int = try {
        val app = appContext()
        if (ordinary(app)) Process.myUid() else -1
    } catch (_: RuntimeException) { -1 }
    @JvmStatic fun authorizationStatusCode(): Int = try {
        microphoneStatus(appContext(), localActivity())
    } catch (_: RuntimeException) { PermissionCode.UNAVAILABLE }
    @JvmStatic fun beginPermissionJob(): NikoVoicePermissionJob = VoiceAuthorization.beginPermission()
    @JvmStatic fun beginApprovalJob(snapshot: Long, input: String, output: String, format: String,
        nonce: ByteArray, epoch: Long, lease: Long, background: Boolean): NikoVoiceApprovalJob =
        VoiceAuthorization.beginApproval(snapshot, input, output, format, nonce, epoch, lease, background)
    @JvmStatic fun onPermissionResult(activity: Activity, requestCode: Int, permissions: Array<out String>, results: IntArray): Boolean =
        VoiceAuthorization.permissionResult(activity, requestCode, permissions, results)
    @JvmStatic fun onActivityDestroyed(activity: Activity) {
        setLocalActivityVisible(activity, false); VoiceAuthorization.cancelActivity(activity)
        synchronized(lock) { if (visibleActivity.get() === activity) visibleActivity.clear() }
    }
    internal fun clearLocalProof(key: CallKey, token: String) = synchronized(lock) {
        if (approval?.key == key && approval?.token == token) approval = null
    }
    // Actual Activity lifecycle/focus hooks run on the UI thread.
    @JvmStatic fun setLocalActivityVisible(activity: Activity, active: Boolean): Boolean = try {
        requireVoice(Build.VERSION.SDK_INT >= 36 && Looper.myLooper() == Looper.getMainLooper() && ordinary(activity) && activity.packageName == appContext().packageName, VoiceCode.PERMISSION)
        synchronized(lock) {
            if (active) { visibleActivity = WeakReference(activity); resumed = true }
            else if (visibleActivity.get() === activity) {
                resumed = false; approval = null
                prepared?.cancel()
                if (foreground != owner?.key) owner?.cancel()
            }
        }; true
    } catch (_: RuntimeException) { false }
    internal fun permission(key: CallKey): Boolean {
        val app = appContext()
        val fgs = synchronized(lock) { foreground == key && owner?.key == key }
        val backgroundApproved = synchronized(lock) { owner?.let { it.key == key && it.backgroundApproved } == true }
        if (backgroundApproved && !VoiceAuthorization.notificationsReady(app)) return false
        return Build.VERSION.SDK_INT >= 36 && VoicePolicy.authorized(ordinary(app),
            app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED, visible(), fgs)
    }
    @JvmStatic fun authorizationStatus(): Int = try {
        val app = appContext()
        if (!ordinary(app)) VoiceCode.PERMISSION else if (app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) VoiceCode.OK else VoiceCode.PERMISSION
    } catch (_: RuntimeException) { VoiceCode.UNSUPPORTED }
    @JvmStatic fun snapshotJson(): String = try {
        synchronized(lock) {
            requireVoice(owner == null, VoiceCode.BUSY)
            val app = appContext(); requireVoice(ordinary(app), VoiceCode.PERMISSION)
            requireVoice(revision < Long.MAX_VALUE, VoiceCode.UNSUPPORTED); revision++
            val next = enumerateRoster(app, revision)
            prepared?.cancel(); prepared = null; roster = next; approval = null; next.json()
        }
    } catch (failure: VoiceFailure) { errorJson(failure.code) } catch (_: RuntimeException) { errorJson(VoiceCode.DEVICE) }

    // Called only by an explicit local UI approval action after OS permission.
    // The token freezes device+format+call identity; it is not a capability ticket.
    @JvmStatic fun approveLocal(activity: Activity, snapshot: Long, input: String, output: String,
        format: String, nonce: ByteArray, epoch: Long, lease: Long, background: Boolean = false): String = try {
        requireVoice(Looper.myLooper() == Looper.getMainLooper() && visibleActivity.get() === activity && visible(), VoiceCode.PERMISSION)
        val key = callKey(nonce, epoch, lease)
        synchronized(lock) {
            requireVoice(owner == null, VoiceCode.BUSY)
            requireVoice(permission(key), VoiceCode.PERMISSION)
            requireVoice(!background || VoiceAuthorization.notificationsReady(activity), VoiceCode.PERMISSION)
            val r = roster ?: throw VoiceFailure(VoiceCode.STALE)
            requireVoice(r.revision == snapshot && r.formatToken == format && lease > lastLease, VoiceCode.STALE)
            r.selected(input, DeviceDirection.INPUT); r.selected(output, DeviceDirection.OUTPUT)
            val token = newToken()
            approval = LocalApproval(token, key, snapshot, input, output, format, SystemClock.elapsedRealtime() + 30_000, background)
            token
        }
    } catch (failure: VoiceFailure) {
        when (failure.code) { VoiceCode.BUSY -> "!busy"; VoiceCode.STALE -> "!devices_changed"; else -> "!denied" }
    } catch (_: RuntimeException) { "!unavailable" }

    @JvmStatic fun prepare(snapshot: Long, input: String, output: String, format: String,
        nonce: ByteArray, epoch: Long, lease: Long, localToken: String): NikoVoicePreparation = try {
        val key = callKey(nonce, epoch, lease)
        synchronized(lock) {
            requireVoice(owner == null && permission(key), VoiceCode.PERMISSION)
            val a = approval ?: throw VoiceFailure(VoiceCode.PERMISSION)
            requireVoice(a.token == localToken && a.key == key && a.revision == snapshot && a.input == input && a.output == output && a.format == format && VoicePolicy.approvalTime(SystemClock.elapsedRealtime(), a.expires), VoiceCode.STALE)
            val r = roster ?: throw VoiceFailure(VoiceCode.STALE)
            requireVoice(r.revision == snapshot && r.formatToken == format && lease > lastLease, VoiceCode.STALE)
            val capture = r.selected(input, DeviceDirection.INPUT); val playback = r.selected(output, DeviceDirection.OUTPUT)
            val session = NikoVoiceSession(key, r, capture, playback, a.expires, a.background)
            prepared?.cancel(); prepared = session
            approval = null; lastLease = lease
            NikoVoicePreparation(VoiceCode.OK, session)
        }
    } catch (failure: VoiceFailure) { NikoVoicePreparation(failure.code, null) }
      catch (_: RuntimeException) { NikoVoicePreparation(VoiceCode.DEVICE, null) }

    internal fun claim(session: NikoVoiceSession) = synchronized(lock) {
        requireVoice(owner == null, VoiceCode.BUSY)
        requireVoice(prepared === session && !session.isCancelled() && session.key.lease == lastLease && roster === session.roster, VoiceCode.STALE)
        owner = session; prepared = null
    }
    internal fun owns(session: NikoVoiceSession): Boolean = synchronized(lock) { owner === session }
    internal fun released(session: NikoVoiceSession) = synchronized(lock) {
        requireVoice(owner === session || owner == null, VoiceCode.BUSY)
        if (owner === session) { owner = null; lastStopped = session.key; if (foreground == session.key) foreground = null }
    }
    @JvmStatic fun revokeLocal(nonce: ByteArray, epoch: Long, lease: Long): Boolean = try {
        val key = callKey(nonce, epoch, lease)
        synchronized(lock) {
            if (approval?.key == key) approval = null
            prepared?.takeIf { it.key == key }?.cancel()
            owner?.takeIf { it.key == key }?.cancel()
        }; true
    } catch (_: RuntimeException) { false }
    // Recovery worker only. This is a native-framework ACK, not a VoiceOwner
    // thread-join ACK. The caller must still stop/join its Rust owner before it
    // releases its capability/native lease or reports Stopped to the UI.
    @JvmStatic fun retryRetainedNativeStop(nonce: ByteArray, epoch: Long, lease: Long): Int = try {
        val key = callKey(nonce, epoch, lease)
        val target = synchronized(lock) {
            owner?.let { requireVoice(it.key == key, VoiceCode.BUSY); it }
                ?: prepared?.let { requireVoice(it.key == key, VoiceCode.BUSY); it }
        }
        if (target == null) {
            synchronized(lock) { requireVoice(lastStopped == key, VoiceCode.STALE) }
            VoiceCode.OK
        } else {
            target.cancel()
            val result = target.stopStatus()
            if (result == VoiceCode.OK) synchronized(lock) {
                if (prepared === target) { prepared = null; lastStopped = key }
            }
            result
        }
    } catch (failure: VoiceFailure) { failure.code } catch (_: RuntimeException) { VoiceCode.STOP_PENDING }
    internal fun canForeground(key: CallKey): Boolean = synchronized(lock) {
        owner?.let { it.key == key && it.backgroundApproved && !it.isCancelled() } == true &&
            visible() && permission(key) && VoiceAuthorization.notificationsReady(appContext())
    }
    internal fun cancelFromLocalService(key: CallKey) = synchronized(lock) { owner?.takeIf { it.key == key }?.cancel() }
    internal fun requestForeground(session: NikoVoiceSession): Boolean {
        synchronized(lock) {
            requireVoice(owner === session && session.backgroundApproved && !session.isCancelled(), VoiceCode.STALE)
            if (foreground == session.key) return true
            if (!foregroundLease.request(session.key)) return false
        }
        if (!main.post {
            synchronized(lock) {
                if (!foregroundLease.dispatch(session.key)) return@post
                if (!canForeground(session.key)) {
                    foregroundLease.undispatched(session.key); session.cancel(VoiceCode.PERMISSION); return@post
                }
                try {
                    foregroundLease.submit(session.key)
                    appContext().startForegroundService(NikoVoiceService.intent(appContext(), session.key))
                } catch (_: RuntimeException) {
                    // Submission failure cannot prove a late framework service
                    // never existed. Retain the owner/lease for recovery.
                    session.cancel(VoiceCode.PERMISSION)
                }
            }
        }) synchronized(lock) { foregroundLease.undispatched(session.key); session.cancel() }
        return false
    }
    internal fun serviceCreated(service: NikoVoiceService, key: CallKey): Boolean = synchronized(lock) {
        if (!foregroundLease.attach(key) || foregroundService != null) false
        else { foregroundService = service; true }
    }
    internal fun enterForeground(service: NikoVoiceService, key: CallKey): Boolean = synchronized(lock) {
        if (foregroundService !== service || !canForeground(key)) false else { foreground = key; true }
    }
    internal fun serviceDestroyed(service: NikoVoiceService, key: CallKey) = synchronized(lock) {
        if (foregroundService === service && foregroundLease.destroy(key)) {
            foregroundService = null
            if (foreground == key) foreground = null
            owner?.takeIf { it.key == key }?.cancel()
        }
    }
    internal fun stopForegroundOwner(session: NikoVoiceSession): Boolean = synchronized(lock) {
        if (!session.backgroundApproved || foregroundLease.clearIfUnsubmitted(session.key)) return true
        requireVoice(foregroundLease.matches(session.key), VoiceCode.STOP_PENDING)
        val service = foregroundService
        if (service != null && foregroundLease.finish(session.key)) {
            if (!main.post { service.finishExact(session.key) }) foregroundLease.retryFinish(session.key)
        }
        false // Only actual onDestroy clears the submitted framework owner.
    }
    private fun errorJson(code: Int): String = JSONObject().put("ok", false).put("error", code).toString()
    internal fun callKey(nonce: ByteArray, epoch: Long, lease: Long): CallKey {
        requireVoice(nonce.size == 16, VoiceCode.STALE)
        val key = CallKey(nonce.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }, epoch, lease)
        requireVoice(key.valid(), VoiceCode.STALE); return key
    }
}
