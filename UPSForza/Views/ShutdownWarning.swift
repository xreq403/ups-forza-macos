import AppKit
import SwiftUI
import UPSKit

/// Panel flotante, visible en todos los Spaces y sobre apps en pantalla completa,
/// con la cuenta regresiva del apagado.
@MainActor
final class ShutdownWarningPanel {
    private var panel: NSPanel?

    func show(monitor: UPSMonitor) {
        if panel == nil {
            let hosting = NSHostingView(rootView: ShutdownWarningView().environment(monitor))
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = hosting
            panel = p
        }
        panel?.center()
        panel?.orderFrontRegardless()
        NSApp.activate()
    }

    func close() {
        panel?.orderOut(nil)
    }
}

struct ShutdownWarningView: View {
    @Environment(UPSMonitor.self) private var monitor

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            Text("La Mac se apagará")
                .font(.title2.weight(.bold))

            if case .warning(_, let deadline, let reason) = monitor.phase {
                Text(deadline, style: .timer)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(reason.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Hay un corte de luz. Guarda tu trabajo: las apps con cambios sin guardar pueden bloquear el apagado.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if monitor.canPostpone {
                    Button("Posponer 5 min") { monitor.postpone() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Apagar ahora", role: .destructive) { monitor.shutdownNow() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 400)
    }
}
