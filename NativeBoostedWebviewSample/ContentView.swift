import SwiftUI
@preconcurrency import WebKit

struct ContentView: View {
    var body: some View {
        VStack {
            WebViewWrapper(
                urlString: "http://8090.yjkwon.iscream.0.winm2m.com/mobile/help/faq",
                cacheListURL: "http://8090.yjkwon.iscream.0.winm2m.com/files/cachelist.json")
            .edgesIgnoringSafeArea(.all)
        }
    }
}

struct WebViewWrapper: UIViewRepresentable {
    let urlString: String
    let cacheListURL: String
    let customURLPrefix = "custom-"

    static var preloadedData: [String: Data] = [:]

    init(urlString: String, cacheListURL: String) {
        self.urlString = customURLPrefix + urlString
        self.cacheListURL = cacheListURL
        preloadFiles()
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: createWebViewConfiguration())
        webView.load(URLRequest(url: URL(string: urlString)!))
        return webView
    }

    private func preloadFiles() {
        guard let url = URL(string: cacheListURL) else { return }

        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                return print("Failed to download cache list: \(error?.localizedDescription ?? "Unknown error")")
            }

            do {
                if let jsonArray = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                    jsonArray.compactMap { $0["url"] as? String }.compactMap(URL.init).forEach { self.downloadAndCacheFile(from: $0) }
                }
            } catch {
                print("Failed to parse JSON: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func downloadAndCacheFile(from url: URL) {
        let filePath = getFilePath(for: url)

        if FileManager.default.fileExists(atPath: filePath.path),
           let data = try? Data(contentsOf: filePath) {
            return WebViewWrapper.preloadedData[url.absoluteString] = data
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                return print("Failed to download file: \(url): \(error?.localizedDescription ?? "Unknown error")")
            }

            do {
                try data.write(to: filePath)
                WebViewWrapper.preloadedData[url.absoluteString] = data
                print("File cached: \(url)")
            } catch {
                print("Failed to save file: \(error.localizedDescription)")
            }
        }.resume()
    }

    private func getFilePath(for url: URL) -> URL {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent(url.lastPathComponent)
    }
    
    private func createWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let handler = CustomSchemeHandler(customSchemePrefix: customURLPrefix)
        ["http", "https"].forEach { config.setURLSchemeHandler(handler, forURLScheme: customURLPrefix + $0) }
        return config
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class CustomSchemeHandler: NSObject, WKURLSchemeHandler {
        let customSchemePrefix: String

        init(customSchemePrefix: String) { self.customSchemePrefix = customSchemePrefix }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let url = urlSchemeTask.request.url!
            let sanitizedURLString = url.absoluteString.replacingOccurrences(of: customSchemePrefix, with: "")

            if let data = WebViewWrapper.preloadedData[sanitizedURLString] {
                return sendResponse(
                    URLResponse(url: url, mimeType: getMimeType(for: sanitizedURLString), expectedContentLength: data.count, textEncodingName: "utf-8"),
                    data, for: urlSchemeTask)
            }
            
            URLSession.shared.dataTask(with: URL(string: sanitizedURLString)!) {[self] data, response, error in
                sendResponse(response!, data!, for: urlSchemeTask)
            }.resume()
        }
        
        func sendResponse(_ response: URLResponse, _ data: Data, for urlSchemeTask: WKURLSchemeTask) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        private func getMimeType(for url: String) -> String {
            return [
                ".js": "application/javascript",
                ".css": "text/css",
                ".html": "text/html"
            ].first { url.hasSuffix($0.key) }?.value ?? "application/octet-stream"
        }
    }
}


