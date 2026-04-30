//
//  PointStreamSender.swift
//  NISDK3_Example
//
//  Responsible for: batched dot transmission, server health monitoring,
//  and pen reconnect signalling. All buffer and flag mutations run on
//  the private serial `queue`; UI callbacks are dispatched to main.
//

import Foundation
import NISDK3

// MARK: - PointStreamSender

final class PointStreamSender {

    // MARK: - Config

    enum Config {
        static let defaultBaseURL     = "91.197.0.41:5252"
        static let userDefaultsURLKey = "ServerBaseURL"

        static let flushInterval:   DispatchTimeInterval = .milliseconds(400)
        static let healthInterval:  DispatchTimeInterval = .seconds(5)
        static let requestTimeout:  TimeInterval         = 5.0
        static let maxBufferSize    = 5_000
        static let successFlashDuration: TimeInterval    = 0.5

        enum Endpoint {
            static let dots   = "/api/dots"
            static let health = "/health"
        }

        enum HTTPStatus {
            /// Non-standard code: server signals the pen must reconnect.
            /// Sent only when the browser dashboard "Reconnect" button is pressed
            /// and connectedPen == "NaN". The server resets the flag after sending,
            /// so this is a one-shot event per button press.
            static let penReconnectRequired = 252

            /// 405 Method Not Allowed still means the server is alive.
            static let methodNotAllowed     = 405
        }
    }

    // MARK: - Callbacks (must be set before calling start())

    /// Fires on main thread when the server connection status changes.
    var onStatusChange: ((PointStreamSender.ConnectionStatus) -> Void)?

    /// Fires on main thread when the server requests pen reconnection (HTTP 252)
    /// and the pen is not currently scanning (PenHelper.shared.opened == false).
    var onReconnectRequired: (() -> Void)?

    /// Fires on main thread after a successful non-252 health response,
    /// so the owner can reset any "reconnect needed" flag.
    var onConnected: (() -> Void)?

    // MARK: - Connection status

    enum ConnectionStatus {
        case disconnected   // red
        case connected      // blue
        case successFlash   // green → blue after Config.successFlashDuration
    }

    // MARK: - Private state (all mutations serialized on `queue`)

    private let queue = DispatchQueue(label: "com.neosmartpen.pointstream", qos: .utility)
    private var flushTimer:  DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var isFlushing       = false
    private var isCheckingHealth = false
    private var activeFlushTask: URLSessionDataTask?

    // MARK: - Init / lifecycle

    init() {}

    /// Starts the flush and health-check timers.
    /// Call this after setting all callbacks to avoid a race where a timer
    /// fires before a callback is assigned.
    func start() {
        startFlushTimer()
        startHealthTimer()
    }

    deinit {
        flushTimer?.cancel()
        healthTimer?.cancel()
        activeFlushTask?.cancel()
    }

    // MARK: - Buffer (external API)

    /// Thread-safe: dispatches asynchronously to the private queue.
    func addToBuffer(_ dot: Dot) {
        queue.async { [self] in
            if PenHelper.shared.netBuffer.count >= Config.maxBufferSize {
                // Drop oldest to prevent unbounded growth during prolonged outages.
                PenHelper.shared.netBuffer.removeFirst()
                print("[PointStreamSender] Buffer overflow — oldest dot dropped.")
            }
            PenHelper.shared.netBuffer.append(dot)
        }
    }

    // MARK: - Timers (private)

    private func startFlushTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Config.flushInterval,
                   repeating: Config.flushInterval,
                   leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.flushBuffer() }
        t.resume()
        flushTimer = t
    }

    private func startHealthTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 1-second initial delay so the first health check does not race
        // with the flush timer that starts at the same moment.
        t.schedule(deadline: .now() + .seconds(1),
                   repeating: Config.healthInterval,
                   leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.checkServerHealth() }
        t.resume()
        healthTimer = t
    }

    // MARK: - Flush (runs on queue)

    private func flushBuffer() {
        // Backpressure: skip this tick if the previous request is still in flight.
        guard !isFlushing else { return }
        guard !PenHelper.shared.netBuffer.isEmpty else { return }

        // Atomic grab: copy + clear in one critical section (already serialized on queue).
        let snapshot = PenHelper.shared.netBuffer
        PenHelper.shared.netBuffer.removeAll(keepingCapacity: true)
        isFlushing = true

        guard let url  = buildURL(endpoint: Config.Endpoint.dots),
              let body = encodeDotsToJSON(snapshot) else {
            // Encoding failure is unexpected; restore to avoid silent data loss.
            PenHelper.shared.netBuffer.insert(contentsOf: snapshot, at: 0)
            isFlushing = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = Config.requestTimeout

        let task = URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                defer { self.isFlushing = false }

                if let error = error {
                    // Return dots to the front of the buffer to preserve
                    // chronological order for the next flush attempt.
                    PenHelper.shared.netBuffer.insert(
                        contentsOf: snapshot,
                        at: PenHelper.shared.netBuffer.startIndex
                    )
                    print("[PointStreamSender] flush error: \(error.localizedDescription). "
                          + "\(snapshot.count) dots returned to buffer.")
                    self.notifyStatus(.disconnected)
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.notifyStatus(.successFlash)
                } else {
                    self.notifyStatus(.disconnected)
                }
            }
        }
        activeFlushTask = task
        task.resume()
    }

    // MARK: - Health check (runs on queue)

    private func checkServerHealth() {
        // Guard against parallel health checks (e.g. from rapid timer overlap).
        guard !isCheckingHealth else { return }
        isCheckingHealth = true

        let isConn = PenHelper.shared.isConnected ?? false
        // "NaN" as a string is the protocol token the server uses to detect
        // a disconnected pen and potentially return 252. (server.js line 57)
        let penID  = isConn ? (PenHelper.shared.pen?.macAddress ?? "NaN") : "NaN"

        guard let url  = buildURL(endpoint: Config.Endpoint.health),
              let body = try? JSONSerialization.data(withJSONObject: ["connectedPen": penID]) else {
            isCheckingHealth = false
            notifyStatus(.disconnected)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = Config.requestTimeout

        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                defer { self.isCheckingHealth = false }

                if error != nil {
                    self.notifyStatus(.disconnected)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.notifyStatus(.disconnected)
                    return
                }

                switch http.statusCode {
                case Config.HTTPStatus.penReconnectRequired:
                    // Server (triggered via dashboard "Reconnect" button) is asking
                    // the app to re-establish the pen Bluetooth connection.
                    self.handleReconnectRequired()
                    // Server is reachable even though it sent 252 → show connected.
                    self.notifyStatus(.connected)

                case 200...299, Config.HTTPStatus.methodNotAllowed:
                    self.notifyStatus(.connected)
                    DispatchQueue.main.async { [weak self] in
                        self?.onConnected?()
                    }

                default:
                    self.notifyStatus(.disconnected)
                }
            }
        }.resume()
    }

    // MARK: - Reconnect (on queue)

    private func handleReconnectRequired() {
        if !PenHelper.shared.opened {
            DispatchQueue.main.async { [weak self] in
                self?.onReconnectRequired?()
            }
        } else {
            DispatchQueue.main.async {
                PenFinder.shared.scanStop()
                PenFinder.shared.scan(10.0)
            }
        }
    }

    // MARK: - Helpers

    private func buildURL(endpoint: String) -> URL? {
        let base = UserDefaults.standard.string(forKey: Config.userDefaultsURLKey)
                   ?? Config.defaultBaseURL
        let full: String
        if base.hasPrefix("http://") || base.hasPrefix("https://") {
            full = base + endpoint
        } else {
            full = "http://\(base)\(endpoint)"
        }
        return URL(string: full)
    }

    private func encodeDotsToJSON(_ dots: [Dot]) -> Data? {
        let array: [[String: Any]] = dots.map { dot in
            let dotTypeCode: Int
            switch dot.dotType {
            case .Down: dotTypeCode = 0
            case .Move: dotTypeCode = 1
            case .Up:   dotTypeCode = 2
            }
            return [
                "x":       dot.x,
                "y":       dot.y,
                "force":   dot.force,
                "time":    dot.time,
                "dotType": dotTypeCode,
                "page":    dot.pageInfo.page,
                "section": dot.pageInfo.section,
                "owner":   dot.pageInfo.owner,
                "note":    dot.pageInfo.note
            ]
        }
        return try? JSONSerialization.data(withJSONObject: array)
    }

    private func notifyStatus(_ status: ConnectionStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }
}
