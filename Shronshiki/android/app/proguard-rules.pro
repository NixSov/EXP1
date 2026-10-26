# WebRTC использует JNI — классы нельзя переименовывать.
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
-dontwarn org.webrtc.**
