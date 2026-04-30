//
//  PageStrokeView.swift
//  NISDK3_Example
//
//  Responsible for: real-time stroke rendering and hover display.
//  Network concerns (batching, health check, reconnect) are delegated
//  to PointStreamSender.
//

import UIKit
import CoreGraphics
import NISDK3

class PageStrokeView: UIView {

    // MARK: - Public API (preserved for MainViewController compatibility)

    /// Set by MainViewController. Invoked when the server requests pen reconnection.
    var onNeedConnect: (() -> Void)?

    /// When set to true, triggers onNeedConnect once.
    /// Reset to false after a successful server health response so the next
    /// reconnect signal can fire the callback again.
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

    // MARK: - Network

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

    // deinit is intentionally minimal: PointStreamSender.deinit handles
    // timer cancellation and task cancellation.

    // MARK: - Setup

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

        // translatesAutoresizingMaskIntoConstraints must be false
        // when NSLayoutConstraint.activate is used (fixes previous constraint conflict).
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: -16),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -160),
            indicator.widthAnchor.constraint(equalToConstant: 10),
            indicator.heightAnchor.constraint(equalToConstant: 10)
        ])
        indicator.apply(.disconnected)

        // Configure sender before start() to avoid a race where the first
        // timer tick fires before the callbacks are assigned.
        sender = PointStreamSender()
        sender.onStatusChange = { [weak self] status in
            self?.indicator.apply(status)
        }
        sender.onReconnectRequired = { [weak self] in
            // Routes through needToConnect so MainViewController's onNeedConnect
            // closure is invoked (preserved public API behaviour).
            self?.needToConnect = true
        }
        sender.onConnected = { [weak self] in
            // Reset flag so the next reconnect signal can re-trigger the callback.
            self?.needToConnect = false
        }
        sender.start()
    }

    // MARK: - Dot rendering

    /// Called on the main thread.
    /// Caller contract: CBCentralManager is initialised with queue: nil (main queue),
    /// so dotDelegate fires on main. Do not wrap in DispatchQueue.main.async here.
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
        // Dispatched to sender's private queue — does not block the caller.
        sender.addToBuffer(dot)
    }

    // MARK: - Hover rendering

    func addHoverLayout(_ dot: Dot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
            // hoverLayer is already in the layer hierarchy (added in setup).
            // Toggle visibility instead of addSublayer on every call.
            self.hoverLayer.isHidden    = false
        }
    }
}

// MARK: - ConnectionIndicatorView

/// A 10×10 circle view that reflects the server connection state.
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
        // Must be false for NSLayoutConstraint.activate to work correctly.
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
