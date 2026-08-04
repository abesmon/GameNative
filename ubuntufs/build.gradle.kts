plugins {
    alias(libs.plugins.android.dynamic.feature)
    alias(libs.plugins.jetbrains.kotlin.android)
}
android {
    namespace = "app.ubuntufs"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
        // testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    flavorDimensions += "androidApi"
    productFlavors {
        create("legacy") {
            dimension = "androidApi"
        }
        create("legacyXr") {
            dimension = "androidApi"
        }
        create("modern") {
            dimension = "androidApi"
        }
        create("modernXr") {
            dimension = "androidApi"
        }
    }

    buildTypes {
        // Dynamic features have to declare every build type the base app declares.
        create("debugFast") {
            initWith(getByName("debug"))
            // Has to match the base app, which drops the flag to get release-like ART codegen.
            isDebuggable = false
        }
        create("release-signed") {
            initWith(getByName("release"))
        }
        create("release-gold") {
            initWith(getByName("release"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":app"))
    implementation(libs.androidx.core.ktx)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
