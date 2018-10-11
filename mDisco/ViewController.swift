//
//  ViewController.swift
//  mDisco
//
//  Created by Dang on 26/9/18.
//  Copyright © 2018 Dang. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
    var browser: BonjourDiscoverer?
    var service: BonjourService?

    @IBOutlet weak var textView: UITextView!

    @IBAction func restart(_ sender: Any) {
        log(text: "------------------\n")
        stop() {
            self.log(text: "------------------\n")
            self.start()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        // Prevent phone sleep
        UIApplication.shared.isIdleTimerDisabled = true

        // Prevent janking scroll
        textView.layoutManager.allowsNonContiguousLayout = false

        start()
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {

        return true
    }

    func log(text: String) {
        textView.text += text
        let len = textView.text.count
        textView.scrollRangeToVisible(NSMakeRange(len - 1, 0))
    }

    func start() {
        browser = BonjourDiscoverer(type: "_http._tcp.", log: { text in
            self.log(text: "[discovery] \(text)\n")
        })

        service = BonjourService(name: "mDisco", type: "_http._tcp.", port: 80, log: { text in
            self.log(text: "[service] \(text)\n")
        })
    }

    func stop(_ didStop: @escaping () -> Void) {
        if browser != nil {
            browser!.stop() {
                if self.service != nil {
                    self.service!.stop() {
                        didStop()
                    }
                }
            }
        } else {
            if service != nil {
                service!.stop() {
                    didStop()
                }
            }
        }
    }
}

extension Data {
    func toString(encoding: String.Encoding = .utf8) -> String {
        return String(data: self, encoding: encoding)!
    }

    /// Decode the TXT record as a string dictionary, or [:] if the data is malformed
    func toDictionary() -> [String: String] {

        var result = [String: String]()
        var data = self

        while !data.isEmpty {
            // The first byte of each record is its length, so prefix that much data
            let recordLength = Int(data.removeFirst())
            guard data.count >= recordLength else { return [:] }
            let recordData = data[..<(data.startIndex + recordLength)]
            data = data.dropFirst(recordLength)

            guard let record = String(bytes: recordData, encoding: .utf8) else { return [:] }
            // The format of the entry is "key=value"
            // (According to the reference implementation, = is optional if there is no value,
            // and any equals signs after the first are part of the value.)
            // `ommittingEmptySubsequences` is necessary otherwise an empty string will crash the next line
            let keyValue = record.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(keyValue[0])
            // If there's no value, make the value the empty string
            switch keyValue.count {
            case 1:
                result[key] = ""
            case 2:
                result[key] = String(keyValue[1])
            default:
                fatalError()
            }
        }

        return result
    }
}

class BonjourDiscoverer: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var bsr = NetServiceBrowser()
    var services = Set<NetService>()
    var print: (_ text: String) -> Void

    init(domain: String = "", type: String, log: @escaping (_ text: String) -> Void) {
        self.print = log
        super.init()
        print("Searching for \"\(type)\" in domain \"\(domain)\"")
        bsr.delegate = self
        bsr.searchForServices(ofType: type, inDomain: domain)
        bsr.schedule(in: .current, forMode: .default)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("{\(service.name)} found at \"\(service.type)\(service.domain)\"")
        service.delegate = self
        service.startMonitoring()
        service.resolve(withTimeout: 3.0)
        services.insert(service) // keep service from autoreleasing
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        print("{\(sender.name)} resolved at \"\(sender.hostName!)\" on port \(sender.port)")
        if let ipv4 = self.resolveIPv4(addresses: sender.addresses!) {
            print("{\(sender.name)} IP: \(ipv4):\(sender.port)")
        }
        let txt = sender.txtRecordData()
        if (txt != nil) {
            print("{\(sender.name)} TXT: \(txt?.toDictionary() as AnyObject)")
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("{\(sender.name)} resolve failed: \(errorDict)")
        services.remove(sender)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        print("{\(sender.name)} TXT updated: \(data.toDictionary() as AnyObject)")
    }

    // Find an IPv4 addresses from the service address data
    func resolveIPv4(addresses: [Data]) -> String? {
        for addr in addresses {
            let data = addr as NSData
            var storage = sockaddr_storage()
            data.getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)

            if Int32(storage.ss_family) == AF_INET {
                let addr4 = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee
                    }
                }

                if let ip = String(cString: inet_ntoa(addr4.sin_addr), encoding: .ascii) {
                    return ip
                }
            }
        }

        return nil
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("search stop")
    }

    func stop(_ didStop: (() -> Void)? = nil) {
        for svr in services {
            svr.stopMonitoring()
            svr.stop()
        }

        services.removeAll()

        bsr.stop()
        bsr.remove(from: .current, forMode: .default)

        print("stop")
        if didStop != nil {
            didStop!()
        }
    }
}

class BonjourService: NSObject, NetServiceDelegate {
    var svr: NetService!
    var print: (_ text: String) -> Void
    var didStop: (() -> Void)?

    init(domain: String = "", name: String, type: String, port: Int32? = nil, log: @escaping (_ text: String) -> Void) {
        self.print = log
        super.init()
        if port == nil {
            svr = NetService(domain: domain, type: type, name: name)
            svr.delegate = self
            svr.publish(options: .listenForConnections)
        } else {
            svr = NetService(domain: domain, type: type, name: name, port: port!)
            svr.delegate = self
            svr.publish()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { // change 2 to desired number of seconds
            self.print("Gonna update TXT")
            let txtDict = ["hello": "world".data(using: .utf8)!]
            self.svr.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
            self.print("TXT update sent")
        }
    }

    func netServiceWillPublish(_ sender: NetService) {
        print("Gonna publish..")
    }

    func netServiceDidPublish(_ sender: NetService) {
        print("Service published: \(sender.name) at \(sender.type)\(sender.domain) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("Publish failed: \(errorDict)")
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        let oldTxtData = sender.txtRecordData()
        let oldTxtDict = NetService.dictionary(fromTXTRecord: oldTxtData!)
        let oldHello = oldTxtDict["hello"]
        print("old TXT: \(String(describing: oldHello?.toString()))")
        let txtDict = NetService.dictionary(fromTXTRecord: data)
        if let helloObj = txtDict["hello"] {
            print("new TXT: \(helloObj.toString())")
        }
    }

    func netServiceDidStop(_ sender: NetService) {
        print("stop")
        if didStop != nil {
            didStop!()
        }
    }

    func stop(_ didStop: (() -> Void)? = nil) {
        self.didStop = didStop
        svr.stop()
        svr = nil
    }
}
