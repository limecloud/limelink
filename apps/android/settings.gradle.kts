pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = "LimeLink"
include(":core", ":app", ":iotCore")
project(":iotCore").projectDir = file("../../.dev/upstream/apps/android/core")
