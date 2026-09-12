import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.nestimer.agent"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nestimer.agent"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("test").java.srcDirs("src/test/kotlin")
    }

    testOptions {
        unitTests.all { it.useJUnitPlatform() }
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        create("release") {
            val path = localProps.getProperty("NESTIMER_KEYSTORE")
            // CI has no keystore and only ever builds debug; skip rather than fail.
            if (!path.isNullOrBlank() && file(path).exists()) {
                storeFile = file(path)
                storePassword = localProps.getProperty("NESTIMER_KEYSTORE_PASSWORD")
                keyAlias = localProps.getProperty("NESTIMER_KEY_ALIAS")
                keyPassword = localProps.getProperty("NESTIMER_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // Reuse the same completeness test as signingConfigs above, so the two
            // guards can't disagree: a missing/moved keystore file cleanly skips
            // signing here too, instead of attaching a half-configured config.
            if (signingConfigs.getByName("release").storeFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation("org.junit.jupiter:junit-jupiter:5.11.3")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
