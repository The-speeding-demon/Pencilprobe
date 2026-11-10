import SwiftUI
import UIKit

// PencilProbe: logs every Apple Pencil signal an app is able to receive.
// - Double-tap and squeeze gestures (UIPencilInteraction)
// - Touches whose type is .pencil, as opposed to a finger
// - Hover events
// - The system's Pencil preferences, as reported to apps

@main
struct PencilProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class EventLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
        let isPencil: Bool
    }

    @Published var entries: [Entry] = []
    @Published var pencilEventCount = 0

    func add(_ text: String, pencil: Bool = false) {
        entries.insert(Entry(text: text, isPencil: pencil), at: 0)
        if pencil { pencilEventCount += 1 }
        if entries.count > 200 { entries.removeLast() }
    }

    func clear() {
        entries.removeAll()
        pencilEventCount = 0
    }
}

final class ProbeView: UIView, UIPencilInteractionDelegate {
    var log: EventLog?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true

        let interaction = UIPencilInteraction()
        interaction.delegate = self
        addInteraction(interaction)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Pencil gestures

    // Called on iOS versions before 17.5.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        log?.add("Pencil double-tap", pencil: true)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveTap tap: UIPencilInteraction.Tap) {
        log?.add("Pencil double-tap", pencil: true)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        let phase: String
        switch squeeze.phase {
        case .began: phase = "began"
        case .changed: phase = "changed"
        case .ended: phase = "ended"
        case .cancelled: phase = "cancelled"
        @unknown default: phase = "unknown"
        }
        if squeeze.phase != .changed {
            log?.add("Pencil squeeze \(phase)", pencil: true)
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let isPencil = touch.type == .pencil
            log?.add("Touch began: \(Self.name(of: touch.type))", pencil: isPencil)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .pencil {
            let force = String(format: "%.2f", touch.force)
            log?.add("Pencil touch ended (force \(force))", pencil: true)
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        if recognizer.state == .began {
            log?.add("Hover began (Pencil or pointer)")
        }
    }

    private static func name(of type: UITouch.TouchType) -> String {
        switch type {
        case .direct: return "finger"
        case .pencil: return "APPLE PENCIL"
        case .indirect: return "indirect"
        case .indirectPointer: return "pointer"
        @unknown default: return "unknown (\(type.rawValue))"
        }
    }
}

struct ProbeArea: UIViewRepresentable {
    let log: EventLog

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.log = log
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var log = EventLog()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(log.pencilEventCount == 0
                     ? "No Pencil events received"
                     : "Pencil events received: \(log.pencilEventCount)")
                    .font(.headline)
                    .foregroundColor(log.pencilEventCount == 0 ? .secondary : .green)
                Text(systemPreferences)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .id(scenePhase) // re-read the preferences when the app returns to the foreground
            }
            .padding(.top, 8)

            ProbeArea(log: log)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    Text("Touch here with the Pencil tip,\nor double-tap / squeeze the Pencil")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                )
                .padding(.horizontal)

            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { log.clear() }
            }
            .padding(.horizontal)

            List(log.entries) { entry in
                HStack {
                    Text(entry.time.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Text(entry.text)
                        .fontWeight(entry.isPencil ? .bold : .regular)
                        .foregroundColor(entry.isPencil ? .green : .primary)
                }
            }
            .listStyle(.plain)
        }
    }

    private var systemPreferences: String {
        var lines = [
            "tap action: \(UIPencilInteraction.preferredTapAction.rawValue)",
            "pencil-only drawing: \(UIPencilInteraction.prefersPencilOnlyDrawing)"
        ]
        if #available(iOS 17.5, *) {
            lines.append("squeeze action: \(UIPencilInteraction.preferredSqueezeAction.rawValue)")
        }
        return lines.joined(separator: "\n")
    }
}
