import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.SonatypeHost
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.jvm.tasks.Jar
import org.jetbrains.dokka.gradle.DokkaTask
import java.util.Properties

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.maven.publish)
    alias(libs.plugins.dokka)
}

android {
    namespace = "com.swmansion.moqkit"
    compileSdk = 35

    defaultConfig {
        minSdk = 29

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

val emptyJavadocJar by tasks.registering(Jar::class) {
    archiveClassifier.set("javadoc")
}

mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = false))
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

publishing {
    publications.withType<MavenPublication>().configureEach {
        artifact(emptyJavadocJar)
    }
}

tasks.withType<DokkaTask>().configureEach {
    dokkaSourceSets {
        create("main") {
            sourceRoots.from(android.sourceSets.getByName("main").java.srcDirs)
            val localSdkDir: String? = rootProject.file("local.properties")
                .takeIf { it.isFile }
                ?.inputStream()
                ?.use { stream ->
                    Properties().apply { load(stream) }.getProperty("sdk.dir")
                }
            val sdkDir = System.getenv("ANDROID_HOME")
                ?: System.getenv("ANDROID_SDK_ROOT")
                ?: localSdkDir
            if (sdkDir != null) {
                classpath.from(files("$sdkDir/platforms/android-${android.compileSdk ?: 35}/android.jar"))
            }
            val releaseClasspath = configurations.getByName("releaseCompileClasspath")
                .filter { file -> !file.name.startsWith("moq") }
            classpath.from(releaseClasspath)

            perPackageOption {
                matchingRegex.set("uniffi\\..*")
                suppress.set(true)
            }
            perPackageOption {
                matchingRegex.set("com\\.swmansion\\.moqkit\\..*\\.internal(\\..*)?")
                suppress.set(true)
            }
        }
    }
}

dependencies {
    api(libs.moq)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)

    // CameraX
    val cameraVersion = "1.4.2"
    api("androidx.lifecycle:lifecycle-common:2.8.7")
    implementation("androidx.camera:camera-lifecycle:$cameraVersion")
    implementation("androidx.camera:camera-core:$cameraVersion")
    implementation("androidx.camera:camera-camera2:$cameraVersion")

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
