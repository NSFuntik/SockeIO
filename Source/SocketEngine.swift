//
//  SocketEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/3/15.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

public final class SocketEngine : NSObject, SocketEnginePollable, SocketEngineWebsocket {
    public let emitQueue = DispatchQueue(label: "com.socketio.engineEmitQueue", attributes: DispatchQueueAttributes.serial, target: nil) //dispatch_queue_create("com.socketio.engineEmitQueue", DispatchQueueAttributes.serial)
    public let handleQueue = DispatchQueue(label: "com.socketio.engineHandleQueue", attributes: DispatchQueueAttributes.serial, target: nil)// dispatch_queue_create("com.socketio.engineHandleQueue", DispatchQueueAttributes.serial)
    public let parseQueue = DispatchQueue(label: "com.socketio.engineParseQueue", attributes: DispatchQueueAttributes.serial, target: nil)//dispatch_queue_create("com.socketio.engineParseQueue", DispatchQueueAttributes.serial)

    public var connectParams: [String: AnyObject]? {
        didSet {
            (urlPolling, urlWebSocket) = createURLs()
        }
    }
    
    public var postWait = [String]()
    public var waitingForPoll = false
    public var waitingForPost = false
    
    public private(set) var closed = false
    public private(set) var connected = false
    public private(set) var cookies: [HTTPCookie]?
    public private(set) var doubleEncodeUTF8 = true
    public private(set) var extraHeaders: [String: String]?
    public private(set) var fastUpgrade = false
    public private(set) var forcePolling = false
    public private(set) var forceWebsockets = false
    public private(set) var invalidated = false
    public private(set) var polling = true
    public private(set) var probing = false
    public private(set) var session: URLSession?
    public private(set) var sid = ""
    public private(set) var socketPath = "/engine.io/"
    public private(set) var urlPolling = NSURL()
    public private(set) var urlWebSocket = NSURL()
    public private(set) var websocket = false
    public private(set) var ws: WebSocket?

    public weak var client: SocketEngineClient?
    
    private weak var sessionDelegate: URLSessionDelegate?

    private let logType = "SocketEngine"
    private let url: NSURL
    
    private var pingInterval: Double?
    private var pingTimeout = 0.0 {
        didSet {
            pongsMissedMax = Int(pingTimeout / (pingInterval ?? 25))
        }
    }
    
    private var pongsMissed = 0
    private var pongsMissedMax = 0
    private var probeWait = ProbeWaitQueue()
    private var secure = false
    private var security: SSLSecurity?
    private var selfSigned = false
    private var voipEnabled = false

    public init(client: SocketEngineClient, url: NSURL, options: Set<SocketIOClientOption>) {
        self.client = client
        self.url = url
        
        for option in options {
            switch option {
            case let .ConnectParams(params):
                connectParams = params
            case let .Cookies(cookies):
                self.cookies = cookies
            case let .DoubleEncodeUTF8(encode):
                doubleEncodeUTF8 = encode
            case let .ExtraHeaders(headers):
                extraHeaders = headers
            case let .SessionDelegate(delegate):
                sessionDelegate = delegate
            case let .ForcePolling(force):
                forcePolling = force
            case let .ForceWebsockets(force):
                forceWebsockets = force
            case let .Path(path):
                socketPath = path
            case let .VoipEnabled(enable):
                voipEnabled = enable
            case let .Secure(secure):
                self.secure = secure
            case let .Security(security):
                self.security = security
            case let .SelfSigned(selfSigned):
                self.selfSigned = selfSigned
            default:
                continue
            }
        }
        
        super.init()
        
        (urlPolling, urlWebSocket) = createURLs()
    }
    
    public convenience init(client: SocketEngineClient, url: NSURL, options: NSDictionary?) {
        self.init(client: client, url: url, options: options?.toSocketOptionsSet() ?? [])
    }
    
    deinit {
        DefaultSocketLogger.Logger.log(message: "Engine is being released", type: logType)
        closed = true
        stopPolling()
    }
    
    private func checkAndHandleEngineError(msg: String) {
        guard let stringData = msg.data(using: String.Encoding.utf8,
            allowLossyConversion: false) else { return }
        
        do {
            if let dict = try JSONSerialization.jsonObject(with:stringData, options: .mutableContainers) as? NSDictionary {
                guard let error = dict["message"] as? String else { return }
                
                /*
                 0: Unknown transport
                 1: Unknown sid
                 2: Bad handshake request
                 3: Bad request
                 */
                didError(error: error)
            }
        } catch {
            didError(error: "Got unknown error from server \(msg)")
        }
    }

    private func checkIfMessageIsBase64Binary(message: String) -> Bool {
        if message.hasPrefix("b4") {
            // binary in base64 string
            let noPrefix = message[message.index(message.startIndex, offsetBy: 2)..<message.endIndex]

            if let data = NSData(base64Encoded: noPrefix, options: .ignoreUnknownCharacters) {
                client?.parseEngineBinaryData(data: data)
            }
            
            return true
        } else {
            return false
        }
    }
    
    private func closeOutEngine() {
        sid = ""
        closed = true
        invalidated = true
        connected = false
        
        ws?.disconnect()
        stopPolling()
    }
    
    /// Starts the connection to the server
    public func connect() {
        if connected {
            DefaultSocketLogger.Logger.error(message: "Engine tried opening while connected. Assuming this was a reconnect", type: logType)
            disconnect(reason: "reconnect")
        }
        
        DefaultSocketLogger.Logger.log(message: "Starting engine. Server: %@", type: logType, args: url)
        DefaultSocketLogger.Logger.log(message: "Handshaking", type: logType)
        
        resetEngine()
        
        if forceWebsockets {
            polling = false
            websocket = true
            createWebsocketAndConnect()
            return
        }
        
        let reqPolling = NSMutableURLRequest(url: urlPolling as URL)
        
        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }
        
        if let extraHeaders = extraHeaders {
            for (headerName, value) in extraHeaders {
                reqPolling.setValue(value, forHTTPHeaderField: headerName)
            }
        }
        
        emitQueue.async { 
            self.doLongPoll(req: reqPolling)
        }
    }

    private func createURLs() -> (NSURL, NSURL) {
        if client == nil {
            return (NSURL(), NSURL())
        }

        let urlPolling = NSURLComponents(string: url.absoluteString!)!
        let urlWebSocket = NSURLComponents(string: url.absoluteString!)!
        var queryString = ""
        
        urlWebSocket.path = socketPath
        urlPolling.path = socketPath

        if secure {
            urlPolling.scheme = "https"
            urlWebSocket.scheme = "wss"
        } else {
            urlPolling.scheme = "http"
            urlWebSocket.scheme = "ws"
        }

        if connectParams != nil {
            for (key, value) in connectParams! {
                let keyEsc   = key.urlEncode()!
                let valueEsc = "\(value)".urlEncode()!

                queryString += "&\(keyEsc)=\(valueEsc)"
            }
        }

        urlWebSocket.percentEncodedQuery = "transport=websocket" + queryString
        urlPolling.percentEncodedQuery = "transport=polling&b64=1" + queryString
        
        return (urlPolling.url!, urlWebSocket.url!)
    }

    private func createWebsocketAndConnect() {
        ws = WebSocket(url: urlWebSocketWithSid)
        
        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            for (key, value) in headers {
                ws?.headers[key] = value
            }
        }

        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                ws?.headers[headerName] = value
            }
        }

        ws?.queue = handleQueue
        ws?.voipEnabled = voipEnabled
        ws?.delegate = self
        ws?.selfSignedSSL = selfSigned
        ws?.security = security

        ws?.connect()
    }
    
    public func didError(error: String) {
        DefaultSocketLogger.Logger.error(message: "%@", type: logType, args: error)
        client?.engineDidError(reason: error)
        disconnect(reason: error)
    }
    
    public func disconnect(reason: String) {
        guard connected else { return closeOutEngine() }
        
        DefaultSocketLogger.Logger.log(message: "Engine is being closed.", type: logType)
        
        if closed {
            closeOutEngine()
            client?.engineDidClose(reason: reason)
            return
        }
        
        if websocket {
            sendWebSocketMessage(str: "", withType: .Close, withData: [])
            closeOutEngine()
        } else {
            disconnectPolling()
        }
    }
    
    // We need to take special care when we're polling that we send it ASAP
    // Also make sure we're on the emitQueue since we're touching postWait
    private func disconnectPolling() {
        
        emitQueue.async { 
            
            self.postWait.append(String(SocketEnginePacketType.Close.rawValue))
            let req = self.createRequestForPostWithPostWait()
            self.doRequest(req: req) {_, _, _ in }
            self.closeOutEngine()

        }
    }

    public func doFastUpgrade() {
        if waitingForPoll {
            DefaultSocketLogger.Logger.error(message: "Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", type: logType)
        }

        sendWebSocketMessage(str: "", withType: .Upgrade, withData: [])
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    private func flushProbeWait() {
        DefaultSocketLogger.Logger.log(message: "Flushing probe wait", type: logType)

        emitQueue.async { 
            
            for waiter in self.probeWait {
                self.write(msg: waiter.msg, withType: waiter.type, withData: waiter.data)
            }
            
            self.probeWait.removeAll(keepingCapacity: false)
            
            if self.postWait.count != 0 {
                self.flushWaitingForPostToWebSocket()
            }
        }
    }
    
    // We had packets waiting for send when we upgraded
    // Send them raw
    public func flushWaitingForPostToWebSocket() {
        guard let ws = self.ws else { return }
        
        for msg in postWait {
            ws.writeString(str: msg)
        }
        
        postWait.removeAll(keepingCapacity: true)
    }

    private func handleClose(reason: String) {
        client?.engineDidClose(reason: reason)
    }

    private func handleMessage(message: String) {
        client?.parseEngineMessage(msg: message)
    }

    private func handleNOOP() {
        doPoll()
    }

    private func handleOpen(openData: String) {
        let mesData = openData.data(using: String.Encoding.utf8, allowLossyConversion: false)!
        do {
            let json = try JSONSerialization.jsonObject(with:mesData,
                options: JSONSerialization.ReadingOptions.allowFragments) as? NSDictionary
            if let sid = json?["sid"] as? String {
                let upgradeWs: Bool

                self.sid = sid
                connected = true

                if let upgrades = json?["upgrades"] as? [String] {
                    upgradeWs = upgrades.contains("websocket")
                } else {
                    upgradeWs = false
                }

                if let pingInterval = json?["pingInterval"] as? Double, pingTimeout = json?["pingTimeout"] as? Double {
                    self.pingInterval = pingInterval / 1000.0
                    self.pingTimeout = pingTimeout / 1000.0
                }

                if !forcePolling && !forceWebsockets && upgradeWs {
                    createWebsocketAndConnect()
                }
                
                sendPing()
                
                if !forceWebsockets {
                    doPoll()
                }
                
                client?.engineDidOpen(reason: "Connect")
            }
        } catch {
            didError(error: "Error parsing open packet")
        }
    }

    private func handlePong(pongMessage: String) {
        pongsMissed = 0

        // We should upgrade
        if pongMessage == "3probe" {
            upgradeTransport()
        }
    }
    
    public func parseEngineData(data: NSData) {
        DefaultSocketLogger.Logger.log(message: "Got binary data: %@", type: "SocketEngine", args: data)
        client?.parseEngineBinaryData(data: data.subdata(with: NSMakeRange(1, data.length - 1)))
    }

    public func parseEngineMessage(message: String, fromPolling: Bool) {
        DefaultSocketLogger.Logger.log(message: "Got message: %@", type: logType, args: message)
        
        let reader = SocketStringReader(message: message)
        let fixedString: String

        guard let type = SocketEnginePacketType(rawValue: Int(reader.currentCharacter) ?? -1) else {
            if !checkIfMessageIsBase64Binary(message: message) {
                checkAndHandleEngineError(msg: message)
            }
            
            return
        }

        if fromPolling && type != .Noop && doubleEncodeUTF8 {
            fixedString = fixDoubleUTF8(string: message)
        } else {
            fixedString = message
        }

        switch type {
        case .Message:
            handleMessage(message: fixedString[fixedString.index(after: fixedString.startIndex)..<fixedString.endIndex])
        case .Noop:
            handleNOOP()
        case .Pong:
            handlePong(pongMessage: fixedString)
        case .Open:
            handleOpen(openData: fixedString[fixedString.index(after: fixedString.startIndex)..<fixedString.endIndex])
        case .Close:
            handleClose(reason: fixedString)
        default:
            DefaultSocketLogger.Logger.log(message: "Got unknown packet type", type: logType)
        }
    }
    
    // Puts the engine back in its default state
    private func resetEngine() {
        closed = false
        connected = false
        fastUpgrade = false
        polling = true
        probing = false
        invalidated = false
        session = URLSession(configuration: .default(),
            delegate: sessionDelegate,
            delegateQueue: OperationQueue())
        sid = ""
        waitingForPoll = false
        waitingForPost = false
        websocket = false
    }

    private func sendPing() {
        if !connected {
            return
        }
        
        //Server is not responding
        if pongsMissed > pongsMissedMax {
            client?.engineDidClose(reason: "Ping timeout")
            return
        }
        
        if let pingInterval = pingInterval {
            pongsMissed += 1
            write(msg: "", withType: .Ping, withData: [])
            
            let time = DispatchTime.now() + Double(Int64(pingInterval * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
            
            DispatchQueue.main.after(when: time, execute: { 
                
                self.sendPing()
            })
        }
    }
    
    // Moves from long-polling to websockets
    private func upgradeTransport() {
        if ws?.isConnected ?? false {
            DefaultSocketLogger.Logger.log(message: "Upgrading transport to WebSockets", type: logType)

            fastUpgrade = true
            sendPollMessage(message: "", withType: .Noop, withData: [])
            // After this point, we should not send anymore polling messages
        }
    }

    /// Write a message, independent of transport.
    public func write(msg: String, withType type: SocketEnginePacketType, withData data: [NSData]) {
        
        emitQueue.async { 
            
            guard self.connected else { return }
            
            if self.websocket {
                DefaultSocketLogger.Logger.log(message: "Writing ws: %@ has data: %@",
                                               type: self.logType, args: msg, data.count != 0)
                self.sendWebSocketMessage(str: msg, withType: type, withData: data)
            } else if !self.probing {
                DefaultSocketLogger.Logger.log(message: "Writing poll: %@ has data: %@",
                                               type: self.logType, args: msg, data.count != 0)
                self.sendPollMessage(message: msg, withType: type, withData: data)
            } else {
                self.probeWait.append((msg, type, data))
            }
        }
    }
    
    // Delegate methods
    public func websocketDidConnect(socket: WebSocket) {
        if !forceWebsockets {
            probing = true
            probeWebSocket()
        } else {
            connected = true
            probing = false
            polling = false
        }
    }
    
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
        probing = false
        
        if closed {
            client?.engineDidClose(reason: "Disconnect")
            return
        }
        
        if websocket {
            connected = false
            websocket = false
            
            if let reason = error?.localizedDescription {
                didError(error: reason)
            } else {
                client?.engineDidClose(reason: "Socket Disconnected")
            }
        } else {
            flushProbeWait()
        }
    }
}
