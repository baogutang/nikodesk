package io.nikodesk.android.voice

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.lang.ref.WeakReference

internal object PermissionCode {
    const val GRANTED = 1
    // Android has no public NOT_DETERMINED permission flag. This means only
    // not granted and no prior request recorded by this app, not global OS history.
    const val NOT_REQUESTED_BY_APP = 0
    const val DENIED = -1
    const val RESTRICTED = -3
    const val UNAVAILABLE = -4
    const val PENDING = 2
}
internal fun permissionHistory(context: Context) = context.getSharedPreferences("nikodesk-owned-voice-permission-v1", Context.MODE_PRIVATE)
internal fun microphoneStatus(context: Context, activity: Activity?): Int = try {
    requireVoice(NikoVoiceBridge.ordinary(context), VoiceCode.PERMISSION)
    if (context.packageManager.isPermissionRevokedByPolicy(Manifest.permission.RECORD_AUDIO, context.packageName)) PermissionCode.RESTRICTED
    else if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) PermissionCode.GRANTED
    else if (permissionHistory(context).getBoolean("requested", false) || activity?.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) == true) PermissionCode.DENIED
    else PermissionCode.NOT_REQUESTED_BY_APP
} catch (_: RuntimeException) { PermissionCode.UNAVAILABLE }

class NikoVoicePermissionJob internal constructor(activity: Activity?) {
    internal val activity = WeakReference(activity)
    private val state = VoiceJobState<Int>(SystemClock.elapsedRealtime() + 90_000)
    internal fun live(): Boolean = state.live(SystemClock.elapsedRealtime())
    internal fun complete(code: Int) { state.complete(code, SystemClock.elapsedRealtime()) }
    fun cancel() { state.cancel(); VoiceAuthorization.forget(this) }
    fun pollCode(): Int = try {
        val result = state.poll(SystemClock.elapsedRealtime())
        // A system grant arriving in the background cannot grant this job.
        if (result == PermissionCode.GRANTED && NikoVoiceBridge.localActivity() !== activity.get()) PermissionCode.PENDING
        else result ?: PermissionCode.PENDING
    } catch (_: VoiceFailure) { VoiceCode.CANCELLED }
}

class NikoVoiceApprovalJob internal constructor(activity: Activity?, internal val key: CallKey) {
    internal val activity = WeakReference(activity)
    private val state = VoiceJobState<String>(SystemClock.elapsedRealtime() + 30_000)
    private var proof = ""
    internal fun live(): Boolean = state.live(SystemClock.elapsedRealtime())
    @Synchronized internal fun complete(token: String) {
        if (state.complete(token, SystemClock.elapsedRealtime())) proof = token
        else NikoVoiceBridge.clearLocalProof(key, token)
    }
    @Synchronized fun cancel() { state.cancel(); NikoVoiceBridge.clearLocalProof(key, proof); VoiceAuthorization.forget(this) }
    @Synchronized fun pollProof(): String = try {
        state.poll(SystemClock.elapsedRealtime()) ?: ""
    } catch (_: VoiceFailure) { NikoVoiceBridge.clearLocalProof(key, proof); "!cancelled" }
}

internal object VoiceAuthorization {
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private data class Dialog(val activity: WeakReference<Activity>, val permission: String,
        val live: () -> Boolean, val result: (Boolean) -> Unit)
    private val requests = mutableMapOf<Int, Dialog>()
    private val jobs = mutableSetOf<NikoVoicePermissionJob>()
    private val approvals = mutableSetOf<NikoVoiceApprovalJob>()

    fun notificationsReady(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED &&
            manager.areNotificationsEnabled() && manager.getNotificationChannel("nikodesk_voice")?.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun request(activity: Activity, permission: String, live: () -> Boolean, result: (Boolean) -> Unit) {
        val prefs = permissionHistory(activity)
        val code = synchronized(lock) {
            // Codes never repeat, including process restarts. Cancellation keeps
            // the system-owned request registered until its exact callback.
            val next = prefs.getInt("next_code", 0x4e00)
            requireVoice(next in 0x4e00..0x7ffe && requests.isEmpty(), VoiceCode.BUSY)
            val edit = prefs.edit().putInt("next_code", next + 1)
            if (permission == Manifest.permission.RECORD_AUDIO) edit.putBoolean("requested", true)
            requireVoice(edit.commit(), VoiceCode.DEVICE)
            requests[next] = Dialog(WeakReference(activity), permission, live, result)
            next
        }
        // If the framework throws after dispatch, its callback can still be
        // late. Preserve the reserved code; never turn that uncertainty into a
        // different job's grant or a second concurrent dialog.
        activity.requestPermissions(arrayOf(permission), code)
    }
    fun beginPermission(): NikoVoicePermissionJob {
        val activity = NikoVoiceBridge.localActivity()
        val job = NikoVoicePermissionJob(activity)
        synchronized(lock) { jobs.add(job) }
        if (activity == null || !main.post { dispatchPermission(job, activity) }) job.complete(PermissionCode.UNAVAILABLE)
        return job
    }
    private fun dispatchPermission(job: NikoVoicePermissionJob, activity: Activity) {
        if (!job.live() || NikoVoiceBridge.localActivity() !== activity) { job.cancel(); return }
        try {
            val status = microphoneStatus(activity, activity)
            if (status == PermissionCode.GRANTED || status == PermissionCode.RESTRICTED || status == PermissionCode.UNAVAILABLE) { job.complete(status); return }
            request(activity, Manifest.permission.RECORD_AUDIO, { job.live() }) { granted ->
                val actual = microphoneStatus(activity, activity)
                job.complete(if (granted && actual == PermissionCode.GRANTED) PermissionCode.GRANTED
                    else if (actual == PermissionCode.RESTRICTED) PermissionCode.RESTRICTED else PermissionCode.DENIED)
            }
        } catch (_: RuntimeException) { job.complete(PermissionCode.UNAVAILABLE) }
    }
    fun permissionResult(activity: Activity, code: Int, permissions: Array<out String>, results: IntArray): Boolean {
        if (code !in 0x4e00..0x7ffe) return false
        val dialog = synchronized(lock) { requests.remove(code) } ?: return true
        if (dialog.activity.get() !== activity || !dialog.live() || activity.isFinishing || activity.isDestroyed) return true
        val granted = permissions.size == 1 && results.size == 1 && permissions[0] == dialog.permission &&
            results[0] == PackageManager.PERMISSION_GRANTED &&
            activity.checkSelfPermission(dialog.permission) == PackageManager.PERMISSION_GRANTED
        dialog.result(granted)
        return true
    }
    fun beginApproval(snapshot: Long, input: String, output: String, format: String,
        nonce: ByteArray, epoch: Long, lease: Long, background: Boolean): NikoVoiceApprovalJob {
        val activity = NikoVoiceBridge.localActivity()
        val key = NikoVoiceBridge.callKey(nonce, epoch, lease)
        val frozenNonce = nonce.copyOf()
        val job = NikoVoiceApprovalJob(activity, key)
        synchronized(lock) { approvals.add(job) }
        if (activity == null || !main.post {
            if (!job.live() || NikoVoiceBridge.localActivity() !== activity) job.cancel()
            else try {
                requireVoice(microphoneStatus(activity, activity) == PermissionCode.GRANTED, VoiceCode.PERMISSION)
                val approve = {
                    // Notification dialogs may finish before window focus is
                    // restored. Defer the bound proof; do not auto-start a call.
                    completeApproval(job, activity, snapshot, input, output, format, frozenNonce, epoch, lease, background)
                }
                if (background && !notificationsReady(activity)) {
                    request(activity, Manifest.permission.POST_NOTIFICATIONS, { job.live() }) { granted ->
                        if (granted && notificationsReady(activity)) approve() else job.complete("!notification_permission")
                    }
                } else approve()
            } catch (failure: VoiceFailure) { job.complete(if (failure.code == VoiceCode.BUSY) "!busy" else "!denied") }
            catch (_: RuntimeException) { job.complete("!unavailable") }
        }) job.cancel()
        return job
    }
    private fun completeApproval(job: NikoVoiceApprovalJob, activity: Activity, snapshot: Long,
        input: String, output: String, format: String, nonce: ByteArray, epoch: Long, lease: Long, background: Boolean) {
        if (!job.live() || activity.isFinishing || activity.isDestroyed) { job.cancel(); return }
        if (NikoVoiceBridge.localActivity() !== activity) {
            if (!main.postDelayed({ completeApproval(job, activity, snapshot, input, output, format, nonce, epoch, lease, background) }, 50)) job.cancel()
            return
        }
        job.complete(NikoVoiceBridge.approveLocal(activity, snapshot, input, output, format, nonce, epoch, lease, background).ifEmpty { "!denied" })
    }
    fun cancelActivity(activity: Activity) {
        val cancel = synchronized(lock) {
            Pair(jobs.filter { it.activity.get() === activity }, approvals.filter { it.activity.get() === activity })
        }
        cancel.first.forEach { it.cancel() }; cancel.second.forEach { it.cancel() }
    }
    fun forget(job: NikoVoicePermissionJob) = synchronized(lock) { jobs.remove(job) }
    fun forget(job: NikoVoiceApprovalJob) = synchronized(lock) { approvals.remove(job) }
}
