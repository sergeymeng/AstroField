# 开发说明

## 构建与测试

应用和 CLI 都是 Swift Package Manager 目标。基础构建使用 macOS 系统框架。构建时若检测到 LibRaw，还会启用线性 RAW 解码。

```bash
swift build
swift test
swift run AstroField
swift run afspike selftest
```

打包脚本会在 `dist/` 中重新生成 `AstroField.app`：

```bash
./scripts/build_app.sh release
```

## 应用图标

`assets/branding/logo.png` 保存品牌图，`assets/branding/app-icon.png` 是调整过边距的应用图标母版。
打包脚本会使用 macOS 自带的 `sips` 和 `iconutil` 生成 16–1024 像素的图标，写入
`Sources/AstroField/Resources/AppIcon.icns`，再复制到应用的 `Contents/Resources`。
`Info.plist` 的 `CFBundleIconFile` 指向该文件；`swift run AstroField` 通过 SwiftPM 资源加载同一图标。

单独更新图标时运行：

```bash
./scripts/build_icons.sh
```

修改母版后应一并提交 PNG 和重新生成的 ICNS。图标外侧透明，蓝黑色底板内部保持不透明。

## 照片回放与截图

可以从应用顶部菜单选择照片回放，也可以在启动时指定目录：

```bash
ASTROFIELD_PLAYBACK_DIR="/path/to/photos" swift run AstroField
```

以下环境变量用于本地演示和检查：

| 变量 | 用途 |
|---|---|
| `ASTROFIELD_DEMO` | `idle`、`exposing`、`waiting`、`focus`、`stack`、`analysis`、`corners`、`trial`、`compare`、`groups`、`trails`、`dark`、`fullchain`、`auto`、`autostack`、`findstar`、`findstarblack`、`findstarfocus` 等演示状态 |
| `ASTROFIELD_NIGHT=1` | 使用夜间主题 |
| `ASTROFIELD_WINDOW_SIZE` | 设置窗口大小，例如 `1180x760` |
| `ASTROFIELD_SHOT_PATH` | 将实际应用窗口保存为截图 |
| `ASTROFIELD_SHOT_DELAY` | 截图前等待的秒数 |
| `ASTROFIELD_SHOT_EXIT=1` | 保存截图后退出 |
| `ASTROFIELD_SESSION_ROOT` | 覆盖会话根目录（默认 `~/Pictures/AstroField`） |
| `ASTROFIELD_DARK_DIR` | 覆盖暗场库目录（默认 `~/Library/Application Support/AstroField/Darks`） |

`dark` 演示采集 2 帧暗场后试拍一张；`fullchain` 依次执行暗场采集、天空/地景分组、
自动对焦、叠加与报告导出；`auto` 在模拟器上跑星空自动曝光的闭环搜索；`autostack`
拍 3 张后自动对星叠加并导出 `auto-stack.tif/png`。`findstar` 进入找星模式并显示星点/
最亮星标记；`findstarblack` 用无星场景验证测试帧回退；`findstarfocus` 再执行一次单星
MFDrive 对焦。截图脚本会把演示会话与暗场库写到 `logs/demo-session` 与 `logs/demo-darks`。

```bash
swift build
./scripts/screenshot.sh
```

截图脚本需要可用的 macOS 图形会话。仓库中的图片来自模拟星空。

## ImageCaptureCore 诊断

应用中的 Nikon 连接使用 ImageCaptureCore / PTP，和可选的 MAID 后端分开。

```bash
./run.sh icc --seconds 3
./run.sh iccprops
```

不带参数运行 `swift run afspike` 可以查看完整命令列表。涉及曝光、相机模式和镜头移动的命令会操作真实设备，按具体测试需要执行。

App 内 ICC 会话诊断：

- 底部日志会记录 `ICC 会话断开：...`，原因来自 `ICCCameraDelegate`：`session closed`、
  `session closed with error: ...` 或 `device removed`。
- 显示/系统休眠与唤醒会写入日志，用于和断开时间对照。
- VIEWFINDER 的「保持后台活跃」阻止 App Nap；不阻止系统休眠。

## 可选的 LibRaw 线性解码

默认构建不依赖 LibRaw。安装了 Homebrew 的 LibRaw 后，`Package.swift` 会自动检测并编译
`Sources/CLibRaw`，`AstroFieldKit` 获得 `ASTROFIELD_LIBRAW` 定义：

```bash
brew install libraw
swift build
```

自定义安装位置：

```bash
export LIBRAW_PREFIX="/path/to/libraw"
swift build
```

没有找到头文件时会自动回退 Core Image 解码，应用仍可构建和运行。LibRaw 路径使用
half-size 解码、gamma 1、关闭相机矩阵和单位白平衡；输出亮度满量程是传感器白电平
（Z7 II 为 15311），Auto 的目标背景据此计算。LibRaw 为 LGPL/CDDL，分发前需处理
动态链接与许可。

## 可选的 Nikon MAID 后端

`Sources/CNikonMAID` 保留了 MAID C++ 桥接代码，用于 SDK 诊断。默认构建不编译它；设置 `NIKON_SDK_HEADERS` 后才加入构建。

SDK 需自行取得，并保存在仓库之外或被忽略的 `vendor/` 目录中。以下路径应替换成实际安装位置：

```bash
export NIKON_SDK_HEADERS="/path/to/sdk/Module/Mac/HeaderFile"
export NIKON_SDK_MODULE="/path/to/TypeCommon Module.bundle/Contents/MacOS/TypeCommon Module"
export NIKON_SDK_FRAMEWORKS="/path/to/TestApp/Frameworks"
./run.sh devices
```

`NIKON_SDK_HEADERS` 必须包含 `Maid3.h` 和配套头文件。`run.sh` 会将本地运行需要的框架放进构建目录，SDK 文件不会进入 Git。

取消可选后端：

```bash
unset NIKON_SDK_HEADERS
swift build
```

没有启用 SDK 时，`afspike` 的 MAID 命令会报告缺少可选后端；模拟分析和 `icc*` 命令仍可使用。

## 测试与硬件记录

单元测试覆盖调度、模拟星场、对焦搜索、显示拉伸、会话关闭回调与重试间隔。真机操作步骤和实测结果见 [Z7 II 验收记录](Z7II_APP_ACCEPTANCE.md)。

报告硬件问题时，请附上机身型号、固件版本、镜头、复现步骤及对应时间的错误日志。
