import Foundation
import WebKit

/// WKScriptMessageHandler that receives NAL payloads from the WebTransport JS client
/// and feeds them into the H264Decoder.
@MainActor
final class WebTransportBridge: NSObject, WKScriptMessageHandler {
    private let decoder: H264Decoder
    private(set) var isConnected = false
    private var frameCount = 0
    var onConnectionChanged: @MainActor (Bool) -> Void = { _ in }
    var onCommandResponse: @MainActor (String) -> Void = { _ in }
    weak var webView: WKWebView?

    init(decoder: H264Decoder) {
        self.decoder = decoder
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "frame":
            guard let b64 = message.body as? String,
                  let data = Data(base64Encoded: b64) else { return }
            frameCount += 1
            if frameCount <= 5 || frameCount % 30 == 0 {
                print("[bridge] frame #\(frameCount) size=\(data.count) header=\(data.first.map { String($0) } ?? "?")")
            }
            decoder.decode(payload: data)

        case "status":
            let status = message.body as? String ?? ""
            print("[WT] status:", status)
            let connected = status == "connected"
            if connected != isConnected {
                isConnected = connected
                onConnectionChanged(connected)
            }

        case "commandResponse":
            let json = message.body as? String ?? ""
            print("[WT] commandResponse:", json)
            onCommandResponse(json)

        default:
            break
        }
    }

    // MARK: - Commands

    /// Send a JSON command string via the JS bidi stream.
    func sendCommand(_ json: String) {
        let safe = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.sendCommand && window.sendCommand('\(safe)')")
    }
}
