// Copyright (c) 2014 Intel Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import WebKit
import SwiftyJSON

public class XWalkExtension: NSObject, WKScriptMessageHandler {
    public final var namespace: String = ""
    public final var id: Int = 0
    internal weak var webView: WKWebView?

    private var seqenceNumber : Int {
        struct seq{
            static var num: Int = 0
        }
        return ++seq.num
    }

    public var jsAPIStub: String {
        var jsapi: String = ""

        // Generate JavaScript through introspection
        for var mlist = class_copyMethodList(self.dynamicType, nil); mlist.memory != nil; mlist = mlist.successor() {
            let method:String = NSStringFromSelector(method_getName(mlist.memory))
            if method.hasPrefix("jsfunc_") && method.hasSuffix(":") {
                var args = method.componentsSeparatedByString(":")
                let name = args.first!.substringFromIndex(advance(method.startIndex, 7))
                args.removeAtIndex(0)
                args.removeLast()

                var stub = "this.invokeNative(\"\(name)\", ["
                var isPromise = false
                for a in args {
                    if a != "_Promise" {
                        stub += "\n        {'\(a)': \(a)},"
                    } else {
                        assert(!isPromise)
                        isPromise = true
                        stub += "\n        {'\(a)': [resolve, reject]},"
                    }
                }
                if args.count > 0 {
                    stub.removeAtIndex(stub.endIndex.predecessor())
                }
                stub += "\n    ]);"
                if isPromise {
                    stub = "\n    ".join(stub.componentsSeparatedByString("\n"))
                    stub = "var _this = this;\n    return new Promise(function(resolve, reject) {\n        _" + stub + "\n    });"
                }
                stub = "exports.\(name) = function(" + ", ".join(args) + ") {\n    \(stub)\n}"
                jsapi += "\(stub)\n"
            } else if method.hasPrefix("jsprop_") && !method.hasSuffix(":") {
                let name = method.substringFromIndex(advance(method.startIndex, 7))
                let writable = self.dynamicType.instancesRespondToSelector(NSSelectorFromString("setJsprop_\(name):"))
                var val: AnyObject = self[name]!
                if val.isKindOfClass(NSString.classForCoder()) {
                    val = NSString(format: "'\(val as String)'")
                }
                jsapi += "exports.defineProperty('\(name)', \(JSON(val).rawString()!), \(writable));\n"
            }
        }

        // Append the content of stub file if exist.
        let bundle : NSBundle = NSBundle(forClass: self.dynamicType)
        var fileName = NSStringFromClass(self.dynamicType)
        fileName = fileName.pathExtension.isEmpty ? fileName : fileName.pathExtension
        if let path = bundle.pathForResource(fileName, ofType: "js") {
            if let file = NSFileHandle(forReadingAtPath: path) {
                if let txt = NSString(data: file.readDataToEndOfFile(), encoding: NSUTF8StringEncoding) {
                    jsapi += txt
                } else {
                    NSException(name: "EncodingError", reason: "The encoding of .js file must be UTF-8.", userInfo: nil).raise()
                }
            }
        }

        return jsapi
    }

    public func attach(webView: WKWebView, namespace: String? = nil) {
        if namespace != nil && !namespace!.isEmpty {
            self.namespace = namespace!
        } else if let defaultNamespace = XWalkExtensionFactory.singleton.getNameByClass(self.dynamicType) {
            self.namespace = defaultNamespace
        } else {
            NSException(name: "NoNamespace", reason: "JavaScript namespace is undetermined.", userInfo: nil).raise()
        }
        self.webView = webView

        // Establish the message channel
        id = seqenceNumber
        webView.MakeExtensible()
        webView.configuration.userContentController.addScriptMessageHandler(self, name: "\(id)")

        // Inject JavaScript API
        let code = "(function(exports) {\n\n" +
            "'use strict';\n" +
            "\(jsAPIStub)\n\n" +
            "})(Extension.create(\(id), '\(self.namespace)'));"
        webView.injectScript(code)
    }

    public func detach() {
        let controller = webView!.configuration.userContentController
        controller.removeScriptMessageHandlerForName("\(id)")
        // TODO: How to remove user script?
        //controller.userScripts.removeAtIndex(id)
        if webView!.URL != nil {
            // Cleanup extension code in current context
            evaluate("delete \(namespace);")
        }
        webView = nil
        id = 0
    }

    public func userContentController(userContentController: WKUserContentController,
        didReceiveScriptMessage message: WKScriptMessage) {
        let body = message.body as [String: AnyObject]
        if let method = body["method"] as? String {
            // Method call
            if let args = body["arguments"] as? [[String: AnyObject]] {
                if args.filter({$0 == [:]}).count > 0 {
                    // WKWebKit can't handle undefined type well
                    println("ERROR: parameters contain undefined value")
                    return
                }
                let inv = Invocation(name: "jsfunc_" + method)
                inv.appendArgument("cid", value: body["callid"])
                for a in args {
                    for (k, v) in a {
                        inv.appendArgument(k, value: v is NSNull ? nil : v)
                    }
                }
                if let result = inv.call(self) {
                    if result.isBool {
                        if result.boolValue {
                            invokeJavaScript(".releaseArguments", arguments: [body["callid"]!])
                        }
                    } else {
                        NSException(name: "TypeError", reason: "The return value of native method must be BOOL type.", userInfo: nil).raise()
                    }
                }
            }
        } else if let prop = body["property"] as? String {
            // Property setting
            let inv = Invocation(name: "setJsprop_\(prop)")
            inv.appendArgument("val", value: body["value"])
            inv.call(self)
        } else {
            // TODO: support user defined message?
            println("ERROR: Unknown message: \(body)")
        }
    }

    public func invokeCallback(id: UInt32, key: String? = nil, arguments: [AnyObject] = []) {
        let args = NSArray(array: [NSNumber(unsignedInt: id), key ?? NSNull(), arguments])
        invokeJavaScript(".invokeCallback", arguments: args)
    }
    public func invokeCallback(id: UInt32, index: UInt32, arguments: [AnyObject] = []) {
        let args = NSArray(array: [NSNumber(unsignedInt: id), NSNumber(unsignedInt: index), arguments])
        invokeJavaScript(".invokeCallback", arguments: args)
    }
    public func invokeJavaScript(function: String, arguments: [AnyObject] = []) {
        var f = function
        var this = "null"
        if f[f.startIndex] == "." {
            // Invoke a method of this object
            f = namespace + function
            this = namespace
        }
        if let json = JSON(arguments).rawString() {
            evaluate("\(f).apply(\(this), \(json));")
        } else {
            println("ERROR: Invalid argument list: \(arguments)")
        }
    }

    public subscript(name: String) -> AnyObject? {
        get {
            let inv = Invocation(name: "jsprop_\(name)")
            if let result = inv.call(self) {
                if let obj: AnyObject = result.object ?? result.number {
                    return obj
                } else {
                    NSException(name: "TypeError", reason: "Unknown return type of property's getter.", userInfo: nil).raise()
                }
            } else {
                NSException(name: "NoSuchPropery", reason: "Property is not defined on native side.", userInfo: nil).raise()
            }
            return nil
        }
        set(value) {
            var val: AnyObject = value ?? NSNull()
            if val.isKindOfClass(NSString.classForCoder()) {
                val = NSString(format: "'\(val as String)'")
            }
            let json = JSON(val).rawString()!
            let cmd = "\(namespace).\(name) = \(json);"
            evaluate(cmd)
            // Native property updating will be triggered by JavaScrpt property setter.
        }
    }

    public override func doesNotRecognizeSelector(aSelector: Selector) {
        // TODO: throw an exception to JavaScript context
        let method = NSStringFromSelector(aSelector)
        println("ERROR: Native method '\(method)' not found in extension '\(namespace)'")
    }
}

extension XWalkExtension {
    // Helper functions to evaluate JavaScript
    public func evaluate(string: String) {
        evaluate(string, success: nil)
    }
    public func evaluate(string: String, error: ((NSError)->Void)?) {
        evaluate(string, completionHandler: { (obj, err)->Void in
            if err != nil { error?(err) }
        })
    }
    public func evaluate(string: String, success: ((AnyObject!)->Void)?) {
        evaluate(string, completionHandler: { (obj, err) -> Void in
            err == nil ? success?(obj) : println("ERROR: Failed to execute script, \(err)\n------------\n\(string)\n------------")
            return    // To make compiler happy
        })
    }
    public func evaluate(string: String, success: ((AnyObject!)->Void)?, error: ((NSError!)->Void)?) {
        evaluate(string, completionHandler: { (obj, err)->Void in
            err == nil ? success?(obj) : error?(err)
            return    // To make compiler happy
        })
    }
    public func evaluate(string: String, completionHandler: ((AnyObject!, NSError!)->Void)?) {
        // TODO: Should call completionHandler with an NSError object when webView is nil
        webView?.evaluateJavaScript(string, completionHandler: completionHandler)
    }
}
