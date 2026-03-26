import SwiftUI
import AVFoundation

/// UIView subclass hosting an AVSampleBufferDisplayLayer.
@MainActor
final class VideoDisplayLayer: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        // For live streaming the PTS is a monotonic counter starting at 0, which the
        // display layer interprets as "far in the past" relative to the host clock and
        // silently drops every frame. Setting DisplayImmediately bypasses PTS scheduling
        // and renders the buffer as soon as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        displayLayer.enqueue(sampleBuffer)
        print("[renderer] enqueued frame, layer status:", displayLayer.status.rawValue)
    }
}

/// SwiftUI wrapper for VideoDisplayLayer.
struct StreamRenderer: UIViewRepresentable {
    let displayView: VideoDisplayLayer

    func makeUIView(context: Context) -> VideoDisplayLayer { displayView }
    func updateUIView(_ uiView: VideoDisplayLayer, context: Context) {}
}
