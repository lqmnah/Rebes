//
//  HelperClient.swift
//  RebesCore
//
//  App-side access to privileged operations. Two transports:
//   1. XPC to the installed root daemon (one-time setup, no password prompts)
//   2. Fallback: osascript "with administrator privileges" (prompt per action)
//
//  Daemon install/uninstall themselves use a single admin prompt.
//

import Foundation

public final class HelperClient: @unchecked Sendable {
    public static let shared = HelperClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    // MARK: - daemon state

    public var daemonPlistPath: String { "/Library/LaunchDaemons/\(kHelperMachServiceName).plist" }
    public var daemonBinaryPath: String { "/Library/PrivilegedHelperTools/\(kHelperMachServiceName)" }

    public func isDaemonInstalled() -> Bool {
        FileManager.default.fileExists(atPath: daemonPlistPath) &&
        FileManager.default.fileExists(atPath: daemonBinaryPath)
    }

    /// Quick async liveness probe of the daemon.
    public func pingDaemon(timeout: TimeInterval = 1.5, completion: @escaping @Sendable (Bool) -> Void) {
        guard isDaemonInstalled() else { completion(false); return }
        // ALL exits (error, timeout, reply) funnel through the same gate so
        // the completion can never fire twice.
        let done = Atomic(false)
        let proxy = remoteProxy { _ in
            if !done.getAndSet(true) { completion(false) }
        }
        guard let proxy else {
            if !done.getAndSet(true) { completion(false) }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if !done.getAndSet(true) { completion(false) }
        }
        proxy.ping { _ in
            if !done.getAndSet(true) { completion(true) }
        }
    }

    /// Install the root daemon. `helperBinary` = path of RebesHelper inside the app bundle.
    /// ONE admin prompt; afterwards privileged actions run without passwords.
    public func installDaemon(helperBinary: String) -> AdminShell.Result {
        let q = AdminShell.shellQuote
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(kHelperMachServiceName)</string>
          <key>ProgramArguments</key><array>
            <string>\(daemonBinaryPath)</string><string>daemon</string>
          </array>
          <key>MachServices</key><dict><key>\(kHelperMachServiceName)</key><true/></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
        </dict></plist>
        """
        // `set -e` aborts on any failing step; the bootout is the ONLY step
        // allowed to fail (nothing may be loaded yet), so bootstrap never runs
        // against a half-installed daemon.
        let cmd = [
            "set -e",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(q(helperBinary)) \(q(daemonBinaryPath))",
            "chown root:wheel \(q(daemonBinaryPath))",
            "chmod 544 \(q(daemonBinaryPath))",
            "printf '%s' \(q(plist.replacingOccurrences(of: "\n", with: ""))) > \(q(daemonPlistPath))",
            "chown root:wheel \(q(daemonPlistPath))",
            "chmod 644 \(q(daemonPlistPath))",
            "launchctl bootout system/\(kHelperMachServiceName) 2>/dev/null || true",
            "launchctl bootstrap system \(q(daemonPlistPath))",
        ].joined(separator: "; ")
        let result = AdminShell.runAsAdmin(cmd)
        invalidateConnection()
        return result
    }

    public func uninstallDaemon() -> AdminShell.Result {
        // Stop the fan curve first so the daemon restores automatic control
        // before it is torn down (otherwise fans could stay forced).
        _ = setFanCurve(enabled: false, curve: [])
        // On uninstall ALWAYS deactivate charge control: disable via the
        // engine so the adapter/LED/gates are restored — persistOnExit only
        // applies to daemon restarts, not removal. Keep the user's saved
        // settings (only `enabled` flips off) so a reinstall restores them.
        var offConfig = AppSettings.shared.chargeConfig
        offConfig.enabled = false
        offConfig.persistOnExit = false
        if let data = try? JSONEncoder().encode(offConfig) {
            _ = daemonCall(timeout: 5, { proxy, done in proxy.setChargeConfig(data, withReply: done) })
        }
        // Belt & braces: after the daemon is stopped, run `charge off` as root
        // via the still-present helper binary — even if the XPC call above
        // failed, the firmware band Rebes owns is released before removal
        // (there would be no software left to release it afterwards).
        let q = AdminShell.shellQuote
        let cmd = [
            "launchctl bootout system/\(kHelperMachServiceName) 2>/dev/null || true",
            // Give launchd a beat to tear the daemon down: the CLI's
            // daemon-running guard can race a just-booted-out daemon.
            "sleep 1",
            "\(q(daemonBinaryPath)) charge off 2>/dev/null || true",
            "rm -f \(q(daemonPlistPath)) \(q(daemonBinaryPath))",
        ].joined(separator: "; ")
        let result = AdminShell.runAsAdmin(cmd)
        invalidateConnection()
        return result
    }

    // MARK: - privileged actions (XPC first, osascript fallback)

    public enum Action: Sendable {
        case chargeLimit(Int)
        case fanAuto(Int)
        case fanSet(Int, Float)

        var helperArgs: [String] {
            switch self {
            case .chargeLimit(let v): return ["chwa", "set", "\(v)"]
            case .fanAuto(let i): return ["fan", "auto", "\(i)"]
            case .fanSet(let i, let rpm): return ["fan", "set", "\(i)", String(format: "%.0f", rpm)]
            }
        }
    }

    /// Perform a privileged action. Blocks — call from a background queue.
    /// `fallbackHelperBinary` = bundled RebesHelper path for the osascript route.
    public func perform(_ action: Action, fallbackHelperBinary: String) -> (ok: Bool, message: String) {
        if isDaemonInstalled(), let proxy = remoteProxy(errorHandler: { _ in }) {
            let sema = DispatchSemaphore(value: 0)
            let outcome = Atomic<(Bool, String)?>(nil)
            let handler: (Bool, String) -> Void = { ok, msg in
                outcome.set((ok, msg))
                sema.signal()
            }
            switch action {
            case .chargeLimit(let v): proxy.setChargeLimit(v, reply: handler)
            case .fanAuto(let i): proxy.setFanAuto(i, reply: handler)
            case .fanSet(let i, let rpm): proxy.setFanSpeed(i, rpm: rpm, reply: handler)
            }
            if sema.wait(timeout: .now() + 10) == .success, let (ok, msg) = outcome.get() {
                return (ok, msg)
            }
            invalidateConnection()
            // fall through to osascript on daemon failure
        }

        let cmd = AdminShell.shellQuote(fallbackHelperBinary) + " " +
            action.helperArgs.joined(separator: " ")
        let result = AdminShell.runAsAdmin(cmd)
        return (result.ok, result.output)
    }

    /// Release inactive/purgeable memory. Daemon route = no password prompt;
    /// falls back to one admin prompt when the daemon isn't installed (or is
    /// an older build without this RPC). Blocks — call from a background queue.
    public func purgeRAM() -> (ok: Bool, message: String) {
        if let r = daemonCall(timeout: 60, { proxy, done in proxy.purgeRAM(reply: done) }) {
            return r
        }
        let result = AdminShell.runAsAdmin("/usr/sbin/purge")
        return (result.ok, result.ok ? "RAM purged" : result.output)
    }

    /// Clear the DNS cache. Same daemon-first / admin-prompt-fallback shape as purgeRAM.
    public func flushDNS() -> (ok: Bool, message: String) {
        if let r = daemonCall(timeout: 15, { proxy, done in proxy.flushDNS(reply: done) }) {
            return r
        }
        let result = AdminShell.runAsAdmin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
        return (result.ok, result.ok ? "DNS cache cleared" : result.output)
    }

    /// Invoke one daemon RPC and wait for its reply. Returns nil when the
    /// daemon isn't installed or doesn't answer (connection error — e.g. an
    /// outdated daemon that lacks the method — or timeout), so the caller can
    /// fall back to the admin-prompt route.
    private func daemonCall(
        timeout: TimeInterval,
        _ invoke: (RebesHelperProtocol, @escaping (Bool, String) -> Void) -> Void
    ) -> (ok: Bool, message: String)? {
        let sema = DispatchSemaphore(value: 0)
        let outcome = Atomic<(Bool, String)?>(nil)
        guard isDaemonInstalled(),
              let proxy = remoteProxy(errorHandler: { _ in sema.signal() }) else { return nil }
        invoke(proxy) { ok, msg in
            outcome.set((ok, msg))
            sema.signal()
        }
        if sema.wait(timeout: .now() + timeout) == .success, let (ok, msg) = outcome.get() {
            return (ok, msg)
        }
        invalidateConnection()
        return nil
    }

    /// Start/stop the daemon-side fan curve. Requires the daemon (there is no
    /// osascript fallback — a curve must run in a persistent root process).
    /// Blocks — call from a background queue.
    public func setFanCurve(enabled: Bool, curve: [FanCurvePoint]) -> (ok: Bool, message: String) {
        guard isDaemonInstalled(), let proxy = remoteProxy(errorHandler: { _ in }) else {
            return (false, "The automatic fan curve needs Full Access (the root daemon). Enable it in Settings.")
        }
        let json = (try? JSONEncoder().encode(curve)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sema = DispatchSemaphore(value: 0)
        let outcome = Atomic<(Bool, String)?>(nil)
        proxy.setFanCurve(enabled: enabled, curveJSON: json) { ok, msg in
            outcome.set((ok, msg)); sema.signal()
        }
        if sema.wait(timeout: .now() + 10) == .success, let (ok, msg) = outcome.get() {
            return (ok, msg)
        }
        invalidateConnection()
        return (false, "the daemon did not respond")
    }

    public func fanCurveStatus(completion: @escaping @Sendable (Bool, String) -> Void) {
        guard isDaemonInstalled(), let proxy = remoteProxy(errorHandler: { _ in completion(false, "offline") }) else {
            completion(false, "daemon belum aktif"); return
        }
        proxy.fanCurveStatus(reply: completion)
    }

    // MARK: - charge control

    /// Apply the full charge config. XPC-first; without a live daemon, falls
    /// back to ONE admin prompt running the bundled helper CLI
    /// (`charge set-config <base64 json>` — whitelist-validated there too).
    /// Blocks — call from a background queue.
    public func setChargeConfig(_ config: ChargeConfig, fallbackHelperBinary: String) -> (ok: Bool, message: String) {
        guard let data = try? JSONEncoder().encode(config) else {
            return (false, "could not encode charge config")
        }
        if let r = daemonCall(timeout: 10, { proxy, done in
            proxy.setChargeConfig(data, withReply: done)
        }) {
            return r
        }
        let cmd = AdminShell.shellQuote(fallbackHelperBinary) + " charge set-config " + data.base64EncodedString()
        let result = AdminShell.runAsAdmin(cmd)
        return (result.ok, result.output.isEmpty ? (result.ok ? "OK" : "failed") : result.output)
    }

    /// Rich charge status from the daemon. Returns nil (never prompts) when
    /// the daemon isn't installed or doesn't answer — an installed-but-silent
    /// daemon means an outdated helper that needs a reinstall.
    public func chargeStatus(timeout: TimeInterval = 3, completion: @escaping @Sendable (ChargeStatus?) -> Void) {
        let done = Atomic(false)
        guard isDaemonInstalled(),
              let proxy = remoteProxy(errorHandler: { _ in
                  if !done.getAndSet(true) { completion(nil) }
              }) else {
            completion(nil)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if !done.getAndSet(true) { completion(nil) }
        }
        proxy.chargeStatus { data in
            if !done.getAndSet(true) {
                completion(try? JSONDecoder().decode(ChargeStatus.self, from: data))
            }
        }
    }

    /// One-shot phases — daemon only (a phase must run in a persistent root
    /// process; there is no admin-prompt fallback). Block — background queue.
    public func startTopUp() -> (ok: Bool, message: String) {
        daemonCall(timeout: 10, { proxy, done in proxy.startTopUp(withReply: done) })
            ?? (false, "Full Access helper unavailable")
    }

    public func startDischarge(to percent: Int) -> (ok: Bool, message: String) {
        daemonCall(timeout: 10, { proxy, done in proxy.startDischarge(to: percent, withReply: done) })
            ?? (false, "Full Access helper unavailable")
    }

    public func startCalibration() -> (ok: Bool, message: String) {
        daemonCall(timeout: 10, { proxy, done in proxy.startCalibration(withReply: done) })
            ?? (false, "Full Access helper unavailable")
    }

    public func cancelChargePhase() -> (ok: Bool, message: String) {
        daemonCall(timeout: 10, { proxy, done in proxy.cancelPhase(withReply: done) })
            ?? (false, "Full Access helper unavailable")
    }

    /// Reads legacy charge-limit status through the root daemon (supported,
    /// enabled). Falls back to an unprivileged read when the daemon isn't installed.
    public func chargeLimitStatus(completion: @escaping @Sendable (Bool, Bool) -> Void) {
        if isDaemonInstalled(), let proxy = remoteProxy(errorHandler: { _ in completion(false, false) }) {
            proxy.chargeLimitStatus(reply: completion)
            return
        }
        if let raw = SMC.shared.readRaw("CHWA") {
            completion(true, (raw.bytes.first ?? 0) == 1)
        } else {
            completion(false, false)
        }
    }

    // MARK: - internals

    private func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> RebesHelperProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: RebesHelperProtocol.self)
            // Tear down only THIS connection: a stale handler firing after a
            // replacement was created must not invalidate the fresh one.
            conn.invalidationHandler = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.invalidateConnection(ifCurrent: conn)
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? RebesHelperProtocol
    }

    private func invalidateConnection(ifCurrent stale: NSXPCConnection? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let stale, stale !== connection { return }
        connection?.invalidate()
        connection = nil
    }
}

/// Minimal thread-safe box.
final class Atomic<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
}

extension Atomic where T == Bool {
    /// Returns the previous value and sets the new one atomically.
    func getAndSet(_ v: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = v; return old
    }
}
