# R8 keep rules for the netineta app.
# Flutter adds its own keeps automatically; these protect the JNI/native VPN
# stack (sing-box libbox + AmneziaWG, both gomobile bindings) and our bridge.

# All JNI native methods.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# gomobile runtime (used by libbox and amneziawg-android).
-keep class go.** { *; }

# sing-box / libbox (net.clever-vpn:libbox-android).
-keep class io.nekohasekai.** { *; }
-keep class libbox.** { *; }

# AmneziaWG (com.zaneschepke:amneziawg-android).
-keep class org.amnezia.** { *; }
-keep class com.zaneschepke.** { *; }

# Our native side: referenced by name from JNI / Flutter MethodChannel / manifest.
-keep class shop.ironvpn.app.** { *; }

# Reflection/metadata needed by gomobile bindings.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod, Exceptions

-dontwarn go.**
-dontwarn io.nekohasekai.**
-dontwarn org.amnezia.**
-dontwarn com.zaneschepke.**
