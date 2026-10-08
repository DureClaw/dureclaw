// DureClaw — macOS 메뉴 막대 서버 앱
//
// DureClaw.app/Contents/Resources/server 에 들어 있는 Phoenix 릴리스(harness_server)를
// 자식 프로세스로 띄우고, 메뉴 막대에서 상태·연결 주소·노드 추가 명령을 보여준다.
//
//   - 데이터: ~/.dureclaw/server/{data,tmp,logs}  (경로에 공백이 없어야 erl 스크립트가 안전)
//   - 포트:   DURECLAW_PORT 환경변수 > ~/.dureclaw/server/config 의 PORT= > 4000
//
// 빌드: build.sh (swiftc 단일 파일, Xcode 프로젝트 없음)

import AppKit
import Darwin
import Foundation

// MARK: - Paths & config

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let base = home.appendingPathComponent(".dureclaw/server")
    static let data = base.appendingPathComponent("data")
    static let tmp = base.appendingPathComponent("tmp")
    static let logs = base.appendingPathComponent("logs")
    static let log = logs.appendingPathComponent("server.log")
    static let config = base.appendingPathComponent("config")
    static let secret = data.appendingPathComponent("server.secret")
    static let welcomed = base.appendingPathComponent(".welcomed")
    static let launchAgent = home.appendingPathComponent("Library/LaunchAgents/ai.baryon.dureclaw.plist")
    static var serverRoot: URL { Bundle.main.resourceURL!.appendingPathComponent("server") }
    static var serverExe: URL { serverRoot.appendingPathComponent("bin/harness_server") }
}

func readConfig() -> [String: String] {
    guard let text = try? String(contentsOf: Paths.config, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].hasPrefix("#") { out[parts[0].uppercased()] = parts[1] }
    }
    return out
}

func configuredPort() -> Int {
    if let s = ProcessInfo.processInfo.environment["DURECLAW_PORT"], let p = Int(s) { return p }
    if let s = readConfig()["PORT"], let p = Int(s) { return p }
    return 4000
}

func readSecret() -> String? {
    guard let s = try? String(contentsOf: Paths.secret, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// MARK: - Self-hosted mesh (Headscale)
//
// 공식 Tailscale 계정 대신, 앱에 들어 있는 오픈소스 Headscale 을 이 Mac 에서 띄운다.
// 실제 동작은 번들한 scripts/mesh.sh 가 맡는다 (Linux 서버·Docker 와 같은 도구).

enum Mesh {
    static let dir = Paths.home.appendingPathComponent(".dureclaw/mesh")
    static var bundled: URL { Bundle.main.resourceURL!.appendingPathComponent("mesh") }
    static var script: URL { bundled.appendingPathComponent("mesh.sh") }
    static var enabledFlag: URL { Paths.base.appendingPathComponent("mesh.enabled") }
    static var publicDerpFlag: URL { Paths.base.appendingPathComponent("mesh.public-derp") }
    static var configFile: URL { dir.appendingPathComponent("config.yaml") }

    static var available: Bool { FileManager.default.fileExists(atPath: script.path) }
    static var enabled: Bool { FileManager.default.fileExists(atPath: enabledFlag.path) }
    static var publicDerp: Bool { FileManager.default.fileExists(atPath: publicDerpFlag.path) }

    /// config.yaml 의 server_url (제어 서버 주소)
    static var serverURL: String? {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("server_url: ") {
            return String(line.dropFirst("server_url: ".count))
        }
        return nil
    }

    /// mesh.sh 실행 → (종료 코드, stdout, stderr)
    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, out: String, err: String) {
        let fm = FileManager.default
        // 번들의 headscale 을 MESH_DIR/bin 으로 (mesh.sh 가 그 경로를 쓴다)
        let bin = dir.appendingPathComponent("bin/headscale")
        if !fm.fileExists(atPath: bin.path) {
            try? fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: bundled.appendingPathComponent("headscale"), to: bin)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["MESH_DIR"] = dir.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Applications/Tailscale.app/Contents/MacOS"
        p.environment = env
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (127, "", "\(error)") }
        let outData = o.fileHandleForReading.readDataToEndOfFile()
        let errData = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let trim = { (d: Data) in (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, trim(outData), trim(errData))
    }

    /// 이 Mac 의 Tailscale 이 지금 자체 망 제어 서버에 붙어 있으면 그 사설망 IP
    static func thisMacMeshIP() -> String? {
        guard let url = serverURL else { return nil }
        let ts = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        guard let prefs = runCapture(ts, ["debug", "prefs"]),
              let data = prefs.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ControlURL"] as? String) == url else { return nil }
        return tailscaleIP()
    }
}

// MARK: - Network helpers

/// 127.0.0.1:port 에 TCP 연결이 되면 누군가 이미 듣고 있는 것.
func portInUse(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return rc == 0
}

func runCapture(_ path: String, _ args: [String]) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    return out?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func tailscaleIP() -> String? {
    let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]
    for c in candidates {
        if let out = runCapture(c, ["ip", "-4"]),
           let first = out.split(separator: "\n").first, first.hasPrefix("100.") {
            return String(first)
        }
    }
    return nil
}

func lanIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var best: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ifa.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") { continue }
            if name == "en0" { return ip }
            if best == nil { best = ip }
        }
    }
    return best
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusLine: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var server: Process?
    private var logHandle: FileHandle?
    private var pollTimer: Timer?
    private var quitting = false
    private var restarting = false
    private var externalServer = false
    private var workKeyEnsured = false
    private var meshStatusItem: NSMenuItem!
    private var meshToggleItem: NSMenuItem!
    private var meshDerpItem: NSMenuItem!
    private let port = configuredPort()

    func applicationDidFinishLaunching(_ notification: Notification) {
        for dir in [Paths.data, Paths.tmp, Paths.logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        buildMenu()
        startServer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        showWelcomeOnce()
        if Mesh.available && Mesh.enabled { DispatchQueue.global().async { self.meshStart(silent: true) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        stopServer()
        // 앱을 끄면 자체 망 제어 서버도 함께 멈춘다 (다음 실행 때 '켜짐'이었으면 다시 켠다)
        if Mesh.available && Mesh.enabled { Mesh.run(["stop"]) }
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "DureClaw") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "DC"
            }
            button.toolTip = "DureClaw 서버"
        }

        statusLine = NSMenuItem(title: "시작 중...", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("대시보드 열기", #selector(openDashboard), "d"))
        menu.addItem(.separator())
        menu.addItem(item("노드 연결 주소 복사", #selector(copyAddress), "c"))
        menu.addItem(item("Windows 설치 프로그램 다운로드", #selector(openWindowsDownload)))
        menu.addItem(item("Linux/Mac 노드 추가 명령 복사", #selector(copyAgentCommand)))
        menu.addItem(item("Claude Code 연결 명령 복사", #selector(copyClaudeCommand)))
        if Mesh.available {
            menu.addItem(.separator())
            let meshMenu = NSMenu()
            meshStatusItem = NSMenuItem(title: "꺼짐", action: nil, keyEquivalent: "")
            meshStatusItem.isEnabled = false
            meshMenu.addItem(meshStatusItem)
            meshMenu.addItem(.separator())
            meshToggleItem = item("자체 망 켜기", #selector(toggleMesh))
            meshMenu.addItem(meshToggleItem)
            meshMenu.addItem(item("노드 연결 코드 복사", #selector(copyJoinCode)))
            meshMenu.addItem(.separator())
            meshMenu.addItem(item("이 Mac을 자체 망에 합류 (망 전환)…", #selector(joinThisMac)))
            meshMenu.addItem(item("원래 망으로 돌아가기", #selector(leaveMesh)))
            meshMenu.addItem(.separator())
            meshDerpItem = item("외부 중계 허용 (NAT 너머 연결)", #selector(toggleDerp))
            meshMenu.addItem(meshDerpItem)
            let parent = NSMenuItem(title: "자체 사설망 (Headscale)", action: nil, keyEquivalent: "")
            parent.submenu = meshMenu
            menu.addItem(parent)
            menu.delegate = self
        }
        menu.addItem(.separator())
        menu.addItem(item("로그 보기", #selector(openLog), "l"))
        menu.addItem(item("서버 재시작", #selector(restartServer), "r"))
        loginItem = item("로그인 시 자동 실행", #selector(toggleLogin))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item("DureClaw 종료", #selector(quit), "q"))
        statusItem.menu = menu
        refreshLoginItem()
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLine.title = text
            self.statusItem.button?.toolTip = "DureClaw — \(text)"
        }
    }

    // MARK: Server lifecycle

    private func startServer() {
        if portInUse(port) {
            externalServer = true
            setStatus("포트 \(port) 사용 중 — 이미 서버가 실행 중")
            return
        }
        externalServer = false
        workKeyEnsured = false
        guard FileManager.default.isExecutableFile(atPath: Paths.serverExe.path) else {
            setStatus("서버 파일 없음 — 앱을 다시 설치해 주세요")
            return
        }

        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: Paths.log)
        logHandle?.seekToEndOfFile()
        logHandle?.write("\n==== DureClaw server start \(Date()) port=\(port) ====\n".data(using: .utf8)!)

        let p = Process()
        p.executableURL = Paths.serverExe
        p.arguments = ["start"]
        p.currentDirectoryURL = Paths.base
        p.environment = serverEnvironment()
        p.standardOutput = logHandle
        p.standardError = logHandle
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.serverExited(proc.terminationStatus) }
        }
        do {
            try p.run()
            server = p
            setStatus("시작 중... (포트 \(port))")
        } catch {
            setStatus("시작 실패: \(error.localizedDescription)")
        }
    }

    private func serverEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = Paths.home.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["PORT"] = String(port)
        env["HOST"] = "0.0.0.0"
        env["OAH_BIND_IP"] = "0.0.0.0"
        env["OAH_TRUST_LOOPBACK"] = "1"
        env["OAH_DATA_DIR"] = Paths.data.path
        env["RELEASE_TMP"] = Paths.tmp.path
        // 같은 맥에서 터미널로 띄운 harness_server 와 노드 이름이 겹치지 않게
        env["RELEASE_NODE"] = "dureclaw_app"
        env["LANG"] = "en_US.UTF-8"
        // 번들한 OpenSSL provider 사용 (build.sh 가 Homebrew 의존을 끊어 둠)
        let modules = Paths.serverRoot.appendingPathComponent("ossl-modules")
        if FileManager.default.fileExists(atPath: modules.path) { env["OPENSSL_MODULES"] = modules.path }
        for (k, v) in readConfig() where k != "PORT" { env[k] = v }
        return env
    }

    private func serverExited(_ code: Int32) {
        server = nil
        try? logHandle?.close()
        logHandle = nil
        if quitting { return }
        if restarting {
            restarting = false
            startServer()
            return
        }
        setStatus("중지됨 (종료 코드 \(code)) — 서버 재시작으로 다시 시작")
    }

    private func stopServer() {
        guard let p = server, p.isRunning else { return }
        p.terminate() // SIGTERM → BEAM 정상 종료
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning {
            // 폴백: 릴리스 스크립트로 원격 종료, 그래도 안 되면 강제 종료
            let stop = Process()
            stop.executableURL = Paths.serverExe
            stop.arguments = ["stop"]
            stop.environment = serverEnvironment()
            stop.currentDirectoryURL = Paths.base
            try? stop.run()
            stop.waitUntilExit()
            let d2 = Date().addingTimeInterval(5)
            while p.isRunning && Date() < d2 { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    // MARK: Polling

    private func poll() {
        if server == nil && !externalServer { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/presence")!)
        req.timeoutInterval = 3
        if let s = readSecret() { req.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let n = (obj["agents"] as? [Any])?.count ?? 0
                let prefix = self.externalServer ? "외부 서버 실행 중" : "실행 중"
                self.setStatus("● \(prefix) · 노드 \(n)개 · 포트 \(self.port)")
                if !self.externalServer { self.ensureWorkKey() }
            } else if self.server != nil {
                self.setStatus("시작 중... (포트 \(self.port))")
            }
        }.resume()
    }

    /// 새 서버에는 Work Key 가 없어 노드가 "Work Key 대기"에 멈춘다.
    /// 앱이 띄운 서버가 처음 응답하면, 없을 때만 기본 Work Key 를 하나 만든다.
    private func ensureWorkKey() {
        DispatchQueue.main.async {
            guard !self.workKeyEnsured else { return }
            self.workKeyEnsured = true
            let base = "http://127.0.0.1:\(self.port)/api/work-keys"
            var get = URLRequest(url: URL(string: base + "/latest")!)
            get.timeoutInterval = 3
            URLSession.shared.dataTask(with: get) { [weak self] _, resp, _ in
                guard let self = self else { return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return }          // 이미 있음
                if code != 404 {                    // 아직 준비 안 됨 → 다음 폴링에서 재시도
                    DispatchQueue.main.async { self.workKeyEnsured = false }
                    return
                }
                var post = URLRequest(url: URL(string: base)!)
                post.httpMethod = "POST"
                post.timeoutInterval = 3
                post.setValue("application/json", forHTTPHeaderField: "Content-Type")
                post.httpBody = "{}".data(using: .utf8)
                if let s = readSecret() { post.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
                URLSession.shared.dataTask(with: post) { [weak self] data, resp, _ in
                    let ok = (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
                    let wk = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["work_key"] as? String
                    self?.appendLog(ok ? "default work key created: \(wk ?? "?")\n" : "work key create failed\n")
                    if !ok { DispatchQueue.main.async { self?.workKeyEnsured = false } }
                }.resume()
            }.resume()
        }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async { self.logHandle?.write(line.data(using: .utf8)!) }
    }

    // MARK: Actions

    private func nodeAddress() -> String {
        let host = tailscaleIP() ?? lanIP() ?? "localhost"
        return "ws://\(host):\(port)"
    }

    private func copy(_ text: String, _ note: String, display: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let alert = NSAlert()
        alert.messageText = note
        alert.informativeText = display ?? text
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
    }

    @objc private func copyAddress() {
        copy(nodeAddress(), "노드 연결 주소를 복사했습니다")
    }

    @objc private func openWindowsDownload() {
        NSWorkspace.shared.open(URL(string: "https://dureclaw.baryon.ai/windows/")!)
    }

    @objc private func copyAgentCommand() {
        let cmd = "PHOENIX=\(nodeAddress()) bash <(curl -fsSL https://dureclaw.baryon.ai/agent)"
        copy(cmd, "노드 추가 명령을 복사했습니다 — 추가할 Linux/Mac 터미널에 붙여 넣으세요")
    }

    @objc private func copyClaudeCommand() {
        let machine = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-") ?? "mac"
        let head = "PHOENIX_URL=ws://localhost:\(port) AGENT_NAME=orchestrator@\(machine) SKIP_TAILSCALE=1"
        let tail = " bash <(curl -fsSL https://dureclaw.baryon.ai/mcp)"
        let secret = readSecret()
        let cmd = head + (secret.map { " OAH_SECRET=\($0)" } ?? "") + tail
        // 화면에는 시크릿을 가리고, 클립보드에만 전체 명령을 넣는다
        let shown = head + (secret == nil ? "" : " OAH_SECRET=••••••") + tail
        copy(cmd, "Claude Code 연결(MCP 등록) 명령을 복사했습니다 — 터미널에 붙여 넣으세요", display: shown)
    }

    // MARK: Self-hosted mesh actions

    private func alert(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    private func refreshMesh() {
        guard Mesh.available else { return }
        let running = Mesh.run(["status"]).code == 0
        let url = Mesh.serverURL ?? ""
        let macIP = Mesh.thisMacMeshIP()
        DispatchQueue.main.async {
            self.meshToggleItem.title = running ? "자체 망 끄기" : "자체 망 켜기"
            self.meshDerpItem.state = Mesh.publicDerp ? .on : .off
            if running {
                self.meshStatusItem.title = "● 켜짐 · \(url)" + (macIP.map { " · 이 Mac \($0)" } ?? " · 이 Mac 미합류")
            } else {
                self.meshStatusItem.title = "꺼짐"
            }
        }
    }

    /// 제어 서버 시작 (설정이 없으면 이 Mac 의 LAN 주소로 사내망 모드 설정을 만든다)
    private func meshStart(silent: Bool = false) {
        if !FileManager.default.fileExists(atPath: Mesh.configFile.path) {
            guard let ip = lanIP() else { if !silent { alert("자체 망을 켤 수 없습니다", "이 Mac의 LAN 주소를 찾지 못했습니다.") }; return }
            var args = ["init", "--url", "http://\(ip):8080"]
            if Mesh.publicDerp { args.append("--public-derp") }
            let r = Mesh.run(args)
            guard r.code == 0 else { if !silent { alert("자체 망 설정 실패", r.err) }; return }
        }
        let r = Mesh.run(["start"])
        if r.code == 0 {
            FileManager.default.createFile(atPath: Mesh.enabledFlag.path, contents: nil)
        } else if !silent {
            alert("자체 망을 시작하지 못했습니다", r.err)
        }
        refreshMesh()
    }

    @objc private func toggleMesh() {
        DispatchQueue.global().async {
            if Mesh.run(["status"]).code == 0 {
                Mesh.run(["stop"])
                try? FileManager.default.removeItem(at: Mesh.enabledFlag)
                self.refreshMesh()
            } else {
                self.meshStart()
            }
        }
    }

    @objc private func toggleDerp() {
        DispatchQueue.global().async {
            let fm = FileManager.default
            if Mesh.publicDerp { try? fm.removeItem(at: Mesh.publicDerpFlag) }
            else { fm.createFile(atPath: Mesh.publicDerpFlag.path, contents: nil) }
            // 설정을 다시 만들고(노드 DB 는 유지) 켜져 있었다면 재시작
            if let url = Mesh.serverURL {
                var args = ["init", "--url", url, "--force"]
                if Mesh.publicDerp { args.append("--public-derp") }
                Mesh.run(args)
                if Mesh.run(["status"]).code == 0 { Mesh.run(["stop"]); self.meshStart() }
            }
            self.refreshMesh()
        }
    }

    @objc private func copyJoinCode() {
        DispatchQueue.global().async {
            guard Mesh.run(["status"]).code == 0 else {
                self.alert("자체 망이 꺼져 있습니다", "먼저 '자체 망 켜기'를 눌러 주세요."); return
            }
            guard let ip = Mesh.thisMacMeshIP() else {
                self.alert("이 Mac이 아직 자체 망에 없습니다",
                           "노드가 이 Mac의 버스에 사설망으로 붙으려면, 먼저 '이 Mac을 자체 망에 합류'를 눌러 주세요.")
                return
            }
            let r = Mesh.run(["join-code", "--ttl", "24h", "--reusable", "--bus", "ws://\(ip):\(self.port)"])
            guard r.code == 0, !r.out.isEmpty else { self.alert("연결 코드 발급 실패", r.err); return }
            DispatchQueue.main.async {
                self.copy(r.out, "노드 연결 코드를 복사했습니다 (24시간 · 여러 대)",
                          display: "Windows: 설치 마법사의 '노드 연결 코드' 칸에 붙여 넣기\n" +
                                   "Linux·Mac: JOIN=<코드> bash <(curl -fsSL https://dureclaw.baryon.ai/agent)\n\n" +
                                   String(r.out.prefix(24)) + "…")
            }
        }
    }

    @objc private func joinThisMac() {
        let a = NSAlert()
        a.messageText = "이 Mac을 자체 망으로 전환할까요?"
        a.informativeText = """
        지금 연결된 Tailscale 망(예: 공식 계정)은 프로필로 그대로 남고, 새 프로필로 자체 망에 합류합니다.
        전환하는 동안 기존 망의 다른 기기와는 연결되지 않습니다.
        '원래 망으로 돌아가기'로 언제든 되돌릴 수 있습니다.
        """
        a.addButton(withTitle: "전환")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async {
            if Mesh.run(["status"]).code != 0 { self.meshStart() }
            let code = Mesh.run(["join-code", "--ttl", "10m"])
            guard code.code == 0 else { self.alert("가입 키 발급 실패", code.err); return }
            let r = Mesh.run(["join", code.out, "--force", "--hostname", "dureclaw-server"])
            if r.code == 0 {
                self.alert("자체 망에 합류했습니다", r.err.split(separator: "\n").last.map(String.init) ?? "")
            } else {
                self.alert("합류하지 못했습니다", r.err)
            }
            self.refreshMesh()
        }
    }

    @objc private func leaveMesh() {
        DispatchQueue.global().async {
            let r = Mesh.run(["leave"])
            self.alert(r.code == 0 ? "원래 망으로 돌아갔습니다" : "되돌리지 못했습니다", r.err)
            self.refreshMesh()
        }
    }

    @objc private func openLog() {
        if FileManager.default.fileExists(atPath: Paths.log.path) {
            NSWorkspace.shared.open(Paths.log)
        } else {
            NSWorkspace.shared.open(Paths.logs)
        }
    }

    @objc private func restartServer() {
        if let p = server, p.isRunning {
            restarting = true
            DispatchQueue.global().async { self.stopServer() }
            setStatus("재시작 중...")
        } else {
            startServer()
        }
    }

    @objc private func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.launchAgent.path) {
            try? fm.removeItem(at: Paths.launchAgent)
        } else {
            let plist: [String: Any] = [
                "Label": "ai.baryon.dureclaw",
                "ProgramArguments": ["/usr/bin/open", "-gj", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(at: Paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: Paths.launchAgent)
            }
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        loginItem.state = FileManager.default.fileExists(atPath: Paths.launchAgent.path) ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showWelcomeOnce() {
        guard !FileManager.default.fileExists(atPath: Paths.welcomed.path) else { return }
        FileManager.default.createFile(atPath: Paths.welcomed.path, contents: nil)
        let alert = NSAlert()
        alert.messageText = "DureClaw 서버가 실행되었습니다"
        alert.informativeText = """
        화면 위쪽 메뉴 막대의 DureClaw 아이콘에서 상태를 확인하고,
        다른 PC를 추가하는 명령·주소를 복사할 수 있습니다.

        Windows PC는 "Windows 설치 프로그램 다운로드"로 받은 프로그램에
        "노드 연결 주소"를 넣으면 연결됩니다.
        """
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "로그인 시 자동 실행 켜기")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           !FileManager.default.fileExists(atPath: Paths.launchAgent.path) {
            toggleLogin()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        DispatchQueue.global().async { self.refreshMesh() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
