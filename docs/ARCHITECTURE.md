# AstroField 架构

版本：2026-11-12

## 目标

同一套拍摄计划、状态机、图像分析和界面逻辑，驱动三种来源：

1. 真实 Nikon（USB / ImageCaptureCore PTP）。
2. 模拟相机（可控、可复现）。
3. 真实照片回放（NEF/JPEG 文件）。

## 分层

```
AstroField (SwiftUI)
   │  界面、状态展示、用户操作
AstroFieldKit
   │  CameraDevice、Simulator、Playback、调度、分析、对焦、质量、叠加
AFSpikeCore
   │  PTP 协议层、ICCCamera、星点分析、CSV、Nikon SDK 备选
CNikonMAID（设置 NIKON_SDK_HEADERS 时编译）
       Nikon Remote Module SDK 的 C++ shim（备选后端）
```

## 相机抽象

默认构建不依赖 Nikon SDK。MAID 后端的本地配置见 [开发说明](DEVELOPMENT.md)。

`CameraDevice` 协议：

- `connect` / `disconnect`
- `status`（状态、型号、能力集合、备注）
- `apply(ExposureSettings)`
- `capture(sequence:) async throws -> ImageRecord`
- `startLiveView` / `stopLiveView` / `livePreview`
- `focusDrive(direction:steps:)`

能力查询必须诚实：`Set<CameraCapability>` 只包含实际可用的能力。模拟与回放不会伪报
镜头动作；Nikon 在连接时通过写回当前值探测 ISO/光圈/快门能力，探测失败则不加能力。

## 线程模型

- SwiftUI 状态在 `@MainActor` 的 `AppModel`。
- `SimulatorCamera` / `PlaybackCamera`：普通类 + 锁，async 方法在通用执行器运行。
- `NikonCamera`：`ICCEngine` 专用线程，负责 `ICCCamera` 的 RunLoop 泵；
  `perform` 用 continuation 把同步相机调用桥接成 async；所有 ICC 调用串行化。
- 相机状态回调可能来自任意队列，`AppModel` 统一切回 MainActor。

## 图像与测量

- `LumaImage`：16 位解码亮度（`[Float]`），测量输入。
- 显示拉伸、白平衡、直方图只作用于显示用的 `CGImage`，不修改 `LumaImage`。
- `ImageRecord`：序列号、来源、文件 URL、拍摄设置、尺寸、预览、星点保留缩略图、
  分析亮度（可为空以限制内存）、指标、质量结论、备注。
- `FrameAnalyzer`：交互用快速指标（采样背景 + `StarDetector`）。
- `StarAnalyzer`（AFSpikeCore）：CLI/测试用的全图 BFS 分析。
- `StarDetector`：全图星点列表；`measureFast` 专供对焦的局部极大值测量。
- RAW：Core Image `CIRAWFilter` 解码；不是传感器原始数据，界面和文档均如此标注。

## 拍摄计划与调度

- `CapturePlan`：纯数据，Codable；开始/间隔/结束/策略/曝光渐变。
- `ScheduleCalculator`：纯函数，理论排程与预检，虚拟时间测试的目标。
- `SequenceRunner`：actor；AsyncStream 事件（progress/captured/failed/finished）。
  - 固定开始间隔支持顺延/跳过；
  - 暂停=拍完当前张；停止=停止调度（当前曝光完成）；
  - 失败计数独立；参数变更在帧间应用。
- `SequenceClock`：真实时钟与测试时钟；排程数学由纯函数覆盖。

## 分析管线

- 捕获后立即加入素材列表。
- 分析使用串行后台链（一次一张），不阻塞拍摄；旧帧的分析亮度会被裁剪以限制内存。
- 叠加独立于分析链，在捕获后立即进入自己的队列。
- 质量规则在分析完成后更新；达到合格张数或异常时暂停序列。

## 对焦

- `FocusSearcher` actor：粗搜 → 细调 → 重复验证；不假设绝对位置或固定步长。
- `FocusProbe`：测量/移动两个动作；模拟器与真实相机各自实现。
- 测量优先使用 LiveView 亮度（快速、无下载），最终按拍摄参数补拍一张验证。
- 无证据（星点不足、曲线平坦、改善低于阈值）返回「尚未确认」。

## 叠加

- `LiveStacker`：参考帧 + 星点质心偏移直方图估计平移；整数像素平移后平均；
  记录每像素覆盖数；拒绝帧保留并给出原因。
- 只处理平移；旋转、视差、移动前景、复杂地景不处理，界面明确说明。

## 明确不做/未做

- 传感器温度读取（没有接口，界面不显示）。
- 自动转动相机（普通三脚架）。
- 未验证的镜头故障诊断。
- 生成式星空作为定量真值。
- 星图解析、全景、旋转对齐（S10 D/E 未实现）。
