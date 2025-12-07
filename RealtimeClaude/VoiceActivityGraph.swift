import SwiftUI

struct VoiceActivityGraph: View {
    let segments: [TranscriptionSegment]

    var body: some View {
        if !segments.isEmpty {
            BarVisualization(segments: segments)
                .frame(height: 50)
                .padding(.horizontal, 8)
        }
    }
}

struct BarVisualization: View {
    let segments: [TranscriptionSegment]

    private let barWidth: CGFloat = 8
    private let barSpacing: CGFloat = 2
    private var totalBarWidth: CGFloat {
        barWidth + barSpacing
    }
    private let cornerRadius: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            guard !segments.isEmpty else { return }

            var xOffset: CGFloat = 0

            for (index, segment) in segments.enumerated() {
                guard xOffset + barWidth <= size.width else { break }

                let confidence = Float(1.0 - segment.noSpeechProb)
                let barHeight = CGFloat(confidence) * size.height

                let barColor = colorForConfidence(confidence)

                let progress = min(1.0, CGFloat(index + 1) / CGFloat(segments.count))
                let easedProgress = 1.0 - pow(1.0 - progress, 3.0)
                let animatedHeight = barHeight * CGFloat(easedProgress)

                let barRect = CGRect(
                    x: xOffset,
                    y: size.height - animatedHeight,
                    width: barWidth,
                    height: animatedHeight
                )

                let barPath = RoundedRectangle(cornerRadius: cornerRadius)
                    .path(in: barRect)

                context.fill(
                    barPath,
                    with: .color(barColor.opacity(0.5))
                )

                xOffset += totalBarWidth
            }
        }
    }

    private func colorForConfidence(_ confidence: Float) -> Color {
        if confidence >= 0.9 {
            return .green
        } else if confidence >= 0.7 {
            return .yellow
        } else if confidence >= 0.4 {
            return .orange
        } else {
            return .red
        }
    }
}
