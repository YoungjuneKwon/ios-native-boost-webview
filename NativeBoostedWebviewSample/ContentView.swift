import SwiftUI
@preconcurrency import WebKit

struct ContentView: View {
    var body: some View {
        VStack {
            WebViewWrapper(
                urlString: "custom-http://8090.yjkwon.iscream.0.winm2m.com/mobile/help/faq",
                cacheListURL: "http://8090.yjkwon.iscream.0.winm2m.com/files/cachelist.json")
            .edgesIgnoringSafeArea(.all)
        }
    }
}

// UIViewRepresentable을 사용해 WKWebView를 SwiftUI 뷰로 변환
struct WebViewWrapper: UIViewRepresentable {
    let urlString: String
    let cacheListURL: String

    // 바이너리 데이터를 저장할 딕셔너리
    static var preloadedData: [String: Data] = [:]

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        // JavaScript 메시지 캡처 설정
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "consoleHandler")
        config.userContentController = userContentController

        config.setURLSchemeHandler(CustomSchemeHandler(), forURLScheme: "custom-http")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator // UIDelegate 설정

        // JavaScript 콘솔 로깅 스크립트 추가
        let consoleLogScript = """
        window.console.log = (function(origLogFunc) {
            return function(...args) {
                origLogFunc.apply(window.console, args);
                window.webkit.messageHandlers.consoleHandler.postMessage(args.join(' '));
            };
        })(window.console.log);

        window.console.error = (function(origLogFunc) {
            return function(...args) {
                origLogFunc.apply(window.console, args);
                window.webkit.messageHandlers.consoleHandler.postMessage(args.join(' '));
            };
        })(window.console.log);
        """
        let script = WKUserScript(source: consoleLogScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContentController.addUserScript(script)

        // 캐시 리스트 다운로드 및 파일 사전 로드
        preloadFiles()

        if let url = URL(string: urlString) {
            let request = URLRequest(url: url)
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 필요 시 UI 업데이트 처리
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func preloadFiles() {
        guard let url = URL(string: cacheListURL) else { return }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("Failed to download cache list: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            do {
                if let jsonArray = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                    for item in jsonArray {
                        if let fileURLString = item["url"] as? String, let fileURL = URL(string: fileURLString) {
                            self.downloadAndCacheFile(from: fileURL)
                        }
                    }
                }
            } catch {
                print("Failed to parse JSON: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    private func downloadAndCacheFile(from url: URL) {
        let filePath = getFilePath(for: url)

        if FileManager.default.fileExists(atPath: filePath.path) {
            // 이미 파일이 존재하면 사전 로드
            if let data = try? Data(contentsOf: filePath) {
                WebViewWrapper.preloadedData[url.absoluteString] = data
            }
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("Failed to download file: \(url): \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            do {
                try data.write(to: filePath)
                WebViewWrapper.preloadedData[url.absoluteString] = data
                print("File cached: \(url)")
            } catch {
                print("Failed to save file: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    private func getFilePath(for url: URL) -> URL {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDirectory.appendingPathComponent(url.lastPathComponent)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        // JavaScript alert() 처리
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: "Alert", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler()
            })
            if let rootVC = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first?.rootViewController {
                rootVC.present(alert, animated: true, completion: nil)
            }
        }

        // JavaScript console.log 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "consoleHandler", let messageBody = message.body as? String else { return }
            print("JavaScript Log: \(messageBody)")
        }
    }

    class CustomSchemeHandler: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else {
                urlSchemeTask.didFailWithError(NSError(domain: "CustomSchemeHandler", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
                return
            }

            let sanitizedURLString = url.absoluteString.replacingOccurrences(of: "custom-", with: "")
            let sanitizedURL = URL(string: sanitizedURLString)!
            if let data = WebViewWrapper.preloadedData[sanitizedURLString] {
                let mimeType = getMimeType(for: sanitizedURLString)
                let response = URLResponse(url: url, mimeType: mimeType,
                                           expectedContentLength: data.count, textEncodingName: "utf-8")
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            }

            let task = URLSession.shared.dataTask(with: sanitizedURL) { data, response, error in
                if let error = error {
                    urlSchemeTask.didFailWithError(error)
                    return
                }

                if let data = data, let response = response {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                } else {
                    urlSchemeTask.didFailWithError(NSError(domain: "CustomSchemeHandler", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to load data"]))
                }
            }
            task.resume()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        private func getMimeType(for url: String) -> String {
            if url.hasSuffix(".js") {
                return "application/javascript"
            } else if url.hasSuffix(".css") {
                return "text/css"
            } else if url.hasSuffix(".html") {
                return "text/html"
            } else if url.hasSuffix(".png") {
                return "image/png"
            } else if url.hasSuffix(".jpg") || url.hasSuffix(".jpeg") {
                return "image/jpeg"
            } else {
                return "application/octet-stream"
            }
        }
    }
}

#Preview {
    ContentView()
}

