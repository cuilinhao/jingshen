import SwiftUI
import UIKit

enum DepthTheme {
    static let accent = Color(red: 1, green: 0.17, blue: 0)
    static let panel = Color(white: 0.075)
    static let muted = Color(white: 0.64)
}

struct ReferenceCircleButton<Content: View>: View {
    var size: CGFloat = 44
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content().foregroundStyle(.white).frame(width: size, height: size)
                .background(DepthTheme.panel, in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain)
    }
}

struct DepthToggle: View {
    @Binding var enabled: Bool
    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { enabled.toggle() }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Capsule().fill(enabled ? DepthTheme.accent : Color(white: 0.28))
                .overlay(alignment: enabled ? .trailing : .leading) {
                    Capsule().fill(.white).frame(width: 36, height: 25).padding(1.5)
                }
                .frame(width: 63, height: 28)
                .frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("景深效果")
        .accessibilityValue(enabled ? "开启" : "关闭")
    }
}

/// The orange index stays fixed; gray marks scroll beneath it, matching the video.
struct ApertureRuler: View {
    let value: Double
    let isEnabled: Bool
    let onChange: (Double) -> Void
    @State private var initialValue: Double?
    @State private var lastFeedbackStep = 0
    private let pointsPerStop: Double = 54
    private let indexX: CGFloat = 191

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(DepthTheme.panel)
            Canvas { context, size in
                let viewport = CGRect(x: 55, y: 0, width: 273, height: size.height)
                context.clip(to: Path(viewport))
                for tick in 0...28 {
                    let f = Aperture.minimum * pow(2, Double(tick) / 8)
                    let x = indexX + CGFloat(log2(f / Aperture.clamp(value)) * pointsPerStop)
                    let height: CGFloat = tick % 4 == 0 ? 14 : (tick % 2 == 0 ? 10 : 7)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 31 - height))
                    path.addLine(to: CGPoint(x: x, y: 31))
                    context.stroke(path, with: .color(Color(white: tick % 4 == 0 ? 0.70 : 0.51)), lineWidth: 0.55)
                }
            }
            Text("ƒ\(value, specifier: "%.1f")")
                .font(.system(size: 12, weight: .light)).foregroundStyle(DepthTheme.accent)
                .monospacedDigit().padding(.leading, 14).allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 2).fill(DepthTheme.accent)
                .frame(width: 4, height: 28).position(x: indexX, y: 25)
                .allowsHitTesting(false)
        }
        .frame(width: 382, height: 50)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { event in
                guard isEnabled else { return }
                if initialValue == nil { initialValue = value }
                let newValue = (initialValue ?? value) * pow(2, -Double(event.translation.width) / pointsPerStop)
                onChange(newValue)
                let step = Int(Aperture.clamp(newValue) * 2)
                if step != lastFeedbackStep {
                    UISelectionFeedbackGenerator().selectionChanged()
                    lastFeedbackStep = step
                }
            }
            .onEnded { event in
                defer { initialValue = nil }
                guard isEnabled else { return }
                if abs(event.translation.width) < 3 {
                    let tapped = value * pow(2, Double(event.location.x - indexX) / pointsPerStop)
                    onChange(tapped)
                }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("模拟光圈")
        .accessibilityValue(String(format: "f %.1f", value))
        .accessibilityHint("左右拖动；光圈数值越小，虚化越强")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onChange(value + 0.2)
            case .decrement: onChange(value - 0.2)
            @unknown default: break
            }
        }
    }
}

struct ColorCirclesIcon: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.40), lineWidth: 1.2).frame(width: 12, height: 12).offset(x: -3.5, y: 2.6)
            Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.2).frame(width: 12, height: 12).offset(x: 3.5, y: 2.6)
            Circle().stroke(Color.white, lineWidth: 1.2).frame(width: 12, height: 12).offset(y: -3.2)
        }.frame(width: 24, height: 24)
    }
}

struct CompareIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.7).stroke(lineWidth: 1.2).frame(width: 19, height: 14)
            Rectangle().stroke(lineWidth: 0.8).frame(width: 15, height: 10)
        }.frame(width: 24, height: 24)
    }
}

struct FocusReticle: View {
    let pulse: Int
    @State private var scale: CGFloat = 1
    var body: some View {
        Rectangle().stroke(DepthTheme.accent, lineWidth: 1.15)
            .frame(width: 48, height: 48).scaleEffect(scale)
            .onChange(of: pulse) { _, _ in
                scale = 1.14
                withAnimation(.easeOut(duration: 0.18)) { scale = 1 }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
