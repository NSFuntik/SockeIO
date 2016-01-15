//
//  SocketEnginePollable.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 1/15/16.
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

public protocol SocketEnginePollable: SocketEngineSpec {
    var invalidated: Bool { get set }
    var session: NSURLSession? { get }
    var waitingForPoll: Bool { get set }
    var waitingForPost: Bool { get set }
    
    func doPoll()
    func handlePollingFailed(reason: String)
    func sendPollMessage(message: String, withType type: SocketEnginePacketType, withData datas: [NSData])
    func stopPolling()
}

// Default polling methods
extension SocketEnginePollable {
    private func addHeaders(req: NSMutableURLRequest) {
        if cookies != nil {
            let headers = NSHTTPCookie.requestHeaderFieldsWithCookies(cookies!)
            req.allHTTPHeaderFields = headers
        }
        
        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                req.setValue(value, forHTTPHeaderField: headerName)
            }
        }
    }
    
    public func doPoll() {
        if websocket || waitingForPoll || !connected || closed {
            return
        }
        
        waitingForPoll = true
        let req = NSMutableURLRequest(URL: NSURL(string: urlPolling + "&sid=\(sid)&b64=1")!)
        
        addHeaders(req)
        doLongPoll(req)
    }
    
    private func doRequest(req: NSURLRequest,
        withCallback callback: (NSData?, NSURLResponse?, NSError?) -> Void) {
            if !polling || closed || invalidated {
                DefaultSocketLogger.Logger.error("Tried to do polling request when not supposed to", type: "SocketEngine")
                return
            }
            
            DefaultSocketLogger.Logger.log("Doing polling request", type: "SocketEngine")
            
            session?.dataTaskWithRequest(req, completionHandler: callback).resume()
    }
    
    func doLongPoll(req: NSURLRequest) {
        doRequest(req) {[weak self] data, res, err in
            guard let this = self else {return}
            
            if err != nil || data == nil {
                DefaultSocketLogger.Logger.error(err?.localizedDescription ?? "Error", type: "SocketEngine")
                
                if this.polling {
                    this.handlePollingFailed(err?.localizedDescription ?? "Error")
                }
                
                return
            }
            
            DefaultSocketLogger.Logger.log("Got polling response", type: "SocketEngine")
            
            if let str = String(data: data!, encoding: NSUTF8StringEncoding) {
                dispatch_async(this.parseQueue) {
                    this.parsePollingMessage(str)
                }
            }
            
            this.waitingForPoll = false
            
            if this.fastUpgrade {
                this.doFastUpgrade()
            } else if !this.closed && this.polling {
                this.doPoll()
            }
        }
    }
    
    private func flushWaitingForPost() {
        if postWait.count == 0 || !connected {
            return
        } else if websocket {
            flushWaitingForPostToWebSocket()
            return
        }
        
        var postStr = ""
        
        for packet in postWait {
            let len = packet.characters.count
            
            postStr += "\(len):\(packet)"
        }
        
        postWait.removeAll(keepCapacity: false)
        
        let req = NSMutableURLRequest(URL: NSURL(string: urlPolling + "&sid=\(sid)")!)
        
        addHeaders(req)
        
        req.HTTPMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        let postData = postStr.dataUsingEncoding(NSUTF8StringEncoding,
            allowLossyConversion: false)!
        
        req.HTTPBody = postData
        req.setValue(String(postData.length), forHTTPHeaderField: "Content-Length")
        
        waitingForPost = true
        
        DefaultSocketLogger.Logger.log("POSTing: %@", type: "SocketEngine", args: postStr)
        
        doRequest(req) {[weak self] data, res, err in
            guard let this = self else {return}
            
            if err != nil {
                DefaultSocketLogger.Logger.error(err?.localizedDescription ?? "Error", type: "SocketEngine")
                
                if this.polling {
                    this.handlePollingFailed(err?.localizedDescription ?? "Error")
                }
                
                return
            }
            
            this.waitingForPost = false
            
            dispatch_async(this.emitQueue) {
                if !this.fastUpgrade {
                    this.flushWaitingForPost()
                    this.doPoll()
                }
            }
        }
    }
    
    func parsePollingMessage(str: String) {
        guard str.characters.count != 1 else {
            return
        }
        
        var reader = SocketStringReader(message: str)
        
        while reader.hasNext {
            if let n = Int(reader.readUntilStringOccurence(":")) {
                let str = reader.read(n)
                
                dispatch_async(handleQueue) {
                    self.parseEngineMessage(str, fromPolling: true)
                }
            } else {
                dispatch_async(handleQueue) {
                    self.parseEngineMessage(str, fromPolling: true)
                }
                break
            }
        }
    }
    
    /// Send polling message.
    /// Only call on emitQueue
    public func sendPollMessage(message: String, withType type: SocketEnginePacketType,
        withData datas: [NSData]) {
            DefaultSocketLogger.Logger.log("Sending poll: %@ as type: %@", type: "SocketEngine", args: message, type.rawValue)
            let fixedMessage = doubleEncodeUTF8(message)
            let strMsg = "\(type.rawValue)\(fixedMessage)"
            
            postWait.append(strMsg)
            
            for data in datas {
                if case let .Right(bin) = createBinaryDataForSend(data) {
                    postWait.append(bin)
                }
            }
            
            if !waitingForPost {
                flushWaitingForPost()
            }
    }
    
    public func stopPolling() {
        invalidated = true
        session?.finishTasksAndInvalidate()
    }
}