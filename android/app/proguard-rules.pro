# Keep rules for google_mlkit_text_recognition.
# The plugin references optional multi-script ML Kit classes that are only
# present when the corresponding script-specific artifact is added as a
# dependency.  Suppress the R8 missing-class errors for every optional script.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
# MediaPipe R8 Keep Rules (für flutter_gemma)
-keep class com.google.mediapipe.** { *; }
-keep class com.google.auto.value.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.auto.value.**
