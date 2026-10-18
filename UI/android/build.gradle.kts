allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

/**
 * 统一所有模块的 NDK 版本。
 *
 * Flutter 工具链把默认值写死成 28.2，插件模块会各自带上它；
 * AGP 取所有模块里的最高版本，只在 app 模块里改不够。
 */
val horseboxNdkVersion = "27.2.12479018"

subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        try {
            android.javaClass
                .getMethod("setNdkVersion", String::class.java)
                .invoke(android, horseboxNdkVersion)
        } catch (_: ReflectiveOperationException) {
            // AGP 版本不同、没有这个 setter 时跳过。
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
