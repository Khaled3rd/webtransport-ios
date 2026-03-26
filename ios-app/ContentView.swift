import SwiftUI
import Combine

@MainActor
final class StreamViewModel: ObservableObject {
    let displayLayer: VideoDisplayLayer
    let decoder: H264Decoder
    let bridge: WebTransportBridge
    @Published var isConnected = false

    init() {
        let layer = VideoDisplayLayer(frame: .zero)
        let dec = H264Decoder()
        let br = WebTransportBridge(decoder: dec)

        displayLayer = layer
        decoder = dec
        bridge = br

        dec.onSampleBuffer = { [layer] sb in
            layer.enqueue(sb)
        }
        br.onConnectionChanged = { [weak self] connected in
            self?.isConnected = connected
        }
    }
}

struct ContentView: View {
    @StateObject private var model = StreamViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StreamRenderer(displayView: model.displayLayer)
                .ignoresSafeArea()

            // Hidden 1×1 web view keeps the JS client alive.
            WebTransportView(bridge: model.bridge)
                .frame(width: 1, height: 1)
                .opacity(0)

            VStack {
                HStack {
                    Spacer()
                    if model.isConnected {
                        LiveBadge()
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}

struct LiveBadge: View {
    @State private var dimmed = false

    var body: some View {
        Text("● LIVE")
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(dimmed ? 0.4 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}
