plugins {
    kotlin("multiplatform") version "2.4.0"
}

repositories {
    mavenCentral()
}

kotlin {
    jvm()
    mingwX64 {
        binaries {
            sharedLib {
                baseName = "horsebox-ime-engine"
            }
        }
    }
}
