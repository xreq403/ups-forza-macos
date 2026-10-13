import AppKit

/// Apagado ordenado de la Mac.
///
/// Envía el AppleEvent `kAEShutDown` a `loginwindow` (Apple QA1134): equivale a
/// "Apagar…" del menú Apple sin el diálogo de confirmación. Las apps con cambios
/// sin guardar pueden bloquearlo. Si falla, recurre a System Events vía `osascript`.
enum SystemShutdown {
    private static let kCoreEventClass: AEEventClass = 0x6165_7674   // 'aevt'
    private static let kAEShutDown: AEEventID = 0x7368_7574          // 'shut'

    static func shutDown() throws {
        do {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: kCoreEventClass,
                eventID: kAEShutDown,
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            _ = try event.sendEvent(options: [.noReply], timeout: 30)
        } catch {
            EventLog.shared.write("AppleEvent a loginwindow falló (\(error)); probando con System Events")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to shut down"]
            try p.run()
        }
    }
}
