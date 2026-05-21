# Build & CI Fix Blog

## 2026-05-21
- Problem: GitHub Actions CI build failed during `flutter build apk --release` because AndroidX dependency versions required Android Gradle Plugin 8.9.1 or higher, while the project was still using AGP 8.6.0.
- Fix: Updated `android/settings.gradle` to use `com.android.application` version `8.11.1` and `android/gradle/wrapper/gradle-wrapper.properties` to Gradle `8.14`.
- Result: The Gradle wrapper now reports `Gradle 8.14`; the Android build configuration is aligned with the current AndroidX requirements.
- Note: Local repo build artifacts such as `android/build/` were generated during diagnosis and are now excluded via `.gitignore`.

> Notiz: Flutter selbst war im Container nicht direkt verfügbar, daher konnte die vollständige APK-Build-Stufe hier nicht lokal ausgeführt werden. Außerdem fehlte im Container ein lokaler Android-SDK-Pfad (`sdk.dir`), daher konnte `./gradlew` hier nicht vollständig getestet werden.
