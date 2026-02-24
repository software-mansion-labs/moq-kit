plugins {
    alias(libs.plugins.android.library)
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

val aarOutputDir = file("/Users/jakub/repos/moq-kit/examples/android/subscriber/MoQSubscriber/libs")

tasks.register<Copy>("manualBuild") {
    group = "build"
    description = "Compiles the library and copies the AAR to the target directory"

    dependsOn("assembleRelease")

    from(layout.buildDirectory.dir("outputs/aar"))
    into(aarOutputDir)
    include("*-release.aar")

    doLast {
        println("Build finished! AAR copied to $aarOutputDir")
    }
}

dependencies {
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.material)
    testImplementation(libs.junit)
    testImplementation("net.java.dev.jna:jna:5.18.1@aar")
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}