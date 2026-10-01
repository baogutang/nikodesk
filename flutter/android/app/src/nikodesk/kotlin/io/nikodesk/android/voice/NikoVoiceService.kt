package io.nikodesk.android.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder

// Non-exported, no boot/restart/bind path. Only the explicitly approved exact
// owner can submit this service from a currently visible local Activity.
class NikoVoiceService : Service() {
    private var owned: CallKey? = null
    private var stopIntent: PendingIntent? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val key = intent?.let { CallKey(it.getStringExtra("nonce") ?: "", it.getLongExtra("epoch", 0), it.getLongExtra("lease", 0)) }
        if (key == null || !key.valid()) { if (owned == null) stopSelf(startId); return START_NOT_STICKY }
        if (intent.action == STOP) {
            if (owned == key) NikoVoiceBridge.cancelFromLocalService(key)
            // Keep the foreground owner until native stop/drain/join requests
            // finishExact. A stopSelf submission alone is not release ACK.
            return START_NOT_STICKY
        }
        if (intent.action != START || owned != null || !NikoVoiceBridge.serviceCreated(this, key)) {
            if (owned == null) stopSelf(startId); return START_NOT_STICKY
        }
        owned = key // Reachable before every fallible native framework call.
        try {
            requireVoice(NikoVoiceBridge.canForeground(key), VoiceCode.PERMISSION)
            val notifications = getSystemService(NotificationManager::class.java)
            requireVoice(VoiceAuthorization.notificationsReady(this), VoiceCode.PERMISSION)
            notifications.createNotificationChannel(NotificationChannel(CHANNEL, "NikoDesk voice", NotificationManager.IMPORTANCE_LOW))
            requireVoice(notifications.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE, VoiceCode.PERMISSION)
            val stop = PendingIntent.getService(this, 0, intent(this, key).setAction(STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            stopIntent = stop
            val notice = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("NikoDesk voice call").setContentText("Microphone in use — stop the call to release it")
                .setVisibility(Notification.VISIBILITY_PUBLIC).setOngoing(true).addAction(Notification.Action.Builder(null, "Stop", stop).build()).build()
            startForeground(NOTICE_ID, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            requireVoice(NikoVoiceBridge.enterForeground(this, key), VoiceCode.PERMISSION)
        } catch (_: RuntimeException) {
            NikoVoiceBridge.cancelFromLocalService(key)
            finishExact(key)
        }
        return START_NOT_STICKY
    }
    internal fun finishExact(key: CallKey) {
        if (owned != key) return
        try { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        catch (_: RuntimeException) { NikoVoiceBridge.cancelFromLocalService(key) }
        // Retain owned identity until framework onDestroy, including failure.
    }
    override fun onDestroy() {
        val key = owned
        // Cancel publication first; then actual lifecycle proves this service
        // has ended. Old callbacks cannot release a replacement service.
        if (key != null) NikoVoiceBridge.cancelFromLocalService(key)
        var released = false
        try {
            stopIntent?.cancel(); stopIntent = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            released = true
        } catch (_: RuntimeException) { if (key != null) NikoVoiceBridge.cancelFromLocalService(key) }
        finally { super.onDestroy() }
        if (released && key != null) { NikoVoiceBridge.serviceDestroyed(this, key); owned = null }
        // Failure retains the exact framework owner; never report Stopped.
    }
    companion object {
        private const val START = "io.nikodesk.voice.LOCAL_FOREGROUND"
        private const val STOP = "io.nikodesk.voice.STOP"
        private const val CHANNEL = "nikodesk_voice"
        private const val NOTICE_ID = 0x4e5601
        internal fun intent(context: Context, key: CallKey): Intent = Intent(context, NikoVoiceService::class.java).setAction(START)
            // PendingIntent identity ignores extras. This URI distinguishes
            // every nonce/epoch/lease so an old notification never stops new audio.
            .setData(Uri.parse("nikodesk-voice://call/${key.nonce}/${key.epoch}/${key.lease}"))
            .putExtra("nonce", key.nonce).putExtra("epoch", key.epoch).putExtra("lease", key.lease)
    }
}
