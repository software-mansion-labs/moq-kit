package com.swmansion.moqdemo.features.publisher

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first

class ScreenCaptureService : Service() {
    companion object {
        private const val NOTIFICATION_CHANNEL_ID = "screen_capture"
        private const val NOTIFICATION_ID = 1

        val isRunning = MutableStateFlow(false)

        suspend fun awaitStarted() {
            isRunning.filter { it }.first()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL_ID, "Screen Capture", NotificationManager.IMPORTANCE_LOW)
        )
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Screen Recording")
            .setContentText("MoQ Demo is recording your screen")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .build()
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        isRunning.value = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning.value = false
        super.onDestroy()
    }
}
