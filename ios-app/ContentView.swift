import SwiftUI
import Combine

@MainActor
final class StreamViewModel: ObservableObject {
    let displayLayer: VideoDisplayLayer
    let decoder: H264Decoder
    let bridge: WebTransportBridge
    @Published var isConnected = false
    @Published var lastResponse = ""

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
        br.onCommandResponse = { [weak self] json in
            self?.lastResponse = json
            // Auto-dismiss after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.lastResponse == json {
                    self?.lastResponse = ""
                }
            }
        }
    }

    func sendCommand(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        bridge.sendCommand(json)
    }
}

struct ContentView: View {
    @StateObject private var model = StreamViewModel()
    @State private var showCommands = false

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

                // Response toast
                if !model.lastResponse.isEmpty {
                    Text(model.lastResponse)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                // Command panel (slide-up)
                if showCommands {
                    CommandPanel(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Toggle button
                Button {
                    withAnimation(.spring()) { showCommands.toggle() }
                } label: {
                    Image(systemName: showCommands ? "chevron.down.circle.fill" : "slider.horizontal.3")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(12)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .padding(.bottom, 16)
            }
        }
    }
}

struct DPadButton: View {
    let direction: String
    let systemImage: String
    let model: StreamViewModel
    @GestureState private var isPressed = false

    var body: some View {
        let drag = DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, state, _ in state = true }

        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: 52, height: 52)
            .background(isPressed ? Color.orange.opacity(0.8) : Color.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundColor(.white)
            .gesture(drag)
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    model.sendCommand(["cmd": "move_start", "dir": direction])
                } else {
                    model.sendCommand(["cmd": "move_stop"])
                }
            }
    }
}

struct DPad: View {
    let model: StreamViewModel

    var body: some View {
        VStack(spacing: 4) {
            DPadButton(direction: "up",    systemImage: "arrowtriangle.up.fill",    model: model)
            HStack(spacing: 4) {
                DPadButton(direction: "left",  systemImage: "arrowtriangle.left.fill",  model: model)
                Color.clear.frame(width: 52, height: 52)
                DPadButton(direction: "right", systemImage: "arrowtriangle.right.fill", model: model)
            }
            DPadButton(direction: "down",  systemImage: "arrowtriangle.down.fill",  model: model)
        }
    }
}

struct CommandPanel: View {
    let model: StreamViewModel
    @State private var selectedBitrate: Int? = nil

    private let bitrateOptions = [500, 1000, 2000, 4000]

    var body: some View {
        VStack(spacing: 12) {
            // D-pad for toy control
            DPad(model: model)

            // Force keyframe button
            Button {
                model.sendCommand(["cmd": "force_keyframe"])
            } label: {
                Label("Force Keyframe", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Bitrate selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Bitrate")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                HStack(spacing: 8) {
                    ForEach(bitrateOptions, id: \.self) { kbps in
                        Button {
                            selectedBitrate = kbps
                            model.sendCommand(["cmd": "set_bitrate", "kbps": kbps])
                        } label: {
                            Text(kbps < 1000 ? "\(kbps)" : "\(kbps / 1000)k")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(selectedBitrate == kbps ? Color.orange : Color.white.opacity(0.15))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
