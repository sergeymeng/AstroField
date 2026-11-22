# 从相机到屏幕

Nikon、模拟相机和照片回放都实现了 [CameraDevice](../Sources/AstroFieldKit/CameraDevice.swift)。SwiftUI 通过 [AppModel](../Sources/AstroField/AppModel.swift) 调用这些接口。可用的按钮取决于连接时得到的 `CameraCapability` 集合。Nikon 会尝试写回当前的快门、光圈和 ISO，分别确认机身是否接受这三项设置。

## 一张 LiveView 帧

[NikonCamera](../Sources/AstroFieldKit/NikonCamera.swift) 在 `ICCEngine` 的专用线程上串行收发 PTP 命令。线程运行 ImageCaptureCore 所需的 RunLoop。相机状态回调由 AppModel 切回主线程更新窗口。

机身返回的 JPEG 解码后放进 `LivePreview.image`，供星点检测和对焦使用。取景器另用 `displayImage` 显示灰度预览。[LiveViewStretch](../Sources/AstroFieldKit/LiveViewStretch.swift) 估算背景中位数和噪声，根据增益与黑场设置映射亮度。调亮预览时，检测器仍能比较同一尺度下的星点。

找星模式保存计划中的曝光设置，临时使用 ISO 12800。持续无星时，它把一次 2 秒 JPEG 曝光下载到临时目录，解码后删除。MFDrive 对焦时，[FocusSearcher](../Sources/AstroFieldKit/FocusEngine.swift) 可以在最亮星周围的小窗口里反复测量。普通对焦搜索先粗扫再细调，最后补拍一张验证帧。

## 一张序列照片

[SequenceRunner](../Sources/AstroFieldKit/SequenceRunner.swift) 按计划调度曝光，用异步事件报告拍摄进度。变更参数、暂停和停止都在两张照片之间生效。固定开拍间隔来不及时，按计划选择顺延或跳过。

曝光完成后，照片先进入素材列表，分析在后台逐张进行。[ImageLoader](../Sources/AstroFieldKit/ImageLoader.swift) 为测量生成浮点亮度图。NEF 可以由 Core Image 解码，也可以用 LibRaw 以 half-size 和线性 gamma 解码。LibRaw 路径按机身白电平换算亮度，自动曝光也按该尺度设定目标背景。

[DarkLibrary](../Sources/AstroFieldKit/DarkLibrary.swift) 从相同来源、相同 ISO 的主暗场中选择曝光时间相差不超过 10% 的候选，优先匹配图像尺寸。减暗后的亮度供预览、星点测量和叠加使用。主暗场以 Float32 像素保存在 `.darkbin` 文件中，JSON 索引记录各组拍摄参数。

[SessionStore](../Sources/AstroFieldKit/SessionExporter.swift) 为每帧写入 JSON，实拍 NEF 保留原路径，模拟帧存为 16 位 TIFF。保存任务先取得所需的亮度数据，旧帧随后可以从内存释放。质量规则在测量完成后评估，达到计划条件时可暂停序列。

[SessionStacker](../Sources/AstroFieldKit/SessionStacker.swift) 用第一张亮场作参考，按星点的平移量对齐后续帧并取平均。星点太少或偏移过大的帧会记入拒绝计数。固定机位的星轨预览走单独的 [StarTrailStacker](../Sources/AstroFieldKit/StarTrailStacker.swift)。

## USB 会话关闭时

关闭会话和拔出设备可能各触发一次通知。`NikonCamera` 将同一会话的两条通知合成一次掉线事件。AppModel 暂停序列，按 1、2、5、5、5 秒的间隔尝试重新发现设备、打开会话并恢复 remote mode。切换相机来源时会取消旧的重连任务。连接恢复后，应用重新开始取景，并尝试写回掉线时暂存的找星前设置。

「保持后台活跃」在 Nikon 连接期间通过 `ProcessInfo.beginActivity` 抑制 App Nap。机身断线和系统电源事件都带有日志，便于在显示器唤醒后核对时间。[Z7 II 拍摄记录](Z7II_APP_ACCEPTANCE.md)
