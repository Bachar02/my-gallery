# Release shrinking rules (R8).

# ---- ML Kit text recognition ------------------------------------------------
# ML Kit discovers its components reflectively (registrars declared in the
# merged manifest), so keep its API, registrars and the Flutter plugin intact.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_commons.** { *; }
# The Flutter plugin references the optional script recognizers (Chinese,
# Devanagari, Japanese, Korean); only the bundled Latin model is shipped.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ---- ONNX Runtime -------------------------------------------------------------
# Its JNI layer looks up Java classes, fields and methods by name.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# ---- General ------------------------------------------------------------------
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
# The Flutter engine references Play Core (deferred components), which is unused.
-dontwarn com.google.android.play.core.**

# ---- Glide (photo_manager) -----------------------------------------------------
# QuietGlideModule is created reflectively from the manifest meta-data.
-keep public class * implements com.bumptech.glide.module.GlideModule
-keep class com.bachar02.ai_gallery.QuietGlideModule { *; }
