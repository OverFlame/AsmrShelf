allprojects {
    repositories {
        // 中国镜像优先，避免访问境外仓库超时
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
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
// 插件自带的 android 模块 compileSdk 可能偏旧（当初是 desktop_drop 写死 33，
// 该依赖已移除，这段留给后面再碰上的同类插件），而插件依赖的 androidx 组件
// 要求编译目标至少 34。AGP 9 只认 compileSdk 属性，
// 且插件自己的 build 脚本会在插件应用之后再赋一次值，所以要等它评估完再改。
// 这段必须放在 evaluationDependsOn 之前：那行会提前触发子项目评估。
subprojects {
    val bumpCompileSdk = {
        extensions.findByName("android")?.withGroovyBuilder { setProperty("compileSdk", 36) }
    }
    if (state.executed) bumpCompileSdk() else afterEvaluate { bumpCompileSdk() }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
