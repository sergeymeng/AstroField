# 本地开发

仓库里有两个 SwiftPM 可执行目标。`AstroField` 打开 SwiftUI 窗口，`afspike` 可以从终端检查 USB 连接、读取机身属性，或用模拟星点测试图像分析。

```sh
swift run AstroField
swift test
swift run afspike selftest
```

`./scripts/build_app.sh` 在 `dist/` 生成带本地临时签名的 Release 应用。打包时，`scripts/build_icons.sh` 从 `assets/branding/app-icon.png` 生成 ICNS。修改图标时可单独运行这个脚本，同时提交 PNG 和生成的 `Sources/AstroField/Resources/AppIcon.icns`。

发布包使用 `./scripts/build_app.sh release --universal` 构建。它合并 arm64 和 x86_64 两个架构，使用系统的 Core Image 解码 NEF。常规源码构建仍可启用 LibRaw。

## 重现一个取景画面

查看找星标记用 `findstar`，检查无星时的 2 秒试拍用 `findstarblack`，测试模拟镜头对焦用 `findstarfocus`。例如，在终端运行：

```sh
ASTROFIELD_DEMO=findstarblack swift run AstroField
```

要回放自己的照片，设置 `ASTROFIELD_PLAYBACK_DIR` 指向照片目录。要重拍仓库里的整组截图，在登录 macOS 图形桌面后运行：

```sh
swift build
./scripts/screenshot.sh
```

[截图脚本](../scripts/screenshot.sh) 列出了各个场景及等待时间，包含暗场采集、自动曝光和叠加。它把会话和暗场分别存到 `logs/demo-session` 与 `logs/demo-darks`。手动复现时可以用以下变量控制窗口和输出。

| 变量 | 用途 |
| --- | --- |
| `ASTROFIELD_NIGHT=1` | 切到夜间主题 |
| `ASTROFIELD_WINDOW_SIZE` | 窗口尺寸，例如 `1180x760` |
| `ASTROFIELD_SHOT_PATH`、`ASTROFIELD_SHOT_DELAY` | 截图路径与启动后等待的秒数 |
| `ASTROFIELD_SHOT_EXIT=1` | 保存截图后退出 |
| `ASTROFIELD_SESSION_ROOT` | 会话目录，默认在 `~/Pictures/AstroField` |
| `ASTROFIELD_DARK_DIR` | 暗场目录，默认在 `~/Library/Application Support/AstroField/Darks` |

## Nikon 连不上时

在应用中断开相机，再运行这两条命令。第一条用 ImageCaptureCore 枚举设备，第二条读取相机属性。

```sh
./run.sh icc --seconds 3
./run.sh iccprops
```

如果连接在取景途中断开，先看窗口底部日志的时间和原因。`device removed` 表示设备从枚举中消失，`session closed` 表示会话关闭。一起记下机身、固件和镜头，尤其是当时显示器或系统是否刚刚唤醒。[Z7 II 的掉线记录和复测步骤](Z7II_APP_ACCEPTANCE.md)

## 用 LibRaw 读 NEF

默认解码器是 Core Image。要使用 LibRaw 的线性亮度做星点测量和暗场校准，安装 LibRaw，再重新构建。指定 Homebrew 前缀也适用于非默认安装位置。

```sh
brew install libraw
LIBRAW_PREFIX="$(brew --prefix libraw)" swift build
```

构建脚本默认在 `/opt/homebrew/opt/libraw` 下查找头文件。使用其他路径时，在运行测试和打包时也设置 `LIBRAW_PREFIX`。解码采用 half-size、单位白平衡和线性 gamma。曝光计算使用传感器白电平作为满量程。启用这条路径的构建会动态链接 LibRaw（LGPL/CDDL）。

## 用 Nikon SDK 调试 MAID

应用的 USB 后端使用 ImageCaptureCore。要调试 CLI 的 MAID 后端，将下面三个变量指向本地 SDK 的头文件、模块和框架目录。

```sh
export NIKON_SDK_HEADERS="/path/to/sdk/Module/Mac/HeaderFile"
export NIKON_SDK_MODULE="/path/to/TypeCommon Module.bundle/Contents/MacOS/TypeCommon Module"
export NIKON_SDK_FRAMEWORKS="/path/to/TestApp/Frameworks"
./run.sh devices
```

`NIKON_SDK_HEADERS` 应包含 `Maid3.h`。`run.sh` 将运行所需的框架复制到构建目录。要切回常规构建，执行 `unset NIKON_SDK_HEADERS` 后再运行 `swift build`。
