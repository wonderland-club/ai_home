//
//  MQTTWebSocketTransport.swift
//  ai_home
//
//  Copied and adapted from CocoaMQTT's CocoaMQTTWebSocket implementation
//  (https://github.com/emqx/CocoaMQTT, MIT License).
//  Patched to build with Starscream 4 by adjusting delegate signatures.
//

import Foundation
import Starscream
import CocoaMQTT

// MARK: - Interfaces

protocol MQTTWebSocketConnectionDelegate: AnyObject {
    func connection(_ conn: MQTTWebSocketConnection, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void)
    func urlSessionConnection(_ conn: MQTTWebSocketConnection, didReceiveTrust trust: SecTrust, didReceiveChallenge challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    func connectionOpened(_ conn: MQTTWebSocketConnection)
    func connectionClosed(_ conn: MQTTWebSocketConnection, withError error: Error?, withCode code: UInt16?)
    func connection(_ conn: MQTTWebSocketConnection, receivedString string: String)
    func connection(_ conn: MQTTWebSocketConnection, receivedData data: Data)
}

protocol MQTTWebSocketConnection: AnyObject {
    var delegate: MQTTWebSocketConnectionDelegate? { get set }
    func connect()
    func disconnect()
    var queue: DispatchQueue? { get set }
    func write(string: String, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void)
    func write(data: Data, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void)
}

// MARK: - MQTTWebSocket

final class MQTTWebSocket: CocoaMQTTSocketProtocol {

    var enableSSL = false
    var shouldConnectWithURIOnly = false
    var headers: [String: String] = [:]

    private let uri: String
    private let builder: MQTTWebSocketConnectionBuilder
    private var connection: MQTTWebSocketConnection?
    private weak var delegate: CocoaMQTTSocketDelegate?
    private var delegateQueue: DispatchQueue?
    private let internalQueue = DispatchQueue(label: "MQTTWebSocket")

    private struct ReadItem {
        let tag: Int
        let length: UInt
    }

    private var readBuffer = Data()
    private var scheduledReads: [ReadItem] = []

    init(uri: String = "", builder: MQTTWebSocketConnectionBuilder = MQTTWebSocket.DefaultConnectionBuilder()) {
        self.uri = uri
        self.builder = builder
    }

    func setDelegate(_ theDelegate: CocoaMQTTSocketDelegate?, delegateQueue: DispatchQueue?) {
        internalQueue.async {
            self.delegate = theDelegate
            self.delegateQueue = delegateQueue
        }
    }

    func connect(toHost host: String, onPort port: UInt16) throws {
        try connect(toHost: host, onPort: port, withTimeout: -1)
    }

    func connect(toHost host: String, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        var urlStr = ""
        if shouldConnectWithURIOnly {
            urlStr = uri
        } else {
            urlStr = "\(enableSSL ? "wss" : "ws")://\(host):\(port)\(uri)"
        }
        guard let url = URL(string: urlStr) else { throw CocoaMQTTError.invalidURL }
        try internalQueue.sync {
            connection?.disconnect()
            connection?.delegate = nil
            let newConnection = try builder.buildConnection(forURL: url, withHeaders: headers)
            connection = newConnection
            newConnection.delegate = self
            newConnection.queue = internalQueue
            newConnection.connect()
        }
    }

    func disconnect() {
        internalQueue.async {
            self.closeConnection(withError: nil)
        }
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        internalQueue.async {
            let newRead = ReadItem(tag: tag, length: length)
            self.scheduledReads.append(newRead)
            self.checkScheduledReads()
        }
    }

    func write(_ data: Data, withTimeout timeout: TimeInterval, tag: Int) {
        internalQueue.async {
            self.connection?.write(data: data, timeout: timeout) { possibleError in
                if let error = possibleError {
                    self.closeConnection(withError: error)
                } else {
                    guard let delegate = self.delegate else { return }
                    self.__delegate_queue {
                        delegate.socket(self, didWriteDataWithTag: tag)
                    }
                }
            }
        }
    }
}

// MARK: - Builders

protocol MQTTWebSocketConnectionBuilder {
    func buildConnection(forURL url: URL, withHeaders headers: [String: String]) throws -> MQTTWebSocketConnection
}

extension MQTTWebSocket {
    struct DefaultConnectionBuilder: MQTTWebSocketConnectionBuilder {
        func buildConnection(forURL url: URL, withHeaders headers: [String: String]) throws -> MQTTWebSocketConnection {
            if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
                let config = URLSessionConfiguration.default
                config.httpAdditionalHeaders = headers
                return URLSessionConnection(url: url, config: config)
            } else {
                var request = URLRequest(url: url)
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                return StarscreamConnection(request: request)
            }
        }
    }
}

// MARK: - URLSessionConnection

extension MQTTWebSocket {
    final class URLSessionConnection: NSObject, MQTTWebSocketConnection {
        weak var delegate: MQTTWebSocketConnectionDelegate?
        var queue: DispatchQueue?

        private let url: URL
        private let config: URLSessionConfiguration
        private lazy var session: URLSession = {
            URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }()
        private var task: URLSessionWebSocketTask?
        init(url: URL, config: URLSessionConfiguration) {
            self.url = url
            self.config = config
        }

        func connect() {
            let task = session.webSocketTask(with: url)
            self.task = task
            task.resume()
            listen()
        }

        func disconnect() {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }

        func write(string: String, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void) {
            task?.send(.string(string), completionHandler: completionHandler)
        }

        func write(data: Data, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void) {
            task?.send(.data(data), completionHandler: completionHandler)
        }

        private func listen() {
            task?.receive { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let value):
                        self.queue?.async { self.delegate?.connection(self, receivedString: value) }
                    case .data(let data):
                        self.queue?.async { self.delegate?.connection(self, receivedData: data) }
                    @unknown default:
                        break
                    }
                    self.listen()
                case .failure(let error):
                    self.queue?.async { self.delegate?.connectionClosed(self, withError: error, withCode: nil) }
                }
            }
        }

    }
}

extension MQTTWebSocket.URLSessionConnection: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue?.async { self.delegate?.connectionOpened(self) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue?.async { self.delegate?.connectionClosed(self, withError: nil, withCode: UInt16(closeCode.rawValue)) }
    }
}

extension MQTTWebSocket.URLSessionConnection: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - StarscreamConnection

extension MQTTWebSocket {
    final class StarscreamConnection: NSObject, MQTTWebSocketConnection {
        weak var delegate: MQTTWebSocketConnectionDelegate?
        var queue: DispatchQueue?

        private let request: URLRequest
        private lazy var socket: Starscream.WebSocket = {
            Starscream.WebSocket(request: request)
        }()

        init(request: URLRequest) {
            self.request = request
        }

        func connect() {
            socket.delegate = self
            socket.callbackQueue = queue ?? DispatchQueue.main
            socket.connect()
        }

        func disconnect() {
            socket.disconnect()
        }

        func write(string: String, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void) {
            socket.write(string: string) {
                completionHandler(nil)
            }
        }

        func write(data: Data, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void) {
            socket.write(data: data) {
                completionHandler(nil)
            }
        }
    }
}

extension MQTTWebSocket.StarscreamConnection: MQTTWebSocketConnectionDelegate {
    func connection(_ conn: MQTTWebSocketConnection, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        delegate?.connection(conn, didReceive: trust, completionHandler: completionHandler)
    }

    func urlSessionConnection(_ conn: MQTTWebSocketConnection, didReceiveTrust trust: SecTrust, didReceiveChallenge challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        delegate?.urlSessionConnection(conn, didReceiveTrust: trust, didReceiveChallenge: challenge, completionHandler: completionHandler)
    }

    func connectionOpened(_ conn: MQTTWebSocketConnection) {
        delegate?.connectionOpened(conn)
    }

    func connectionClosed(_ conn: MQTTWebSocketConnection, withError error: Error?, withCode code: UInt16?) {
        delegate?.connectionClosed(conn, withError: error, withCode: code)
    }

    func connection(_ conn: MQTTWebSocketConnection, receivedString string: String) {
        delegate?.connection(conn, receivedString: string)
    }

    func connection(_ conn: MQTTWebSocketConnection, receivedData data: Data) {
        delegate?.connection(conn, receivedData: data)
    }
}

extension MQTTWebSocket.StarscreamConnection: Starscream.WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected:
            delegate?.connectionOpened(self)
        case .disconnected(_, let code):
            delegate?.connectionClosed(self, withError: nil, withCode: code)
        case .text(let string):
            delegate?.connection(self, receivedString: string)
        case .binary(let data):
            delegate?.connection(self, receivedData: data)
        case .cancelled:
            delegate?.connectionClosed(self, withError: nil, withCode: nil)
        case .error(let error):
            delegate?.connectionClosed(self, withError: error, withCode: nil)
        default:
            break
        }
    }
}

// MARK: - CocoaMQTTSocketDelegate Bridge

extension MQTTWebSocket: MQTTWebSocketConnectionDelegate {
    func connection(_ conn: MQTTWebSocketConnection, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func urlSessionConnection(_ conn: MQTTWebSocketConnection, didReceiveTrust trust: SecTrust, didReceiveChallenge challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func connectionOpened(_ conn: MQTTWebSocketConnection) {
        __delegate_queue { self.delegate?.socketConnected(self) }
    }

    func connectionClosed(_ conn: MQTTWebSocketConnection, withError error: Error?, withCode code: UInt16?) {
        closeConnection(withError: error)
    }

    func connection(_ conn: MQTTWebSocketConnection, receivedString string: String) {
        guard let data = string.data(using: .utf8) else { return }
        queueRead(data: data)
    }

    func connection(_ conn: MQTTWebSocketConnection, receivedData data: Data) {
        queueRead(data: data)
    }
}

// MARK: - Helpers

private extension MQTTWebSocket {
    func checkScheduledReads() {
        guard !scheduledReads.isEmpty else { return }
        guard !readBuffer.isEmpty else { return }
        let read = scheduledReads.removeFirst()
        if readBuffer.count >= read.length {
            let range = 0..<Int(read.length)
            let data = readBuffer.subdata(in: range)
            readBuffer.removeSubrange(range)
            __delegate_queue { self.delegate?.socket(self, didRead: data, withTag: read.tag) }
        } else {
            scheduledReads.insert(read, at: 0)
        }
    }

    func queueRead(data: Data) {
        readBuffer.append(data)
        checkScheduledReads()
    }

    func closeConnection(withError error: Error?) {
        reset()
        __delegate_queue { self.delegate?.socketDidDisconnect(self, withError: error) }
    }

    func reset() {
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
        readBuffer.removeAll()
        scheduledReads.removeAll()
    }

    func __delegate_queue(_ action: @escaping () -> Void) {
        if let delegateQueue = delegateQueue {
            delegateQueue.async(execute: action)
        } else {
            action()
        }
    }

}
