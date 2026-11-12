import Foundation

/// `afspike icc`: enumerate the camera and print a status snapshot plus one live-view frame.
public final class ICCProbe {
    public init() {}

    public func start(timeout: TimeInterval) {
        let camera = ICCCamera()
        camera.log = { print("icc: \($0)") }
        do {
            try camera.start(timeout: timeout)
            try camera.openSession(timeout: 10)
            print("camera: \(camera.deviceName ?? "?")")
            let s = camera.snapshot()
            print("battery: \(s.batteryLevel.map { "\($0)%" } ?? "<unavailable>")")
            print("compression: \(s.compression.map { "\($0)" } ?? "<unavailable>")")
            print("exposure_program: \(s.exposureProgram.map { "\($0)" } ?? "<unavailable>")")
            print("exposure_time: \(s.exposureTime.map { "\($0)" } ?? "<unavailable>")")
            print("f_number: \(s.fNumber.map { "\($0)" } ?? "<unavailable>")")
            print("iso: \(s.exposureIndex.map { "\($0)" } ?? "<unavailable>")")
            print("liveview_prohibit: \(s.liveViewProhibit.map { "\($0)" } ?? "<unavailable>")")
            print("liveview_size: \(s.liveViewImageSize.map { "\($0)" } ?? "<unavailable>")")
            print("liveview_status: \(s.cameraLiveViewStatus.map { "\($0)" } ?? "<unavailable>")")
            print("monitor_off: \(s.monitorOffStatus.map { "\($0)" } ?? "<unavailable>")")

            try camera.startLiveView()
            let frame = try camera.fetchLiveViewFrame(timeout: 10)
            print("live view frame: \(frame.width)x\(frame.height) jpeg=\(frame.jpeg.count)B header=\(frame.headerSize)B")
            try? camera.endLiveView()
        } catch {
            print("icc probe failed: \(error)")
        }
        camera.close()
    }
}
