import UIKit
import WebKit
import PhotosUI
import UniformTypeIdentifiers
import HopCore

final class LocalAssets: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let allowed = ["index.html","styles.css","android.css","app.js","fx.js","bridge.js","i18n.js","multi.js","multi.css","picker.js","picker.css","icon.png"]
        guard let url = task.request.url, url.host == "local", allowed.contains(url.lastPathComponent), let root = Bundle.main.resourceURL?.appendingPathComponent("hop"), let bytes = try? Data(contentsOf: root.appendingPathComponent(url.lastPathComponent)) else { task.didFailWithError(HopError.invalid("Unknown asset")); return }
        let mime = url.pathExtension == "js" ? "text/javascript" : url.pathExtension == "css" ? "text/css" : url.pathExtension == "png" ? "image/png" : "text/html"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: "utf-8")); task.didReceive(bytes); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
final class HopViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private var web: WKWebView!
    private var engine: HopEngine?
    private var pickID: String?
    private var pageReady = false
    private var documentController: UIDocumentInteractionController?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let config = WKWebViewConfiguration(); config.setURLSchemeHandler(LocalAssets(), forURLScheme: "hop"); config.userContentController.add(self, name: "hop")
        web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.isOpaque = false; web.backgroundColor = .systemBackground; web.scrollView.isScrollEnabled = false
        web.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: view.leadingAnchor),web.trailingAnchor.constraint(equalTo: view.trailingAnchor),web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)])
        do { let engine = try HopEngine(); self.engine = engine; engine.event = { [weak self] event in DispatchQueue.main.async { self?.emit(event) } } }
        catch { showError(error) }
        web.load(URLRequest(url: URL(string: "hop://local/index.html?platform=android&material=none")!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url?.scheme == "hop" && action.request.url?.host == "local" ? .allow : .cancel) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "hop", message.frameInfo.request.url?.host == "local", let body = message.body as? [String: Any], let id = body["id"] as? String, id.range(of: "^[0-9]{1,12}$", options: .regularExpression) != nil, let method = body["method"] as? String, let args = body["args"] as? [Any] else { return }
        guard let engine else { complete(id, error: "Hop could not start"); return }
        switch method {
        case "pick": openPicker(id, source: args.first as? String ?? "files")
        case "hasSharedFiles": complete(id, value: false)
        case "getLanguage": complete(id, value: UserDefaults.standard.string(forKey: "language") ?? "ru")
        case "setLanguage": let value = args.first as? String ?? "ru"; if ["ru","en"].contains(value) { UserDefaults.standard.set(value, forKey: "language") }; complete(id, value: value)
        case "theme": let value = args.first as? String ?? "system"; if ["dark","light","system"].contains(value) { UserDefaults.standard.set(value, forKey: "theme") }; complete(id, value: value)
        case "settings": settings(); complete(id)
        case "downloads","reveal": shareDownloads(); complete(id)
        case "location": complete(id, value: "Файлы/Hop")
        default:
            engine.queue.async { [weak self] in
                guard let self else { return }
                do {
                    switch method {
                    case "init": engine.whenReady { self.complete(id, value: engine.state()) }
                    case "ready": DispatchQueue.main.async { self.pageReady = true }; self.complete(id)
                    case "send": guard args.count == 2, let peer = args[0] as? String, let handles = args[1] as? [String] else { throw HopError.invalid("Bad selection") }; self.complete(id, value: try engine.send(to: peer, handles: handles))
                    case "cancel": if let transfer = args.first as? String { engine.cancel(transfer) }; self.complete(id)
                    case "offer": guard args.count == 3, let transfer = args[0] as? String, let accepted = args[1] as? Bool, let remember = args[2] as? Bool else { throw HopError.invalid("Bad offer") }; engine.decide(transfer, accepted: accepted, remember: remember); self.complete(id)
                    case "rename": engine.rename(args.first as? String ?? "iPhone"); self.complete(id, value: engine.name)
                    case "forget": engine.trusted = [:]; self.complete(id, value: 0)
                    default: throw HopError.invalid("Unsupported action")
                    }
                } catch { self.complete(id, error: error.localizedDescription) }
            }
        }
    }
    private func complete(_ id: String, value: Any? = nil, error: String? = nil) {
        let args: [Any] = [id,value ?? NSNull(),error as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: args), let text = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in self?.web.evaluateJavaScript("window.hopAndroid.complete.apply(null,\(text))", completionHandler: nil) }
    }
    private func emit(_ event: [String: Any]) { guard pageReady, let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }; web.evaluateJavaScript("window.hopAndroid.emit(\(text))", completionHandler: nil) }
    private func openPicker(_ id: String, source: String) {
        guard pickID == nil else { complete(id, error: "File picker is already open"); return }; pickID = id
        if source == "gallery" { var config = PHPickerConfiguration(); config.selectionLimit = 50; let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true); return }
        // File and folder selections use Apple's document browser and scoped URLs.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: source == "folder" ? [.folder] : [.item], asCopy: true)
        picker.allowsMultipleSelection = source != "folder"; picker.delegate = self; present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishPick([]) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { importFiles(urls) }
    private func importFiles(_ urls: [URL]) {
        guard let engine else { finishPick([]); return }
        engine.queue.async { [weak self] in
            do {
                var handles = [String]()
                for source in urls.prefix(100) {
                    let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let base = engine.staging.appendingPathComponent(UUID().uuidString, isDirectory: true); try engine.files.createDirectory(at: base, withIntermediateDirectories: true)
                    let name = source.lastPathComponent; _ = try SafePath.components(name)
                    let target = base.appendingPathComponent(name); try engine.files.copyItem(at: source, to: target)
                    var items = [TransferItem]()
                    func item(_ url: URL) throws { let relative = String(url.path.dropFirst(base.path.count + 1)); _ = try SafePath.components(relative); let v = try url.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey]); guard v.isSymbolicLink != true else { throw HopError.invalid("Symbolic links are unsupported") }; items.append(TransferItem(path: relative, size: v.isDirectory == true ? 0 : Int64(v.fileSize ?? 0), directory: v.isDirectory == true, url: url)) }
                    try item(target)
                    if items[0].directory, let iterator = engine.files.enumerator(at: target, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) { for case let url as URL in iterator { guard items.count < 10000 else { throw HopError.invalid("Too many files") }; try item(url) } }
                    handles.append(engine.registerSelection(items))
                }
                DispatchQueue.main.async { self?.finishPick(handles) }
            } catch { DispatchQueue.main.async { self?.finishPick([], error: error.localizedDescription) } }
        }
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true); guard !results.isEmpty else { finishPick([]); return }
        let group = DispatchGroup(), lock = NSLock(); var urls = [URL]()
        for result in results { group.enter(); result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in defer { group.leave() }; guard let url else { return }; let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent); do { try FileManager.default.copyItem(at: url, to: target); lock.lock(); urls.append(target); lock.unlock() } catch {} } }
        group.notify(queue: .main) { [weak self] in self?.importFiles(urls) }
    }
    private func finishPick(_ handles: [String], error: String? = nil) { guard let id = pickID else { return }; pickID = nil; complete(id, value: handles, error: error) }
    private func shareDownloads() { guard let engine else { return }; let sheet = UIActivityViewController(activityItems: [engine.root], applicationActivities: nil); sheet.popoverPresentationController?.sourceView = view; present(sheet, animated: true) }
    private func settings() { let alert = UIAlertController(title: "Hop 0.1.0", message: "Приём работает, пока Hop открыт. Файлы сохраняются в «Файлы → На моём iPhone → Hop». Используйте доверенную локальную сеть.", preferredStyle: .alert); alert.addAction(UIAlertAction(title: "Готово", style: .default)); present(alert, animated: true) }
    private func showError(_ error: Error) { DispatchQueue.main.async { let alert = UIAlertController(title: "Hop", message: error.localizedDescription, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); self.present(alert, animated: true) } }
}
