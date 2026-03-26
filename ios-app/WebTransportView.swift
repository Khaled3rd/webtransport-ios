import SwiftUI
import WebKit

/// A hidden UIViewRepresentable that hosts a WKWebView running the WebTransport JS client.
struct WebTransportView: UIViewRepresentable {
    let bridge: WebTransportBridge

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(bridge, name: "frame")
        contentController.add(bridge, name: "status")

        // No WKUserScript injection: ENABLE_USER_SCRIPT_SANDBOXING=YES isolates injected
        // scripts into a separate JS world, so window.* values set there are invisible to
        // the page's own script. We bake the values directly into the HTML string instead.

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)

        // loadHTMLString avoids the on-device "Could not create a sandbox extension" error
        // that loadFileURL triggers. baseURL makes the page a secure HTTPS origin so the
        // WebTransport JS API is available.
        let html = Self.buildHTML(
            relayURL: Configuration.relayURL,
            fingerprint: Configuration.certFingerprint
        )
        webView.loadHTMLString(html, baseURL: URL(string: "https://ruh.sunbour.com"))

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - HTML

    /// Builds the HTML page with the relay URL and cert fingerprint baked in as JS literals.
    private static func buildHTML(relayURL: String, fingerprint: String) -> String {
        // JSON-encode the strings so any special characters are safely escaped.
        let urlJSON = jsonString(relayURL)
        let fpJSON  = jsonString(fingerprint)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head><body><script>
        (async function() {
          const RELAY_URL = \(urlJSON);
          const FP_HEX   = \(fpJSON);
          const fpBytes  = new Uint8Array(FP_HEX.split(':').map(h => parseInt(h, 16)));

          function toB64(bytes) {
            let s = '';
            for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
            return btoa(s);
          }

          for (;;) {
            try {
              const wt = new WebTransport(RELAY_URL, {
                serverCertificateHashes: [{ algorithm: 'sha-256', value: fpBytes }]
              });
              await wt.ready;
              webkit.messageHandlers.status.postMessage('connected');

              // Relay opens exactly one persistent uni stream per subscriber.
              // Frames are length-prefixed: [4B length BE][1B flags][Annex-B NALs].
              const streamReader = wt.incomingUnidirectionalStreams.getReader();
              const { value: stream, done: sd } = await streamReader.read();
              if (sd || !stream) {
                webkit.messageHandlers.status.postMessage('disconnected');
                await new Promise(r => setTimeout(r, 2000));
                continue;
              }

              const r = stream.getReader();
              let pending = new Uint8Array(0);

              async function readN(n) {
                while (pending.byteLength < n) {
                  const { value, done } = await r.read();
                  if (done) return null;
                  const m = new Uint8Array(pending.byteLength + value.byteLength);
                  m.set(pending); m.set(value, pending.byteLength);
                  pending = m;
                }
                const out = pending.slice(0, n);
                pending = pending.slice(n);
                return out;
              }

              for (;;) {
                const lb = await readN(4);
                if (!lb) break;
                const len = (lb[0] << 24) | (lb[1] << 16) | (lb[2] << 8) | lb[3];
                const fb = await readN(len);
                if (!fb) break;
                webkit.messageHandlers.frame.postMessage(toB64(fb));
              }
              webkit.messageHandlers.status.postMessage('disconnected');
            } catch (e) {
              webkit.messageHandlers.status.postMessage('error: ' + e.message);
            }
            await new Promise(r => setTimeout(r, 2000));
          }
        })();
        </script></body></html>
        """
    }

    private static func jsonString(_ s: String) -> String {
        // Wrap in an array so JSONSerialization accepts it, then strip the brackets.
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let result = String(data: data, encoding: .utf8),
           result.hasPrefix("["), result.hasSuffix("]") {
            return String(result.dropFirst().dropLast())
        }
        // Fallback: manual escape (safe for URLs and colon-hex fingerprints).
        return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
