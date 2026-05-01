//
//  PageStrokeView.swift
//  NISDK3_Example
//
//  PageStrokeView: real-time stroke and hover rendering.
//  PointStreamSender: batched dot transmission and server health monitoring.
//
//  Both classes live in this file because the iOS-SDK3.0 sample project's
//  .xcodeproj cannot be edited without a Mac to add new source files.
//

import UIKit
import CoreGraphics
import NISDK3

// MARK: - PageStrokeView

class PageStrokeView: UIView {

    // MARK: - Public API (preserved for MainViewController compatibility)

    /// Set by MainViewController. Invoked when the server requests pen reconnection.
    var onNeedConnect: (() -> Void)?

    /// When set to true, triggers onNeedConnect once. Reset to false after a
    /// successful server health response so the next reconnect signal can fire.
    var needToConnect: Bool = false {
        didSet {
            if needToConnect { onNeedConnect?() }
        }
    }

    /// Page geometry — written externally by MainViewController.pageUpdate.
    var x: Double = 0.0
    var y: Double = 0.0
    var width:  Double = 0.0
    var height: Double = 0.0

    // MARK: - Drawing layers

    private var dotPath    = UIBezierPath()
    private var shapelayer: CAShapeLayer!
    private var hoverLayer: CAShapeLayer!
    private let hoverRadius: CGFloat = 5

    // MARK: - Network sender

    private var sender: PointStreamSender!

    // MARK: - Connection indicator

    private let indicator = ConnectionIndicatorView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear

        shapelayer = CAShapeLayer()
        shapelayer.lineWidth   = 1
        shapelayer.strokeColor = UIColor.white.cgColor
        shapelayer.fillColor   = UIColor.clear.cgColor
        shapelayer.lineCap     = .round
        layer.addSublayer(shapelayer)

        hoverLayer = CAShapeLayer()
        layer.addSublayer(hoverLayer)

        addSubview(indicator)
        // Match original visible position (CGRect x: 355, y: 0, w/h: 10).
        NSLayoutConstraint.activate([
            indicator.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            indicator.widthAnchor.constraint(equalToConstant: 10),
            indicator.heightAnchor.constraint(equalToConstant: 10)
        ])
        indicator.apply(.disconnected)

        sender = PointStreamSender()
        sender.onStatusChange = { [weak self] status in
            self?.indicator.apply(status)
        }
        sender.onReconnectRequired = { [weak self] in
            self?.needToConnect = true
        }
        sender.onConnected = { [weak self] in
            self?.needToConnect = false
        }
        sender.start()
    }

    // MARK: - Dot rendering

    /// Called on the main thread (CBCentralManager uses queue: nil → main).
    func addDot(_ dot: Dot) {
        hoverLayer.isHidden = true
        let point = ScaleHelper.shared.getPoint(dot, frame.size)
        switch dot.dotType {
        case .Down:
            dotPath.move(to: point)
        case .Move:
            dotPath.addLine(to: point)
            shapelayer.path = dotPath.cgPath
        case .Up:
            dotPath.removeAllPoints()
        }
        sender.addToBuffer(dot)
    }

    // MARK: - Hover rendering

    func addHoverLayout(_ dot: Dot) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let center = ScaleHelper.shared.getPoint(dot, self.frame.size)
            let path = UIBezierPath(
                arcCenter: center,
                radius: self.hoverRadius,
                startAngle: 0, endAngle: .pi * 2,
                clockwise: true
            )
            self.hoverLayer.path        = path.cgPath
            self.hoverLayer.fillColor   = UIColor.orange.cgColor
            self.hoverLayer.strokeColor = UIColor.yellow.cgColor
            self.hoverLayer.lineWidth   = self.hoverRadius * 0.05
            self.hoverLayer.opacity     = 0.6
            self.hoverLayer.isHidden    = false
        }
    }
}

// MARK: - ConnectionIndicatorView

private final class ConnectionIndicatorView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor    = .red
        layer.cornerRadius = 5
        clipsToBounds      = true
    }

    func apply(_ status: PointStreamSender.ConnectionStatus) {
        UIView.animate(withDuration: 0.2) {
            switch status {
            case .disconnected: self.backgroundColor = .red
            case .connected:    self.backgroundColor = .systemBlue
            case .successFlash: self.backgroundColor = .systemGreen
            }
        }
        if status == .successFlash {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + PointStreamSender.Config.successFlashDuration
            ) { [weak self] in
                UIView.animate(withDuration: 0.2) {
                    self?.backgroundColor = .systemBlue
                }
            }
        }
    }
}

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
            /// Non-standard code: server signals the pen must reconnect
            /// (one-shot, sent only when "Reconnect" pressed in dashboard
            /// and connectedPen == "NaN").
            static let penReconnectRequired = 252
            /// 405 Method Not Allowed still means server is alive.
            static let methodNotAllowed     = 405
        }
    }

    // MARK: - Callbacks (set before calling start())

    var onStatusChange:      ((ConnectionStatus) -> Void)?
    var onReconnectRequired: (() -> Void)?
    var onConnected:         (() -> Void)?

    // MARK: - Connection status

    enum ConnectionStatus {
        case disconnected
        case connected
        case successFlash
    }

    // MARK: - Private state (mutated only on `queue`)

    private let queue = DispatchQueue(label: "com.neosmartpen.pointstream", qos: .utility)
    private var flushTimer:  DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var isFlushing       = false
    private var isCheckingHealth = false
    private var activeFlushTask: URLSessionDataTask?

    init() {}

    func start() {
        // Permit PenSearchViewController to auto-connect by saved MAC.
        // (PenSearchViewController:164 reads this flag as a permission gate.)
        // The flag is set once at startup; PenSearchVC's MAC match check
        // ensures we still only auto-connect to the user-configured device.
        PenHelper.shared.needToConnect = true

        startFlushTimer()
        startHealthTimer()
    }

    deinit {
        flushTimer?.cancel()
        healthTimer?.cancel()
        activeFlushTask?.cancel()
    }

    // MARK: - Buffer (external API)

    func addToBuffer(_ dot: Dot) {
        queue.async {
            if PenHelper.shared.netBuffer.count >= Config.maxBufferSize {
                PenHelper.shared.netBuffer.removeFirst()
                print("[PointStreamSender] Buffer overflow — oldest dot dropped.")
            }
            PenHelper.shared.netBuffer.append(dot)
        }
    }

    // MARK: - Timers

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
        t.schedule(deadline: .now() + .seconds(1),
                   repeating: Config.healthInterval,
                   leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.checkServerHealth() }
        t.resume()
        healthTimer = t
    }

    // MARK: - Flush (on queue)

    private func flushBuffer() {
        guard !isFlushing else { return }
        guard !PenHelper.shared.netBuffer.isEmpty else { return }

        let snapshot = PenHelper.shared.netBuffer
        PenHelper.shared.netBuffer.removeAll(keepingCapacity: true)
        isFlushing = true

        guard let url  = buildURL(endpoint: Config.Endpoint.dots),
              let body = encodeDotsToJSON(snapshot) else {
            PenHelper.shared.netBuffer.insert(contentsOf: snapshot, at: 0)
            isFlushing = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod      = "POST"
        req.httpBody        = body
        req.timeoutInterval = Config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else { return }
            self.queue.async {
                defer { self.isFlushing = false }
                if let error = error {
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

    // MARK: - Health check (on queue)

    private func checkServerHealth() {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true

        let isConn = PenHelper.shared.isConnected ?? false
        let penID  = isConn ? (PenHelper.shared.pen?.macAddress ?? "NaN") : "NaN"

        guard let url  = buildURL(endpoint: Config.Endpoint.health),
              let body = try? JSONSerialization.data(withJSONObject: ["connectedPen": penID]) else {
            isCheckingHealth = false
            notifyStatus(.disconnected)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod      = "POST"
        req.httpBody        = body
        req.timeoutInterval = Config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else { return }
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
                    self.handleReconnectRequired()
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
