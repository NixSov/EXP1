package ru.shronshiki.shronshiki

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class MessagePushService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) { MessageAlerts.show(this,message.data) }
    override fun onNewToken(token: String) {
        getSharedPreferences("message_push",Context.MODE_PRIVATE).edit().putString("token",token).apply()
        tokenListener?.invoke(token)
    }
    companion object { var tokenListener: ((String)->Unit)?=null }
}

object MessageAlerts {
    @Synchronized fun show(context: Context,data: Map<String,String>) {
        val prefs=context.getSharedPreferences("message_push",Context.MODE_PRIVATE)
        if(!prefs.getBoolean("enabled",false) || data["user"]!=prefs.getString("user",null)) return
        if(Build.VERSION.SDK_INT>=33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) return
        val event=data["id"] ?: return
        val seen=prefs.getString("seen","")!!.split(',').filter { it.isNotBlank() }
        if(event in seen) return
        val manager=context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if(Build.VERSION.SDK_INT>=26) manager.createNotificationChannel(NotificationChannel("shronshiki_messages","Сообщения",NotificationManager.IMPORTANCE_HIGH))
        val chat=data["chat_id"].orEmpty()
        if(chat.isNotEmpty() && chat==prefs.getString("activeChat",null)) {
            prefs.edit().putString("seen",(seen.takeLast(99)+event).joinToString(",")).apply()
            return
        }
        val code=data["room_code"].orEmpty()
        val uri=if(chat.isNotEmpty()) Uri.Builder().scheme("shronshiki").authority("chat").appendPath(chat).build()
            else Uri.Builder().scheme("shronshiki").authority("join").appendPath(code).build()
        val open=Intent(Intent.ACTION_VIEW,uri).setPackage(context.packageName).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val intent=PendingIntent.getActivity(context,event.hashCode(),open,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder=if(Build.VERSION.SDK_INT>=26) Notification.Builder(context,"shronshiki_messages") else { @Suppress("DEPRECATION") Notification.Builder(context) }
        val notification=builder.setSmallIcon(android.R.drawable.stat_notify_chat).setContentTitle(data["title"] ?: "Shronshiki")
            .setContentText(data["text"] ?: "Вам написали").setContentIntent(intent).setAutoCancel(true).setCategory(Notification.CATEGORY_MESSAGE).build()
        manager.notify(event.hashCode(),notification)
        prefs.edit().putString("seen",(seen.takeLast(99)+event).joinToString(",")).apply()
    }
}
