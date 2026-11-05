plugins { id("com.android.application"); kotlin("android"); kotlin("plugin.serialization"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace="run.limeai.link"
    compileSdk=36
    buildToolsVersion="36.0.0"
    defaultConfig { applicationId="run.limeai.limelink"; minSdk=26; targetSdk=36; versionCode=1; versionName="0.1.0" }
    buildFeatures { compose=true }
    compileOptions { sourceCompatibility=JavaVersion.VERSION_21; targetCompatibility=JavaVersion.VERSION_21 }
}
kotlin { jvmToolchain(21) }
dependencies {
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2025.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
}
