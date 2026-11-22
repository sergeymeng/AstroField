# AstroField 架构

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

`Set<CameraCapability>` 决定界面中可用的操作。Nikon 在连接时写回 ISO、光圈和快门的当前值，将探测成功的项目加入能力集合。

## 线程模型

- SwiftUI 状态在 `@MainActor` 的 `AppModel`。
- `SimulatorCamera` / `PlaybackCamera`：普通类 + 锁，async 方法在通用执行器运行。
- `NikonCamera`：`ICCEngine` 专用线程，负责 `ICCCamera` 的 RunLoop 泵；
  `perform` 用 continuation 把同步相机调用桥接成 async；所有 ICC 调用串行化。
- 相机状态回调可能来自任意队列，`AppModel` 统一切回 MainActor。

## 图像与测量

- `LumaImage`：16 位解码亮度（`[Float]`），测量输入。
- 显示拉伸、白平衡、直方图只作用于显示用的 `CGImage`，不修改 `LumaImage`。
- LiveView 的显示与测量分离：`LivePreview.image` 是测量帧（Nikon 为相机 JPEG 原始解码），
  `LivePreview.displayImage` 是 `LiveViewStretch` 生成的显示图。取景增益/黑场只改显示图。
- `ImageRecord`：序列号、来源、文件 URL、拍摄设置、尺寸、预览、星点保留缩略图、
  分析亮度（可为空以限制内存）、指标、质量结论、备注。
- `FrameAnalyzer`：交互用快速指标（采样背景 + `StarDetector`）。
- `StarAnalyzer`（AFSpikeCore）：CLI/测试用的全图 BFS 分析。
- `StarDetector`：全图星点列表；`measureFast` 专供对焦的局部极大值测量。
- RAW：默认 Core Image `CIRAWFilter` 解码；可选 LibRaw 线性解码（`CLibRaw` C++ shim，
  half_size、gamma 1、关闭相机矩阵与单位白平衡）。LibRaw 路径的亮度满量程是传感器
  白电平（Z7 II 15311），暗场与 Auto 的目标背景按此计算。两者都不是未处理的 CFA 数据；
  LibRaw 更接近线性，但仍是去马赛克后的 RGB。

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

## 暗场校准

- `DarkAccumulator`：逐帧 Double 累加，拒绝尺寸或曝光参数不一致的帧；`build` 输出均值
  master 与统计（均值、检出热像素数）。
- `DarkLibrary`：索引 JSON + 每个 master 一个 `.darkbin`（magic、宽高、Float32 像素；
  load 校验 magic/版本/字节数/宽高）；单条像素缓存；目录可由 `ASTROFIELD_DARK_DIR` 覆盖。
- 匹配：ISO 严格相等、曝光相对差 ≤ 10%、来源一致、同尺寸优先，其余情况回退到最近的
  同来源候选；不跨来源静默套用。
- 注入点：分析链在 `FrameAnalyzer.metrics` 之前减暗；减暗后的亮度写回记录并重建预览、
  缩略图；叠加使用减暗后的亮度。减暗不修改任何文件。
- 模拟器：`lensCovered` 时无星点、无光污染，只保留偏置/暗电流与固定单像素热像素；
  热像素位置只依赖场景种子，正常帧与盖盖帧一致。

## 会话与导出

- `SessionStore`：每个序列/分组新建时间戳目录；模拟帧写 16-bit 灰度 TIFF，边车 JSON
  （帧 ID、角色、参数、指标、质量结论、分组、是否减暗）；真实 NEF/回放只写边车并记录
  原路径。
- 所有文件 IO 在一个串行队列上执行，JSON/CSV 用原子写；写失败只告警，不打断拍摄。
- `SessionReport`：CSV 逐帧、JSON 含 summary；叠加/星轨成片从 `LumaImage` 导出
  TIFF + PNG，预览上限 1000 px。
- AppModel 在 `addRecord` 时立即快照亮度，避免后续 `pruneLuma` 导致丢帧。

## 自动重连与找星模式

- `NikonCamera: ICCCameraDelegate`：会话关闭或设备移除只上报一次 `onSessionLost(reason)`，
  保留能力集合；`reconnect()` 重建 browser/session/remote mode，跳过能力探测。
- `ReconnectPolicy`：1/2/5/5/5 秒，最多 5 次；`CameraState.reconnecting`/`recovered`
  驱动状态栏与监看重连层。重连任务由 `AppModel` 单实例管理，旧任务按 generation 作废。
- 找星模式：保存计划设置，临时写 ISO 12800；LiveView 分析输出星点与最亮星；MFDrive
  可在单星窗口执行 `FocusSearcher(minStars: 1)`。LiveView 无星时自动拍一张临时 JPEG
  测试帧，解码后删除，不进会话。退出恢复原设置；断开期间记入 `pendingRestore`。
- 「保持后台活跃」通过 `ProcessInfo.beginActivity` 阻止 App Nap，避免显示休眠后取景
  轮询被节流；系统休眠仍可能发生，由重连恢复。
