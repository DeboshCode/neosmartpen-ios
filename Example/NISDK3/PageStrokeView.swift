//
//  PageStrokeView.swift
//  NISDK3_Example
//
//  Created by NeoLAB on 2020/04/07.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import Foundation
import UIKit
import CoreGraphics
import NISDK3
import CoreBluetooth

class PageStrokeView: UIView {

    override func draw(_ rect: CGRect) {
        // Drawing code
    }
    
    var dotPath = UIBezierPath()
    var shapelayer: CAShapeLayer!
    var x:Double = 0.0
    var y:Double = 0.0
    var width:Double = 0.0
    var height:Double = 0.0
    
    //HoverView
    var hoverLayer: CAShapeLayer!
    var hoverPath: UIBezierPath!
    private var hoverRadius = CGFloat(5)
    var onNeedConnect: (() -> Void)?   // ← новое свойство

    var needToConnect: Bool = false {
        didSet {
            if needToConnect {
                onNeedConnect?()           // вызываем, когда флаг стал true
                //needToConnect = false      // сбрасываем, чтобы не дёргать много раз
            }
        }
    }
    
    // === ДОБАВЛЕНО: Очередь для потокобезопасной работы с буфером ===
        private let dotBufferQueue = DispatchQueue(label: "com.neosmartpen.dotBufferQueue")
        
    // === ДОБАВЛЕНО: Таймер для отправки ===
    private var batchSendTimer: Timer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        viewinit()
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            checkServerConnection()
        }
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        viewinit()
    }
    
    
    private let connectionIndicator: UIView = {
        let view = UIView(frame: CGRect(x: 355, y: 0, width: 10, height: 10))
        view.backgroundColor = .red  // Начальный цвет — красный
        view.layer.cornerRadius = 5  // Идеальный кружок
        view.clipsToBounds = true
        view.isHidden = false  // Или true, если хочешь скрыть по умолчанию
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()
    
    enum ConnectionStatus {
        case disconnected   // красный
        case connected      // синий
        case successFlash   // зелёный на 0.3 сек
    }
    
    func viewinit(){
        backgroundColor = UIColor.clear
        isMultipleTouchEnabled = false
        UIGraphicsBeginImageContext(frame.size)
        shapelayer = CAShapeLayer()
        shapelayer.lineWidth = 1
        shapelayer.strokeColor = UIColor.white.cgColor
        shapelayer.fillColor = UIColor.clear.cgColor
        shapelayer.lineCap = CAShapeLayerLineCap.round
        layer.addSublayer(shapelayer)
        
        //HoverView
        hoverLayer = CAShapeLayer()
        layer.addSublayer(hoverLayer)
        
        // === ДОБАВЛЯЕМ ИНДИКАТОР СОЕДИНЕНИЯ ===
            addSubview(connectionIndicator)
        connectionIndicator.translatesAutoresizingMaskIntoConstraints = true;
            // Constraints для правильного позиционирования (правый верхний угол)
            NSLayoutConstraint.activate([
                connectionIndicator.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: -16),
                connectionIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -160),
                connectionIndicator.widthAnchor.constraint(equalToConstant: 10),
                connectionIndicator.heightAnchor.constraint(equalToConstant: 10)
            ])
            
            // Начальное состояние — красный
            updateConnectionIndicator(.disconnected)
        
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.checkServerConnection()
        }
        
        // === ДОБАВЛЕНО: Запуск таймера для батч-отправки (каждые 200 мс) ===
            batchSendTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.sendBatchedDots()
        }
    }
    
    func updateConnectionIndicator(_ status: ConnectionStatus) {
        //print("Меняем индикатор")
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.2) {
                switch status {
                case .disconnected:
                    self.connectionIndicator.backgroundColor = .red
                case .connected:
                    self.connectionIndicator.backgroundColor = .systemBlue
                case .successFlash:
                    self.connectionIndicator.backgroundColor = .systemGreen
                }
            }
            
            if status == .successFlash {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    self.connectionIndicator.backgroundColor = .systemBlue
                }
            }
            //print("Поменяли")
        }
    }
    
    func checkServerConnection() {
        let defaultBaseURL = "91.197.0.41:5252"
        
        let savedBaseURL = UserDefaults.standard.string(forKey: "ServerBaseURL") ?? defaultBaseURL
        
        var fullURLString = "http://\(savedBaseURL)/health"
        
        if savedBaseURL.hasPrefix("http://") || savedBaseURL.hasPrefix("https://") {
            fullURLString = "\(savedBaseURL)/health"
        }
        
        guard let url = URL(string: fullURLString) else {
            DispatchQueue.main.async {
                self.updateConnectionIndicator(.disconnected)
            }
            return
        }
        
        PenHelper.shared.needToConnect = true
        let isConn = PenHelper.shared.isConnected ?? false
        // Предполагаем, что у тебя есть значение для connectedPen
        let connectedPenValue: Any = isConn
            ? (PenHelper.shared.pen?.macAddress ?? "NaN")
            : "NaN"
        
        // или например: let connectedPenValue = true

        let jsonBody: [String: Any] = [
            "connectedPen": connectedPenValue
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5.0
        //print("Connecting to: \(url)")
        
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
            request.httpBody = jsonData
        } catch {
            print("Ошибка сериализации JSON: \(error)")
            DispatchQueue.main.async {
                self.updateConnectionIndicator(.disconnected)
            }
            return  // или continue — решай сам
        }
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            // ВСЁ, что меняет UI — только в main!
            DispatchQueue.main.async {
                if error != nil {
                    self.updateConnectionIndicator(.disconnected)
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 405 {  // 405 тоже нормально — метод не поддерживается, но сервер жив
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 252
                    {
                        if !PenHelper.shared.opened{
                            self.needToConnect = true
                        } else {
                            PenFinder.shared.scanStop()
                            PenFinder.shared.scan(10.0)
                        }
                        
                    } else {
                        self.needToConnect = false
                    }
 
                    self.updateConnectionIndicator(.connected)
                } else {
                    self.updateConnectionIndicator(.disconnected)
                }
            }
        }.resume()
    }
    
    //Second Dot data
    func addDot(_ dot: Dot) {
        DispatchQueue.main.async {
            self.hoverLayer.removeFromSuperlayer() //remove hover when draw stroke

            let type = dot.dotType
            let pointXY = ScaleHelper.shared.getPoint(dot, self.frame.size)
            switch type {
            case .Down:
                self.dotPath.move(to: pointXY)
            case .Move:
                self.dotPath.addLine(to: pointXY)
                self.shapelayer.path = self.dotPath.cgPath
                
            case .Up:
                self.dotPath.removeAllPoints()
                break
            }
        }
        
        // === ИЗМЕНЕНО: Потокобезопасное добавление точки в буфер ===
        // Асинхронно кидаем в нашу очередь, чтобы не блокировать выполнение
        dotBufferQueue.async {
            PenHelper.shared.netBuffer.append(dot)
        }
    }
    
    // === НОВАЯ ФУНКЦИЯ: Пакетная отправка точек ===
    @objc private func sendBatchedDots() {
        var dotsToSend: [Dot] = []
        
        // 1. Потокобезопасно забираем и очищаем буфер
        // Используем sync, чтобы дождаться извлечения массива
        dotBufferQueue.sync {
            guard !PenHelper.shared.netBuffer.isEmpty else { return }
            dotsToSend = PenHelper.shared.netBuffer
            
            // Очищаем буфер, сохраняя выделенную память под массив для оптимизации
            PenHelper.shared.netBuffer.removeAll(keepingCapacity: true)
        }
        
        // Если точек нет — ничего не делаем
        if dotsToSend.isEmpty { return }
        
        // 2. Преобразуем массив [Dot] в массив словарей (JSON Array)
        let jsonArray = dotsToSend.map { dot -> [String: Any] in
            var num_type = -1
            switch dot.dotType {
            case .Down: num_type = 0
            case .Move: num_type = 1
            case .Up: num_type = 2
            }
            
            return [
                "x": dot.x,
                "y": dot.y,
                "force": dot.force,
                "time": dot.time,
                "dotType": num_type,
                "page": dot.pageInfo.page,
                "section": dot.pageInfo.section,
                "owner": dot.pageInfo.owner,
                "note": dot.pageInfo.note
            ]
        }
        
        // 3. Формируем запрос
        let defaultBaseURL = "91.197.0.41:5252"
        let savedBaseURL = UserDefaults.standard.string(forKey: "ServerBaseURL") ?? defaultBaseURL
        var fullURLString = "http://\(savedBaseURL)/api/dots" // ВНИМАНИЕ: сменил на /api/dots (множественное число)
        
        if savedBaseURL.hasPrefix("http://") || savedBaseURL.hasPrefix("https://") {
            fullURLString = "\(savedBaseURL)/api/dots"
        }

        guard let url = URL(string: fullURLString) else { return }
        
        // Сериализуем МАССИВ в JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray) else {
            print("Ошибка сериализации JSON массива")
            return
        }

        // Если у тебя WebSocket (URLSessionWebSocketTask),
        // тут будет: webSocketTask.send(.data(jsonData)) { ... }
        // Ниже классический HTTP вариант, так как URLSession сам переиспользует TCP соединения под капотом (keep-alive)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Ошибка отправки пакета точек: \(error.localizedDescription)")
                self.checkServerConnection() // Можно закомментить, если падает слишком часто
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("Пакет из \(dotsToSend.count) точек успешно отправлен")
                self.updateConnectionIndicator(.successFlash)
            } else {
                print("Сервер ответил с ошибкой на батч-отправку")
                self.updateConnectionIndicator(.disconnected)
            }
        }.resume()
    }
    
    
    //MARK: HoverView
    func addHoverLayout(_ dot: Dot) {
        DispatchQueue.main.async {
            let len = self.hoverRadius
            let currentLocation = ScaleHelper.shared.getPoint(dot, self.frame.size)
            
            let path = UIBezierPath(arcCenter: currentLocation, radius: len, startAngle: 0, endAngle: .pi * 2.0, clockwise: true)
            
            self.hoverLayer.path = path.cgPath
            self.hoverLayer.fillColor = UIColor.orange.cgColor
            self.hoverLayer.strokeColor = UIColor.yellow.cgColor
            self.hoverLayer.lineWidth = self.hoverRadius * 0.05
            self.hoverLayer.opacity = 0.6
            self.layer.addSublayer(self.hoverLayer)
            
        }
    }
}
