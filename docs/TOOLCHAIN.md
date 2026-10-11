# M0 固定工具链

用户于 2026-10-11 确认 Flutter 3.47.5 与 Dart 3 兼容升级路线。版本由 `scripts/toolchain.json` 维护；当前 Flutter 3.47.5 / Dart 3.13.4 / JDK 21.0.12.1 / Gradle 9.3.1 / AGP 9.1.0 / Kotlin 2.4.0，App 编译 API 36，插件另需 API 35，CMake 3.22.1，NDK 28.2.13676358。Gradle 分发按官方校验值固定，Dart 直接及传递依赖提交 `pubspec.lock`。

首次 SDK 安装使用 `scripts/install-flutter.ps1`，从官方固定 tag 获取并引导 SDK；已有目录拒绝覆盖。JDK、Android SDK 由 `use-dev-env.ps1` 参数或 COUNT_TOOLS 环境变量指定。默认 JDK 复用本机已安装的公共运行时，不读取或借用其他项目签名。脚本只修改当前进程环境，不全局切换 SDK。

已有 Android 构建环境可以复用 JDK、SDK 平台和构建工具。Flutter 项目另需其固定的 Flutter/Dart、Gradle、Android 插件和 NDK；这些首次下载到项目独立缓存，后续重复构建复用缓存。“初始化”不代表重装整个 Android 环境。

NDK 固定为 Flutter 3.47.5 要求的 28.2.13676358（r28c）。本机新版 Android CLI 的旧 sdkmanager 兼容入口无法安装该版本，因此使用 [Android 官方归档](https://github.com/android/ndk/wiki/Unsupported-Downloads) 的 Windows ZIP。下载完整后执行 `scripts/install-pinned-ndk.ps1 -Archive '<仓库外归档路径>'`，先核对官方大小与校验值，再安装到 SDK 的独立版本目录；不覆盖已有版本或调整其他项目配置。归档及解压缓存不进入 Git。

本轮最终采用 CountTools 缓存中的独立 Android SDK：`scripts/prepare-android-sdk.ps1` 从已有 SDK 复制平台、build-tools、platform-tools、licenses、cmdline-tools，NDK 加入该副本。环境脚本优先使用这个目录；也可以显式传入 SDK 路径。已有平台和工具无需重新下载，SalaryFlow 仍使用原来的 SDK。第三方插件要求其他 compileSdk 时，其平台由构建工具加到副本中，不降低 App 的 API 36 编译目标。

```powershell
./scripts/use-dev-env.ps1 -Inspect
./scripts/test-local.ps1 -Python python -Baseline HEAD
./scripts/build-personal-android.ps1 -VersionName 0.0.0-m0.1 -VersionCode 11000 -SigningProperties '<仓库外配置路径>'
```

示例候选号仅说明参数，已用过的 code 不可再次使用。实际候选台账在忽略的 `local-artifacts/android`。需要网络代理时在当前进程配置 HTTPS_PROXY；Gradle 的代理配置放独立 GRADLE_USER_HOME，不能提交凭据。Android Maven 沿用原工程的国内镜像方案，限定 Google 镜像组并保留官方仓库。

Windows 未启用开发者模式时，Flutter 会因其他桌面平台插件符号链接失败。`prepare-local-workspace.ps1` 将 Android、lib、test、assets 和锁文件复制到带项目归属标记的仓库外工作目录，仅替换这些副本。Flutter 分析、测试、构建在该目录运行；不会删仓库平台源码，也不需要改系统开发者模式。不要并发运行会重建同一工作目录的脚本。

AGP 9 使用内置 Kotlin，但 Flutter 3.47.5 的 Gradle 插件仍依赖旧 DSL，因此 `android.builtInKotlin=true`、`android.newDsl=false`。旧日期依赖替换为 Flutter 日历；过时 charts_flutter 替换为原生饼图，保留原有数量、颜色与图例。上游网络更新入口已移除，作者与来源许可保留。蓝粉 Cheki 业务 UI 从 M1 开始。

来源：[Flutter 官方安装](https://docs.flutter.dev/install/manual)、[内置 Kotlin 迁移](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)。安装、配置、分析/测试、构建、签名、设备与阶段验收须分别记录。
