import SwiftUI
import WebKit

/// A hidden UIViewRepresentable that hosts a WKWebView running the WebTransport JS client.
struct WebTransportView: UIViewRepresentable {
    let bridge: WebTransportBridge

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(bridge, name: "frame")
        contentController.add(bridge, name: "status")
        contentController.add(bridge, name: "commandResponse")

        // No WKUserScript injection: ENABLE_USER_SCRIPT_SANDBOXING=YES isolates injected
        // scripts into a separate JS world, so window.* values set there are invisible to
        // the page's own script. We bake the values directly into the HTML string instead.

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        bridge.webView = webView

        // loadHTMLString avoids the on-device "Could not create a sandbox extension" error
        // that loadFileURL triggers. baseURL makes the page a secure HTTPS origin so the
        // WebTransport JS API is available.
        let html = Self.buildHTML(relayURL: Configuration.relayURL)
        webView.loadHTMLString(html, baseURL: URL(string: "https://ruh.sunbour.com"))

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - HTML

    /// Builds the HTML page with the relay URL baked in as a JS literal.
    private static func buildHTML(relayURL: String) -> String {
        let urlJSON = jsonString(relayURL)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head><body><script>
        (async function() {
          const RELAY_URL = \(urlJSON);

          function toB64(bytes) {
            let s = '';
            for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
            return btoa(s);
          }

          for (;;) {
            try {
              const wt = new WebTransport(RELAY_URL);
              await wt.ready;
              webkit.messageHandlers.status.postMessage('connected');

              // Accept the bidi command stream opened by the relay (server-initiated).
              let cmdWriter = null;
              try {
                const bidiReader = wt.incomingBidirectionalStreams.getReader();
                const { value: bidi, done: bidiDone } = await bidiReader.read();
                if (bidiDone || !bidi) throw new Error('No bidi stream from relay');
                cmdWriter = bidi.writable.getWriter();
                window.sendCommand = async function(jsonStr) {
                  const enc = new TextEncoder().encode(jsonStr);
                  const buf = new Uint8Array(4 + enc.length);
                  new DataView(buf.buffer).setUint32(0, enc.length, false);
                  buf.set(enc, 4);
                  await cmdWriter.write(buf);
                };
                // Read responses from relay in background.
                (async () => {
                  const rdr = bidi.readable.getReader();
                  let pend = new Uint8Array(0);
                  async function readNR(n) {
                    while (pend.byteLength < n) {
                      const { value, done } = await rdr.read();
                      if (done) return null;
                      const m = new Uint8Array(pend.byteLength + value.byteLength);
                      m.set(pend); m.set(value, pend.byteLength);
                      pend = m;
                    }
                    const out = pend.slice(0, n);
                    pend = pend.slice(n);
                    return out;
                  }
                  for (;;) {
                    const lb = await readNR(4); if (!lb) break;
                    const len = (lb[0]<<24)|(lb[1]<<16)|(lb[2]<<8)|lb[3];
                    const rb = await readNR(len); if (!rb) break;
                    webkit.messageHandlers.commandResponse.postMessage(
                      new TextDecoder().decode(rb)
                    );
                  }
                })();
              } catch (bidiErr) {
                console.warn('Bidi command stream unavailable:', bidiErr);
              }

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
