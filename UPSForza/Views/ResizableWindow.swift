import AppKit
import SwiftUI

/// Configura la ventana que contiene la vista con AppKit: redimensionable, con
/// límites de tamaño, un tamaño inicial y su propio nombre para recordar el marco.
/// En la ventana de Ajustes, SwiftUI ignora el tamaño ideal de la vista y la crea
/// sin `.resizable`, así que esto se hace a mano.
struct ResizableWindow: NSViewRepresentable {
    var initialSize: NSSize
    var minSize: NSSize
    var maxSize: NSSize
    /// Nombre con el que macOS guarda el marco (tamaño y posición) de la ventana.
    var autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        view.configure = { window in configure(window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.contentMinSize = minSize
        window.contentMaxSize = maxSize

        // Restaurar el marco guardado; si no hay (primera vez), tamaño inicial
        // recortado a la pantalla y centrada.
        if window.frameAutosaveName != autosaveName {
            let restored = window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
            if !restored {
                var size = initialSize
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    size.height = min(size.height, visible.height - 60)
                }
                window.setContentSize(size)
                window.center()
            }
        }
    }
}

/// Avisa cuando la vista entra en su ventana (y de nuevo tras la primera disposición
/// de SwiftUI, que puede cambiar el tamaño).
private final class WindowObserverView: NSView {
    var configure: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        configure?(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.configure?(window)
        }
    }
}
