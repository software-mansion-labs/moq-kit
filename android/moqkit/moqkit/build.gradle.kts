import com.vanniktech.maven.publish.SonatypeHost
import org.jetbrains.dokka.gradle.DokkaTask

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.maven.publish)
    alias(libs.plugins.dokka)
}

android {
    namespace = "com.swmansion.moqkit"
    compileSdk = 35

    defaultConfig {
        minSdk = 30

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

mavenPublishing {
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL)
    if (project.hasProperty("signing.keyId") || project.hasProperty("signingInMemoryKey")) {
        signAllPublications()
    }
    val publishVersion = project.findProperty("publishVersion")?.toString() ?: "0.0.1-alpha"
    coordinates("com.swmansion.moqkit", "moqkit", publishVersion)
    pom {
        name = "MoQ Kit Android SDK"
        description = "Android SDK for Media over QUIC (MOQ) — live streaming over QUIC/WebTransport."
        url = "https://github.com/software-mansion-labs/moq-kit"
        licenses {
            license {
                name = "Apache License, Version 2.0"
                url = "https://www.apache.org/licenses/LICENSE-2.0.txt"
            }
        }
        scm {
            connection = "scm:git:git://github.com/software-mansion-labs/moq-kit.git"
            developerConnection = "scm:git:ssh://github.com/software-mansion-labs/moq-kit.git"
            url = "https://github.com/software-mansion-labs/moq-kit"
        }
        developers {
            developer {
                id = "swmansion"
                name = "Software Mansion"
                email = "contact@swmansion.com"
            }
        }
    }
}


tasks.withType<DokkaTask>().configureEach {
    dokkaSourceSets {
        create("main") {
            sourceRoots.from(file("src/main/java"))
            perPackageOption {
                matchingRegex.set("uniffi\\..*")
                suppress.set(true)
            }
        }
    }
}

dependencies {
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)

    // CameraX
    val cameraVersion = "1.4.2"
    api("androidx.lifecycle:lifecycle-common:2.8.7")
    implementation("androidx.camera:camera-lifecycle:$cameraVersion")
    implementation("androidx.camera:camera-core:$cameraVersion")
    implementation("androidx.camera:camera-camera2:$cameraVersion")

    testImplementation(libs.junit)
    testImplementation("net.java.dev.jna:jna:5.18.1@aar")
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
