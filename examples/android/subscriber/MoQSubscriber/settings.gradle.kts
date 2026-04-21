pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        mavenLocal()
    }
}

// Reference the local moqkit library directly so this example always reflects
// the latest local changes without requiring a Maven publish step.
includeBuild("../../../../android/moqkit") {
    dependencySubstitution {
        substitute(module("com.swmansion.moqkit:moqkit")).using(project(":moqkit"))
    }
}

rootProject.name = "MoQ Subscriber"
include(":app")
 
