package com.tryps.app

import android.app.NotificationChannel
import android.app.NotificationManager
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class TrypsMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Ride updates", NotificationManager.IMPORTANCE_HIGH),
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map)
            .setContentTitle(message.notification?.title ?: "Tryps ride update")
            .setContentText(message.notification?.body ?: message.data["message"].orEmpty())
            .setAutoCancel(true)
            .build()
        manager.notify(message.messageId?.hashCode() ?: 1, notification)
    }

    private companion object {
        const val CHANNEL_ID = "ride_updates"
    }
}
