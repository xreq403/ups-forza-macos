import SwiftUI

/// Ventana principal: panel en vivo e historial, en pestañas.
struct MainWindowView: View {
    @AppStorage("mainWindowTab") private var tab = Tab.dashboard

    enum Tab: String {
        case dashboard
        case history
    }

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Panel", systemImage: "chart.xyaxis.line") }
                .tag(Tab.dashboard)
            HistoryView()
                .tabItem { Label("Historial", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
        }
        .frame(minWidth: 820, minHeight: 640)
    }
}
