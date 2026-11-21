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

    func start() throws {
        try lock.withLock {
            guard listener == nil else { return }
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            l.start(queue: queue)
            listener = l
        }
    }

    func stop() {
        lock.withLock {
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
    <img id="live" alt="Live view">
    <div class="row" id="status">Connecting…</div>
    <h1>Recent alerts</h1>
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
        ];
        document.getElementById("status").innerHTML = parts.filter(Boolean).join(" · ");
        const key = s.events.map(e => e.id).join();
        if (key !== shownEvents) {
          shownEvents = key;
          document.getElementById("events").innerHTML = s.events.map(e =>
            `<a href="/event/${e.id}.jpg?${q}" target="_blank"><img loading="lazy" src="/event/${e.id}.jpg?${q}">` +
            `${new Date(e.date).toLocaleString()} · ${e.confidence}%${e.sent ? "" : " · not sent"}</a>`).join("");
        }
      } catch (e) {
        document.getElementById("status").innerHTML = '<span class="bad">● Can\\'t reach the phone</span>';
      }
    }
    refresh(); setInterval(refresh, 2000);
    </script></body></html>
    """
}
