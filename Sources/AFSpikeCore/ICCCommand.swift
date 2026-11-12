import Foundation

/// `afspike icccmd`: send one arbitrary PTP command over ImageCaptureCore.
public final class ICCCommand {
    private let opcode: UInt16
    private let params: [UInt32]
    private let outData: Data?
    private let timeout: TimeInterval

    public init(opcode: UInt16, params: [UInt32], outData: Data? = nil,
                timeout: TimeInterval = 20) {
        self.opcode = opcode
        self.params = params
        self.outData = outData
        self.timeout = timeout
    }

    public func run() {
        let camera = ICCCamera()
        do {
            try camera.connect()
            let response = try camera.sendSync(opcode, params, outData: outData, timeout: timeout)
            let head = response.data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "op 0x%04X params=%@ data=%dB resp=0x%04X",
                         opcode, "\(params)", response.data.count, response.code))
            if !head.isEmpty { print("data: \(head)") }
        } catch {
            print("icc command failed: \(error)")
        }
        camera.close()
    }
}
