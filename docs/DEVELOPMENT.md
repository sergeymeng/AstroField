# 开发说明

## 构建与测试

应用和 CLI 都是 Swift Package Manager 目标。默认构建只使用 macOS 系统框架，不需要 Nikon SDK。

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

## 照片回放与截图

可以从应用顶部菜单选择照片回放，也可以在启动时指定目录：

```bash
ASTROFIELD_PLAYBACK_DIR="/path/to/photos" swift run AstroField
```

以下环境变量用于本地演示和检查：

| 变量 | 用途 |
|---|---|
| `ASTROFIELD_DEMO` | `idle`、`exposing`、`waiting`、`focus`、`stack`、`analysis`、`corners`、`trial`、`compare`、`groups`、`trails` 等演示状态 |
| `ASTROFIELD_NIGHT=1` | 使用夜间主题 |
| `ASTROFIELD_WINDOW_SIZE` | 设置窗口大小，例如 `1180x760` |
| `ASTROFIELD_SHOT_PATH` | 将实际应用窗口保存为截图 |
| `ASTROFIELD_SHOT_DELAY` | 截图前等待的秒数 |
| `ASTROFIELD_SHOT_EXIT=1` | 保存截图后退出 |

```bash
swift build
./scripts/screenshot.sh
```

截图脚本需要可用的 macOS 图形会话。仓库中的图片来自模拟星空；其余检查图片和实拍素材保留在本机。

## ImageCaptureCore 诊断

应用中的 Nikon 连接使用 ImageCaptureCore / PTP，和可选的 MAID 后端分开。

```bash
./run.sh icc --seconds 3
./run.sh iccprops
```

不带参数运行 `swift run afspike` 可以查看完整命令列表。涉及曝光、相机模式和镜头移动的命令会操作真实设备，按具体测试需要执行。

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

## 验证范围

单元测试覆盖调度、模拟星场、对焦搜索、质量规则、预设和图像处理。它们不代表真实机身、镜头或夜空环境已经通过验收。

硬件问题请记录机身、固件、镜头、所执行操作和错误文本。原始 NEF 与设备日志保存在本地；分享前按需要选择相关材料。
