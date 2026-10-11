allprojects {
    repositories {
        maven("https://maven.aliyun.com/repository/google") {
            content { includeGroupByRegex("com\\.android(\\..*)?"); includeGroupByRegex("androidx(\\..*)?") }
        }
        google(); mavenCentral()
    }
}
val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)
subprojects {
    layout.buildDirectory.value(newBuildDir.dir(project.name))
    evaluationDependsOn(":app")
}
tasks.register<Delete>("clean") { delete(rootProject.layout.buildDirectory) }
