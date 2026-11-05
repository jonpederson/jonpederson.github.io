import Darwin
import Foundation

// Watches the AI agents running on this Mac (port of `agents_data.py`).
//
// Claude Code writes one JSON-lines transcript per session and a small status file per
// running process. This tails those files (reading only new bytes after the first pass)
// and samples `ps` for CPU, memory and child processes, then publishes an immutable
// snapshot for the renderer every second.
//
// Only metadata leaves this file: titles, project folders, tool names, file basenames,
// Bash descriptions and token counts. Prompts, code and command text are never kept.

private let otherRuntimes: Set<String> = ["ollama", "llama-server", "llama-cli", "vllm", "lmstudio", "lms", "codex",
                                          "gemini", "aider", "goose", "cursor-agent", "opencode"]
private let fileTools: Set<String> = ["Read", "Edit", "Write", "NotebookEdit", "MultiEdit"]

/// ~/.claude, or $SCREENIE_CLAUDE_DIR (used by CI to render a demo).
let claudeDir: URL = {
    if let dir = ProcessInfo.processInfo.environment["SCREENIE_CLAUDE_DIR"], !dir.isEmpty {
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
}()

func projectOf(_ cwd: String) -> String {
    if cwd.isEmpty { return "?" }
    let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
    if trimmed.contains("scratch") && trimmed.contains("Claude") { return "scratch" }
    let base = (trimmed as NSString).lastPathComponent
    return base.isEmpty ? cwd : base
}

func prettyModel(_ m: String?) -> String {
    guard let m, !m.isEmpty else { return "?" }
    let parts = m.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
    if parts.count >= 3, Int(parts[1]) != nil {
        return "\(parts[0].capitalized) \(parts[1]).\(parts[2])"
    }
    return m
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

private func parseTS(_ v: Any?) -> Double? {
    guard let s = v as? String else { return nil }
    return (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
}

private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

// MARK: - Snapshot (what the renderer reads)

struct AgentGit {
    let branch: String
    let add, del, changed, ahead: Int
}

struct AgentEvent {
    let seq: Int
    let t: Double
    let sid: String
    let kind: String   // prompt | tool | subtool
    let name: String
    let target: String
}

struct AgentInfo {
    let sid: String
    let pid: Int
    let title: String
    let project: String
    let cwd: String
    let model: String
    let effort: String
    let busy: Bool
    let since: Double
    let started: Double
    let prompts, toolCalls, errors: Int
    let tokens: [String: Int]
    let ctx: Int
    let outRate: Double
    let last: (name: String, target: String, t: Double)?
    let spark: [Int]
    let cpu: Double
    let rss: Double
    let kids: [(String, Int)]
    let subagents: Int
    let files: Int
    let git: AgentGit?
    let tools: [(String, Int)]
}

struct AgentSnapshot {
    let t: Double
    let agents: [AgentInfo]
    let events: [AgentEvent]
    let today: [String: Int]
    let toolsToday: [(String, Int)]
    let filesToday: Int
    let hours: [[(String, Int)]]  // 24 hours, oldest first: (project, actions)
    let projects: [String]
    let sessionsToday: Int
    let others: [String]
}

// MARK: - Transcripts

/// Incrementally parsed session transcript (plus any subagent transcripts).
final class Transcript {
    let sid: String
    let path: URL
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: Data] = [:]
    private var msgIDs: Set<String> = []
    private var toolIDs: Set<String> = []
    var tokens: [String: Int] = [:]
    var tools: [String: Int] = [:]
    var prompts = 0
    var errors = 0
    var subagents: Set<String> = []
    var files: Set<String> = []
    var model: String?
    var ctx = 0
    var title: String?
    var cwd: String?
    var firstT: Double?
    var lastT: Double?
    var lastTool: (name: String, target: String, t: Double)?
    var minutes: [Int: Int] = [:]  // epoch minute -> actions
    var outTimes: [(Double, Int)] = []

    init(sid: String, path: URL) {
        self.sid = sid
        self.path = path
    }

    private func paths() -> [URL] {
        let subDir = path.deletingLastPathComponent().appendingPathComponent(sid).appendingPathComponent("subagents")
        let subs = (try? FileManager.default.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil)) ?? []
        return [path] + subs.filter { $0.pathExtension == "jsonl" }
    }

    func update(_ hub: AgentHub) {
        for p in paths() {
            let key = p.path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: key))?[.size] as? NSNumber else { continue }
            let total = size.uint64Value
            var off = offsets[key] ?? 0
            if total < off { off = 0 }
            if total == off { continue }
            guard let fh = try? FileHandle(forReadingFrom: p) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: off)
            var data = partial.removeValue(forKey: key) ?? Data()
            data.append((try? fh.readToEnd()) ?? Data())
            offsets[key] = total
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if let lastLine = lines.last, !lastLine.isEmpty {
                partial[key] = Data(lastLine)
                lines.removeLast()
            }
            let sub = p != path
            for line in lines where !line.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                entry(obj, hub, sub)
            }
        }
    }

    private func entry(_ e: [String: Any], _ hub: AgentHub, _ sub: Bool) {
        let kind = e["type"] as? String
        if kind == "custom-title" {
            if let t = e["customTitle"] as? String, !t.isEmpty { title = t }
            return
        }
        guard let t = parseTS(e["timestamp"]) else { return }
        firstT = min(firstT ?? t, t)
        lastT = max(lastT ?? t, t)
        if let c = e["cwd"] as? String, !c.isEmpty { cwd = c }
        if sub || (e["isSidechain"] as? Bool) == true {
            subagents.insert((e["agentId"] as? String) ?? (e["sessionId"] as? String) ?? "sub")
        }
        guard let msg = e["message"] as? [String: Any] else { return }
        let content = msg["content"]
        if kind == "assistant" {
            let mid = msg["id"] as? String ?? ""
            if let u = msg["usage"] as? [String: Any], !msgIDs.contains(mid) {
                msgIDs.insert(mid)
                let out = int(u["output_tokens"]), inp = int(u["input_tokens"])
                let cw = int(u["cache_creation_input_tokens"]), cr = int(u["cache_read_input_tokens"])
                let think = int((u["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
                for (k, v) in [("input", inp), ("cache_write", cw), ("cache_read", cr), ("output", out), ("thinking", think)] {
                    tokens[k, default: 0] += v
                }
                if !sub {
                    ctx = inp + cw + cr + out
                    model = (msg["model"] as? String) ?? model
                }
                outTimes.append((t, out))
                if outTimes.count > 400 { outTimes.removeFirst(outTimes.count - 400) }
                hub.countTokens(t, inp, cw, cr, out, think)
            }
            if let blocks = content as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    let id = b["id"] as? String ?? UUID().uuidString
                    if toolIDs.contains(id) { continue }
                    toolIDs.insert(id)
                    tool(b, t, hub, sub)
                }
            }
        } else if kind == "user" {
            let external = (e["userType"] as? String) == "external"
            if content is String && !sub && external {
                prompts += 1
                hub.event(self, t, "prompt", "New task", "")
                hub.countAction(t, self, tool: nil, prompt: true)
            } else if let blocks = content as? [[String: Any]] {
                for b in blocks {
                    let type = b["type"] as? String
                    if type == "tool_result" && (b["is_error"] as? Bool) == true {
                        errors += 1
                    } else if type == "text" && !sub && external && (e["isMeta"] as? Bool) != true {
                        prompts += 1
                        hub.event(self, t, "prompt", "New task", "")
                        hub.countAction(t, self, tool: nil, prompt: true)
                        break
                    }
                }
            }
        }
    }

    private func tool(_ b: [String: Any], _ t: Double, _ hub: AgentHub, _ sub: Bool) {
        var name = b["name"] as? String ?? "?"
        if name.hasPrefix("mcp__") { name = name.components(separatedBy: "__").last ?? name }
        let inp = b["input"] as? [String: Any] ?? [:]
        var target = ""
        if fileTools.contains(name), let fp = inp["file_path"] as? String, !fp.isEmpty {
            target = (fp as NSString).lastPathComponent
            if name != "Read" {
                files.insert(fp)
                hub.filesTodayAdd(t, fp)
            }
        } else if name == "Bash" || name == "Agent" || name == "Task" {
            target = inp["description"] as? String ?? ""
        } else if name == "WebSearch" || name == "WebFetch" {
            target = "web"
        }
        tools[name, default: 0] += 1
        minutes[Int(t / 60), default: 0] += 1
        lastTool = (name, target, t)
        hub.event(self, t, sub ? "subtool" : "tool", name, target)
        hub.countAction(t, self, tool: name, prompt: false)
    }
}

// MARK: - Hub

private struct Proc {
    let ppid: Int
    let cpu: Double   // seconds of CPU time
    let rss: Double   // bytes
    let comm: String
    let args: [String]
}

private struct HourKey: Hashable {
    let hour: Int
    let project: String
}

/// Runs on its own queue while an Agents screen is showing; the renderer reads
/// `snapshot` from the main thread.
final class AgentHub {
    static let shared = AgentHub()

    private let queue = DispatchQueue(label: "local.screenie.agents", qos: .utility)
    private let lock = NSLock()
    private var published: AgentSnapshot?
    private var users = 0  // main thread
    private var timer: DispatchSourceTimer?

    // Worker state (queue only)
    private var transcripts: [String: Transcript] = [:]
    private var events: [AgentEvent] = []
    private var seq = 0
    private var midnight = AgentHub.midnight()
    private var today: [String: Int] = [:]
    private var toolsToday: [String: Int] = [:]
    private var filesToday: Set<String> = []
    private var hours: [HourKey: Int] = [:]
    private var cpuPrev: [Int: (Double, Double)] = [:]
    private var git: [String: AgentGit?] = [:]
    private var gitT: [String: Double] = [:]

    var snapshot: AgentSnapshot? { lock.withLock { published } }

    func retain() {
        users += 1
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 {
            timer?.cancel()
            timer = nil
        }
    }

    private static func midnight() -> Double {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    // MARK: Counters fed by transcripts

    func countTokens(_ t: Double, _ inp: Int, _ cw: Int, _ cr: Int, _ out: Int, _ think: Int) {
        guard t >= midnight else { return }
        for (k, v) in [("input", inp), ("cache_write", cw), ("cache_read", cr), ("output", out), ("thinking", think)] {
            today[k, default: 0] += v
        }
    }

    func countAction(_ t: Double, _ tr: Transcript, tool: String?, prompt: Bool) {
        if t >= Date().timeIntervalSince1970 - 86400 {
            hours[HourKey(hour: Int(t / 3600), project: projectOf(tr.cwd ?? "")), default: 0] += 1
        }
        guard t >= midnight else { return }
        if let tool {
            toolsToday[tool, default: 0] += 1
            today["tool_calls", default: 0] += 1
        }
        if prompt { today["prompts", default: 0] += 1 }
    }

    func filesTodayAdd(_ t: Double, _ path: String) {
        if t >= midnight { filesToday.insert(path) }
    }

    func event(_ tr: Transcript, _ t: Double, _ kind: String, _ name: String, _ target: String) {
        guard t >= Date().timeIntervalSince1970 - 3600 else { return }
        seq += 1
        events.append(AgentEvent(seq: seq, t: t, sid: tr.sid, kind: kind, name: name, target: target))
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }

    // MARK: Worker

    private func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private func sessions() -> [String: [String: Any]] {
        let dir = claudeDir.appendingPathComponent("sessions")
        var out: [String: [String: Any]] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (d["pid"] as? NSNumber)?.intValue, let sid = d["sessionId"] as? String,
                  isAlive(pid) else { continue }
            out[sid] = d
        }
        return out
    }

    private func tick() {
        let m = Self.midnight()
        if m != midnight {
            midnight = m
            today = [:]
            toolsToday = [:]
            filesToday = []
        }
        let live = sessions()
        // Track live sessions plus anything active in the last 24 hours (for the day's totals).
        let cutoff = Date().addingTimeInterval(-86400)
        let fm = FileManager.default
        let projectsDir = claudeDir.appendingPathComponent("projects")
        for dir in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for p in files where p.pathExtension == "jsonl" {
                let sid = p.deletingPathExtension().lastPathComponent
                let mtime = (try? p.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard live[sid] != nil || (mtime ?? .distantPast) > cutoff else { continue }
                let tr = transcripts[sid] ?? Transcript(sid: sid, path: p)
                transcripts[sid] = tr
                tr.update(self)
            }
        }

        let now = Date().timeIntervalSince1970
        let procs = Self.procs()
        var agents: [AgentInfo] = []
        for (sid, s) in live {
            guard let tr = transcripts[sid], let pid = (s["pid"] as? NSNumber)?.intValue else { continue }
            let cwd = (s["cwd"] as? String) ?? tr.cwd ?? ""
            let tree = Self.descendants(pid, procs)
            let all = [pid] + tree
            let cpu = cpuPercent(pid, all, procs, now)
            let rss = all.reduce(0.0) { $0 + (procs[$1]?.rss ?? 0) }
            var kidCounts: [String: Int] = [:]
            for p in tree {
                if let c = procs[p]?.comm, !["bash", "sh", "zsh", "-zsh", "-bash"].contains(c) { kidCounts[c, default: 0] += 1 }
            }
            let minuteNow = Int(now / 60)
            let spark = (0..<60).reversed().map { tr.minutes[minuteNow - $0] ?? 0 }
            let outRate = Double(tr.outTimes.filter { $0.0 > now - 120 }.reduce(0) { $0 + $1.1 }) / 2
            let ms = { (k: String) -> Double? in (s[k] as? NSNumber)?.doubleValue }
            let args = procs[pid]?.args ?? []
            agents.append(AgentInfo(
                sid: sid, pid: pid, title: (s["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tr.title ?? "Untitled session",
                project: projectOf(cwd), cwd: cwd,
                model: prettyModel(tr.model ?? Self.arg(args, "--model")),
                effort: Self.arg(args, "--effort") ?? "default",
                busy: (s["status"] as? String) == "busy",
                since: (ms("statusUpdatedAt") ?? ms("updatedAt") ?? ms("startedAt") ?? now * 1000) / 1000,
                started: (ms("startedAt") ?? now * 1000) / 1000,
                prompts: tr.prompts, toolCalls: tr.tools.values.reduce(0, +), errors: tr.errors,
                tokens: tr.tokens, ctx: tr.ctx, outRate: outRate, last: tr.lastTool, spark: spark,
                cpu: cpu, rss: rss, kids: Array(kidCounts.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }),
                subagents: tr.subagents.count, files: tr.files.count, git: gitInfo(cwd, now),
                tools: Array(tr.tools.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) })))
        }
        agents.sort { a, b in
            if a.busy != b.busy { return a.busy }
            return (a.last?.t ?? 0) > (b.last?.t ?? 0)
        }

        let hour0 = Int(now / 3600) - 23
        let projects = Array(Set(agents.map(\.project)).union(hours.keys.filter { $0.hour >= hour0 }.map(\.project))).sorted()
        let hourRows = (0..<24).map { i in projects.map { p in (p, hours[HourKey(hour: hour0 + i, project: p)] ?? 0) } }
        hours = hours.filter { $0.key.hour >= hour0 - 1 }
        let others = Array(Set(procs.values.map(\.comm)).intersection(otherRuntimes)).sorted()
        let snap = AgentSnapshot(
            t: now, agents: agents, events: events, today: today,
            toolsToday: Array(toolsToday.sorted { $0.value > $1.value }.prefix(7).map { ($0.key, $0.value) }),
            filesToday: filesToday.count, hours: hourRows, projects: projects,
            sessionsToday: transcripts.values.filter { ($0.lastT ?? 0) >= midnight }.count, others: others)
        lock.withLock { published = snap }
    }

    /// pid -> (ppid, CPU seconds, RSS bytes, command name, arguments), from `ps`.
    private static func procs() -> [Int: Proc] {
        guard let out = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,rss=,time=,args="], cwd: nil) else { return [:] }
        var result: [Int: Proc] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int(f[0]), let ppid = Int(f[1]), let rss = Double(f[2]) else { continue }
            let args = f[4].split(separator: " ").map(String.init)
            let comm = ((args.first ?? "") as NSString).lastPathComponent
            result[pid] = Proc(ppid: ppid, cpu: cpuSeconds(String(f[3])), rss: rss * 1024, comm: comm, args: args)
        }
        return result
    }

    /// ps TIME: [[dd-]hh:]mm:ss.ss
    private static func cpuSeconds(_ s: String) -> Double {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return days * 86400 + total
    }

    private static func descendants(_ pid: Int, _ procs: [Int: Proc]) -> [Int] {
        var kids: [Int: [Int]] = [:]
        for (p, info) in procs { kids[info.ppid, default: []].append(p) }
        var out: [Int] = []
        var stack = kids[pid] ?? []
        while let p = stack.popLast() {
            out.append(p)
            stack.append(contentsOf: kids[p] ?? [])
        }
        return out
    }

    private func cpuPercent(_ key: Int, _ pids: [Int], _ procs: [Int: Proc], _ now: Double) -> Double {
        let secs = pids.reduce(0.0) { $0 + (procs[$1]?.cpu ?? 0) }
        let prev = cpuPrev[key]
        cpuPrev[key] = (secs, now)
        guard let prev, now > prev.1 else { return 0 }
        return max(0, (secs - prev.0) / (now - prev.1) * 100)
    }

    private static func arg(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Git

    /// A real git binary; /usr/bin/git without the developer tools would pop up an
    /// install dialog, so it's only used when they're installed.
    private static let gitPath: String? = {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                          "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }()

    private func gitInfo(_ cwd: String, _ now: Double) -> AgentGit? {
        guard !cwd.isEmpty, let gitPath = Self.gitPath else { return nil }
        if now - (gitT[cwd] ?? 0) < 20 { return git[cwd] ?? nil }
        gitT[cwd] = now
        func g(_ args: String...) -> String? { Self.run(gitPath, ["-C", cwd] + args, cwd: nil) }
        guard let branch = g("rev-parse", "--abbrev-ref", "HEAD") else {
            git[cwd] = .some(nil)
            return nil
        }
        var add = 0, del = 0
        for line in (g("diff", "--numstat", "HEAD") ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count >= 2 {
                add += Int(parts[0]) ?? 0
                del += Int(parts[1]) ?? 0
            }
        }
        let changed = (g("status", "--porcelain") ?? "").split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let ahead = Int((g("rev-list", "--count", "@{u}..HEAD") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let info = AgentGit(branch: branch.trimmingCharacters(in: .whitespacesAndNewlines), add: add, del: del,
                            changed: changed, ahead: ahead)
        git[cwd] = info
        return info
    }

    /// Runs a command and returns its output, or nil if it fails or takes over 3 seconds.
    private static func run(_ path: String, _ args: [String], cwd: String?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"  // never take the index lock away from a working agent
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
