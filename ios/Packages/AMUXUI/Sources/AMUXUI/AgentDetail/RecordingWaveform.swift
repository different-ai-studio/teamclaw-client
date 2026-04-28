import SwiftUI

struct RecordingWaveform: View {
    /// 0...1 normalized current audio level.
    let level: Float
    /// Number of bars to render.
    var barCount: Int = 7

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.subheadline)
                .foregroundStyle(.red)
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 3, height: barHeight(for: i))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(height: 22, alignment: .center)
            Text("Recording…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .onAppear { pulse = true }
        .accessibilityLabel("Recording")
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Each bar gets a phase offset so the row feels like a wave even though
        // there is only one live level value coming in.
        let l = CGFloat(max(0, min(1, level)))
        let phase = CGFloat(index) / CGFloat(barCount)
        let offset = sin(phase * .pi * 2 + (pulse ? .pi : 0)) * 0.25
        let h = max(0.15, min(1.0, l + offset))
        return 6 + h * 16  // 6...22
    }
}

#Preview {
    VStack(spacing: 12) {
        RecordingWaveform(level: 0.1)
        RecordingWaveform(level: 0.5)
        RecordingWaveform(level: 0.9)
    }
    .padding()
}
