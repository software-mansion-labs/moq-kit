plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.maven.publish)
}

android {
    namespace = "com.swmansion.moqkit"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

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


dependencies {
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)
    testImplementation(libs.junit)
    testImplementation("net.java.dev.jna:jna:5.18.1@aar")
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}