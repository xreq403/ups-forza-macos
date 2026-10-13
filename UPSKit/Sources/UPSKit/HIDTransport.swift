import Foundation
import IOKit.hid

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case writeFailed(IOReturn)
    case timeout(String)

    public var description: String {
        switch self {
        case .notConnected: "UPS no conectada"
        case .writeFailed(let r): "Error escribiendo en la UPS (IOReturn 0x\(String(UInt32(bitPattern: r), radix: 16)))"
        case .timeout(let cmd): "Sin respuesta al comando \(cmd)"
        }
    }
}

/// Transporte USB HID para el chip INNO TECH "USB to Serial" (VID 0x0665 / PID 0x5161).
///
/// - Envío: el comando ASCII terminado en `\r` se parte en bloques de 8 bytes,
///   rellenados con 0x00, y cada bloque se envía como *output report* (sin report ID).
/// - Recepción: se acumulan *input reports* de 8 bytes hasta encontrar `\r`.
///
/// El `IOHIDManager` corre en un hilo propio con su run loop; los callbacks de
/// conexión y desconexión llegan en ese hilo.
public final class HIDTransport: @unchecked Sendable {
    public static let vendorID = 0x0665
    public static let productID = 0x5161
    static let reportSize = 8

    /// Se llama (en el hilo HID) al conectar (`true`) o desconectar (`false`) la UPS.
    /// Asignar antes de `start()`.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let state = NSCondition()          // protege device e inputBuffer
    private var device: IOHIDDevice?
    private var inputBuffer: [UInt8] = []
    private let commandLock = NSLock()         // serializa comandos completos
    private var manager: IOHIDManager?
    private var thread: Thread?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    public init() {}

    public var isConnected: Bool {
        state.lock()
        defer { state.unlock() }
        return device != nil
    }

    /// Empieza a buscar la UPS. Idempotente.
    public func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [String: Any] = [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
                Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
                Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
            }, ctx)

            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "UPSForza.HID"
        thread = t
        t.start()
        ready.wait()
    }

    /// Envía un comando y devuelve la respuesta cruda (hasta `\r` inclusive).
    /// Bloquea el hilo que llama hasta recibir la respuesta o agotar `timeout`.
    @discardableResult
    public func send(_ command: String, expectReply: Bool = true, timeout: TimeInterval = 3) throws -> [UInt8] {
        commandLock.lock()
        defer { commandLock.unlock() }
        state.lock()
        defer { state.unlock() }

        guard let device else { throw TransportError.notConnected }
        inputBuffer.removeAll()   // descarta datos viejos

        let data = Array((command + "\r").utf8)
        for start in stride(from: 0, to: data.count, by: Self.reportSize) {
            var report = Array(data[start..<min(start + Self.reportSize, data.count)])
            report += Array(repeating: 0, count: Self.reportSize - report.count)
            let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count)
            guard r == kIOReturnSuccess else { throw TransportError.writeFailed(r) }
        }
        guard expectReply else { return [] }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if let cr = inputBuffer.firstIndex(of: 0x0D) {
                let reply = Array(inputBuffer[...cr])
                inputBuffer.removeAll()
                return reply
            }
            guard self.device != nil else { throw TransportError.notConnected }
            if !state.wait(until: deadline) { throw TransportError.timeout(command) }
        }
    }

    // MARK: - Callbacks (hilo HID)

    private func attach(_ dev: IOHIDDevice) {
        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 64, { ctx, _, _, _, _, report, length in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
                .received(UnsafeBufferPointer(start: report, count: length))
        }, Unmanaged.passUnretained(self).toOpaque())

        state.lock()
        device = dev
        inputBuffer.removeAll()
        state.broadcast()
        state.unlock()
        onConnectionChange?(true)
    }

    private func detach(_ dev: IOHIDDevice) {
        state.lock()
        let wasCurrent = device === dev
        if wasCurrent { device = nil }
        state.broadcast()
        state.unlock()
        if wasCurrent { onConnectionChange?(false) }
    }

    private func received(_ bytes: UnsafeBufferPointer<UInt8>) {
        state.lock()
        inputBuffer.append(contentsOf: bytes)
        state.broadcast()
        state.unlock()
    }
}
