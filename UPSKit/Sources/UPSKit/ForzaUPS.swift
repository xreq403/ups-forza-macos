import Foundation

/// Controlador de la UPS Forza NT-2402PRO (protocolo Voltronic-QS-Hex, variante "T").
///
/// Las variantes `…Sync` bloquean el hilo que llama; las `async` corren en una
/// cola serie propia para no bloquear el *cooperative pool* ni el hilo principal.
public final class ForzaUPS: Sendable {
    public let transport: HIDTransport
    private let queue = DispatchQueue(label: "UPSForza.commands")

    public init(transport: HIDTransport = HIDTransport()) {
        self.transport = transport
    }

    public func start() { transport.start() }

    public var isConnected: Bool { transport.isConnected }

    // MARK: - Síncrono

    /// Comando `M`: variante del protocolo ("T" en este equipo).
    public func protocolVariantSync() throws -> String {
        let reply = try transport.send("M")
        return String(decoding: reply.filter { $0 != 0x0D && $0 != 0x00 }, as: UTF8.self)
    }

    /// Comando `QS`: estado actual.
    public func statusSync() throws -> UPSStatus {
        try QSParser.parse(transport.send("QS"))
    }

    /// Comando arbitrario; devuelve la respuesta cruda. Para diagnóstico.
    public func rawSync(_ command: String, expectReply: Bool = true) throws -> [UInt8] {
        try transport.send(command, expectReply: expectReply)
    }

    /// Deja la alarma sonora en el estado pedido. `Q` solo la alterna, así que
    /// primero se lee el bit b0 y se envía únicamente si hace falta.
    /// Devuelve el estado leído después del cambio (puede no coincidir si la UPS lo ignoró).
    public func setBeeperSync(enabled: Bool) throws -> Bool {
        guard try statusSync().beeperOn != enabled else { return enabled }
        try transport.send("Q", expectReply: false)
        Thread.sleep(forTimeInterval: 0.5)
        return try statusSync().beeperOn
    }

    // MARK: - Async

    public func status() async throws -> UPSStatus {
        try await run { try self.statusSync() }
    }

    public func protocolVariant() async throws -> String {
        try await run { try self.protocolVariantSync() }
    }

    public func setBeeper(enabled: Bool) async throws -> Bool {
        try await run { try self.setBeeperSync(enabled: enabled) }
    }

    // Comandos de control (según NUT; aún no probados en este equipo).

    /// `Q`: alterna la alarma sonora. Para fijar un estado usar `setBeeper(enabled:)`.
    public func toggleBeeper() async throws {
        try await run { try self.transport.send("Q", expectReply: false) }
    }

    /// `T`: test rápido de batería.
    public func batteryTest() async throws {
        try await run { try self.transport.send("T", expectReply: false) }
    }

    /// `C`: cancela un apagado programado / enciende la salida.
    public func cancelShutdown() async throws {
        try await run { try self.transport.send("C", expectReply: false) }
    }

    /// `S<n>`: apaga la salida de la UPS tras `minutes` (0.2–9) y la vuelve a
    /// encender cuando regrese la luz.
    public func shutdownAndReturn(minutes: Double) async throws {
        let cmd = Self.shutdownCommand(minutes: minutes)
        try await run { try self.transport.send(cmd, expectReply: false) }
    }

    static func shutdownCommand(minutes: Double) -> String {
        let m = min(max(minutes, 0.2), 9)
        return m < 1 ? "S.\(Int((m * 10).rounded()))" : String(format: "S%02d", Int(m))
    }

    @discardableResult
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }
}
