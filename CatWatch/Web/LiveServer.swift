import Darwin
import Foundation
import Network

/// A tiny HTTP server so CatWatch can be watched from a browser on the same Wi-Fi.
/// Every request needs the PIN shown in Settings (`?pin=1234`).
final class LiveServer: @unchecked Sendable {
    static let port: UInt16 = 8080

    private let queue = DispatchQueue(label: "catwatch.web")
    private let lock = NSLock()
    private var listener: NWListener?
    private var frame: Data?
    private var status = Data("{}".utf8)
    private var lastViewer = Date.distantPast
    private var _pin = ""
    private var eventsDirectory: URL?
    private var _onAction: (@Sendable (String, [String: String]) -> Void)?

    /// Called (on the server queue) for `/action?do=…` requests from the page's buttons.
    var onAction: (@Sendable (String, [String: String]) -> Void)? {
        get { lock.withLock { _onAction } }
        set { lock.withLock { _onAction = newValue } }
    }
    static let actions: Set<String> = ["dismiss", "clear", "label", "snooze", "pause", "resume"]

    var pin: String {
        get { lock.withLock { _pin } }
        set { lock.withLock { _pin = newValue } }
    }

    var isRunning: Bool { lock.withLock { listener != nil } }

    /// True while a browser has asked for a frame in the last few seconds.
    var hasViewer: Bool { lock.withLock { Date().timeIntervalSince(lastViewer) < 5 } }

    func update(frame data: Data) { lock.withLock { frame = data } }
    func update(status data: Data) { lock.withLock { status = data } }
    func setEventsDirectory(_ url: URL) { lock.withLock { eventsDirectory = url } }

    private var wanted = false
    private var _lastError: String?
    /// Why the server isn't listening (nil while it is), for Settings.
    var lastError: String? { lock.withLock { _lastError } }

    func start() throws {
        try lock.withLock {
            wanted = true
            guard listener == nil else { return }
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l else { return }
                switch state {
                case .ready:
                    self.lock.withLock { self._lastError = nil }
                case .failed(let error), .waiting(let error):
                    // e.g. Local Network permission not granted yet, or the port is busy: try again shortly.
                    self.lock.withLock {
                        self._lastError = error.localizedDescription
                        if self.listener === l { self.listener = nil }
                    }
                    l.cancel()
                    self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.lock.withLock({ self.wanted }) else { return }
                        try? self.start()
                    }
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        }
    }

    func stop() {
        lock.withLock {
            wanted = false
            listener?.cancel()
            listener = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let response = parts.count >= 2 && parts[0] == "GET"
                ? self.respond(to: String(parts[1]))
                : Self.http(405, "text/plain", Data("Method not allowed".utf8))
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Builds the full HTTP response for a request target such as `/frame.jpg?pin=1234`.
    func respond(to target: String) -> Data {
        let components = URLComponents(string: target)
        let path = components?.path ?? "/"
        let given = components?.queryItems?.first { $0.name == "pin" }?.value ?? ""
        let pin = self.pin
        guard !pin.isEmpty, given == pin else {
            return Self.http(path == "/" ? 200 : 403, "text/html; charset=utf-8", Data(Self.pinPage(wrong: !given.isEmpty).utf8))
        }
        switch path {
        case "/":
            return Self.http(200, "text/html; charset=utf-8", Data(Self.page.utf8))
        case "/frame.jpg":
            let data = lock.withLock { () -> Data? in
                lastViewer = Date()
                return frame
            }
            guard let data else { return Self.http(503, "text/plain", Data("No frame yet".utf8)) }
            return Self.http(200, "image/jpeg", data)
        case "/status.json":
            return Self.http(200, "application/json", lock.withLock { status })
        case "/action":
            var params: [String: String] = [:]
            for item in components?.queryItems ?? [] where item.name != "pin" { params[item.name] = item.value ?? "" }
            guard let action = params["do"], Self.actions.contains(action) else {
                return Self.http(404, "text/plain", Data("Unknown action".utf8))
            }
            onAction?(action, params)
            return Self.http(200, "application/json", Data("{\"ok\":true}".utf8))
        default:
            if path.hasPrefix("/event/"), path.hasSuffix(".jpg"),
               let id = UUID(uuidString: String(path.dropFirst("/event/".count).dropLast(".jpg".count))),
               let dir = lock.withLock({ eventsDirectory }),
               let data = try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).jpg")) {
                return Self.http(200, "image/jpeg", data)
            }
            return Self.http(404, "text/plain", Data("Not found".utf8))
        }
    }

    static func http(_ code: Int, _ type: String, _ body: Data) -> Data {
        let reason = [200: "OK", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// The phone's Wi-Fi IPv4 address, for showing the web view's link in Settings.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private static let style = """
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root { color-scheme: dark; }
    body { margin: 0; background: #111; color: #eee; font: 15px -apple-system, system-ui, sans-serif; }
    main { max-width: 560px; margin: 0 auto; padding: 16px; }
    h1 { font-size: 20px; margin: 0 0 12px; }
    #live { width: 100%; border-radius: 10px; background: #222; display: block; min-height: 200px; }
    .row { display: flex; flex-wrap: wrap; gap: 6px 14px; margin: 10px 0; color: #bbb; }
    .ok { color: #6d6; } .bad { color: #f77; }
    .events { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 8px; }
    .events a { color: #bbb; text-decoration: none; font-size: 13px; }
    .events img { width: 100%; border-radius: 6px; display: block; }
    input, button { font: inherit; padding: 8px 12px; border-radius: 8px; border: 1px solid #444; background: #222; color: #eee; }
    button { cursor: pointer; } button.on { background: #2a4; border-color: #2a4; } button.no { background: #a33; border-color: #a33; }
    #live { cursor: zoom-in; }
    #live.full { position: fixed; inset: 0; width: 100vw; height: 100vh; object-fit: contain; border-radius: 0; background: #000; z-index: 9; cursor: zoom-out; }
    .controls { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0 18px; }
    .head { display: flex; justify-content: space-between; align-items: center; }
    .card { font-size: 13px; color: #bbb; }
    .card .btns { display: flex; gap: 4px; margin-top: 4px; }
    .card .btns button { flex: 1; padding: 6px 4px; font-size: 12px; }
    .empty { color: #777; }
    </style>
    """

    static func pinPage(wrong: Bool) -> String {
        """
        <!doctype html><html><head><title>CatWatch</title>\(style)</head><body><main>
        <h1>🐈 CatWatch</h1>
        <p>Enter the PIN shown in CatWatch › Settings › Web view.</p>
        \(wrong ? "<p class=\"bad\">Wrong PIN.</p>" : "")
        <form method="get" action="/"><input name="pin" inputmode="numeric" autofocus> <button>Open</button></form>
        </main></body></html>
        """
    }

    static let page = """
    <!doctype html><html><head><title>CatWatch</title>\(style)</head><body><main>
    <h1>🐈 CatWatch</h1>
    <img id="live" alt="Live view" title="Tap for full screen">
    <div class="row" id="status">Connecting…</div>
    <div class="controls" id="controls"></div>
    <div class="head"><h1>Alerts (last 24 h)</h1><button id="clear">Clear all</button></div>
    <div class="events" id="events"></div>
    </main>
    <script>
    const pin = new URLSearchParams(location.search).get("pin");
    const q = "pin=" + encodeURIComponent(pin);
    const live = document.getElementById("live");
    let busy = false;
    function nextFrame() {
      if (busy || document.hidden) return;
      busy = true;
      const img = new Image();
      img.onload = () => { live.src = img.src; busy = false; };
      img.onerror = () => { busy = false; };
      img.src = "/frame.jpg?" + q + "&t=" + Date.now();
    }
    setInterval(nextFrame, 350);
    live.onclick = () => live.classList.toggle("full");
    async function act(params) {
      try { await fetch("/action?" + q + "&" + new URLSearchParams(params)); } catch (e) {}
      refresh();
    }
    document.getElementById("clear").onclick = () => { if (confirm("Delete all alerts from the phone?")) act({do: "clear"}); };
    document.addEventListener("click", e => {
      const b = e.target.closest("button[data-do]");
      if (b) act(Object.assign({}, b.dataset));
    });
    function ago(s) { return s < 60 ? Math.round(s) + " s ago" : s < 3600 ? Math.round(s / 60) + " min ago" : Math.round(s / 3600) + " h ago"; }
    let shownEvents = "";
    async function refresh() {
      try {
        const s = await (await fetch("/status.json?" + q)).json();
        const parts = [
          s.running ? '<span class="ok">● Watching</span>' : '<span class="bad">● Paused</span>',
          s.dark ? '<span class="bad">Too dark to see</span>' : (s.cats ? "Cat " + s.cats + "%" : "No cat"),
          "Battery " + s.battery + (s.charging ? " ⚡" : ""),
          s.hot ? '<span class="bad">Hot</span>' : "",
          s.lastAlert != null ? "Last alert " + ago(s.lastAlert) : "",
          s.snooze > 0 ? '<span class="bad">Alerts snoozed ' + Math.ceil(s.snooze / 60) + ' min</span>' : "",
        ];
        document.getElementById("status").innerHTML = parts.filter(Boolean).join(" · ");
        document.getElementById("controls").innerHTML =
          (s.running ? '<button data-do="pause">Pause watching</button>' : '<button class="on" data-do="resume">Resume watching</button>') +
          (s.snooze > 0 ? '<button data-do="snooze" data-min="0">Cancel snooze</button>'
                        : '<button data-do="snooze" data-min="30">Snooze 30 min</button><button data-do="snooze" data-min="60">Snooze 1 h</button>');
        const key = s.events.map(e => e.id + (e.label || "")).join();
        if (key !== shownEvents) {
          shownEvents = key;
          document.getElementById("events").innerHTML = s.events.length ? s.events.map(e =>
            `<div class="card"><a href="/event/${e.id}.jpg?${q}" target="_blank"><img loading="lazy" src="/event/${e.id}.jpg?${q}"></a>` +
            `${new Date(e.date).toLocaleString()} · ${e.confidence}%${e.sent ? "" : " · " + (e.error || "not sent")}` +
            `<div class="btns"><button data-do="label" data-id="${e.id}" data-as="cat" class="${e.label === "cat" ? "on" : ""}">My cat</button>` +
            `<button data-do="label" data-id="${e.id}" data-as="notcat" class="${e.label === "notcat" ? "no" : ""}">Not my cat</button>` +
            `<button data-do="dismiss" data-id="${e.id}">✕</button></div></div>`).join("")
            : '<p class="empty">No alerts in the last 24 hours.</p>';
        }
      } catch (e) {
        document.getElementById("status").innerHTML = '<span class="bad">● Can\\'t reach the phone</span>';
      }
    }
    refresh(); setInterval(refresh, 2000);
    </script></body></html>
    """
}
