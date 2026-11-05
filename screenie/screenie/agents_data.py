"""Watches the AI agents running on this computer.

Claude Code writes one JSON-lines transcript per session and a small status
file per running process. This module tails those files (only reading new
bytes after the first pass) and samples /proc for CPU, memory and child
processes, then publishes an immutable snapshot for the renderer every second.

Only metadata leaves this module: titles, project folders, tool names, file
basenames and token counts. Prompts, code and command text are never read
into the snapshot.
"""

import glob
import json
import os
import subprocess
import threading
import time
from collections import Counter, deque
from datetime import datetime

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
CLK_TCK = os.sysconf("SC_CLK_TCK")
OTHER_RUNTIMES = ("ollama", "llama-server", "llama-cli", "vllm", "lmstudio", "lms", "codex", "gemini",
                  "aider", "goose", "cursor-agent", "opencode")
FILE_TOOLS = ("Read", "Edit", "Write", "NotebookEdit", "MultiEdit")


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def pretty_model(m):
    if not m:
        return "?"
    parts = m.replace("claude-", "").split("-")
    if len(parts) >= 3 and parts[1].isdigit():
        return f"{parts[0].title()} {parts[1]}.{parts[2]}"
    return m


class Transcript:
    """Incrementally parsed session transcript (plus any subagent transcripts)."""

    def __init__(self, sid, path):
        self.sid, self.path = sid, path
        self.offsets = {}
        self.partial = {}
        self.msg_ids, self.tool_ids = set(), set()
        self.tokens = Counter()
        self.tools = Counter()
        self.prompts = 0
        self.errors = 0
        self.subagents = set()
        self.files = set()
        self.model = None
        self.ctx = 0
        self.title = None
        self.cwd = None
        self.first_t = None
        self.last_t = None
        self.last_tool = None  # (name, target, t)
        self.minutes = Counter()  # epoch minute -> actions
        self.out_times = deque(maxlen=400)  # (t, output tokens)

    def paths(self):
        yield self.path
        yield from glob.glob(os.path.join(os.path.dirname(self.path), self.sid, "subagents", "*.jsonl"))

    def update(self, hub):
        for p in self.paths():
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            off = self.offsets.get(p, 0)
            if size < off:
                off = 0
            if size == off:
                continue
            with open(p, "rb") as f:
                f.seek(off)
                data = self.partial.pop(p, b"") + f.read()
            self.offsets[p] = size
            lines = data.split(b"\n")
            if lines and lines[-1]:
                self.partial[p] = lines.pop()
            sub = p != self.path
            for line in lines:
                if line:
                    try:
                        self._entry(json.loads(line), hub, sub)
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue

    def _entry(self, e, hub, sub):
        kind = e.get("type")
        if kind == "custom-title":
            self.title = e.get("customTitle") or self.title
            return
        t = parse_ts(e.get("timestamp"))
        if t is None:
            return
        self.first_t = t if self.first_t is None else min(self.first_t, t)
        self.last_t = t if self.last_t is None else max(self.last_t, t)
        if e.get("cwd"):
            self.cwd = e["cwd"]
        if sub or e.get("isSidechain"):
            self.subagents.add(e.get("agentId") or e.get("sessionId") or "sub")
        msg = e.get("message")
        if not isinstance(msg, dict):
            return
        content = msg.get("content")
        if kind == "assistant":
            mid = msg.get("id")
            u = msg.get("usage")
            if u and mid not in self.msg_ids:
                self.msg_ids.add(mid)
                out = u.get("output_tokens", 0)
                inp = u.get("input_tokens", 0)
                cw = u.get("cache_creation_input_tokens", 0)
                cr = u.get("cache_read_input_tokens", 0)
                think = (u.get("output_tokens_details") or {}).get("thinking_tokens", 0)
                self.tokens.update(input=inp, cache_write=cw, cache_read=cr, output=out, thinking=think)
                if not sub:
                    self.ctx = inp + cw + cr + out
                    self.model = msg.get("model") or self.model
                self.out_times.append((t, out))
                hub.count_tokens(t, inp, cw, cr, out, think)
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id") not in self.tool_ids:
                        self.tool_ids.add(b.get("id"))
                        self._tool(b, t, hub, sub)
        elif kind == "user":
            if isinstance(content, str) and not sub and e.get("userType") == "external":
                self.prompts += 1
                hub.event(self, t, "prompt", "New task", "")
                hub.count_action(t, self, prompt=True)
            elif isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                        self.errors += 1
                    elif isinstance(b, dict) and b.get("type") == "text" and not sub \
                            and e.get("userType") == "external" and not e.get("isMeta"):
                        self.prompts += 1
                        hub.event(self, t, "prompt", "New task", "")
                        hub.count_action(t, self, prompt=True)
                        break

    def _tool(self, b, t, hub, sub):
        name = b.get("name", "?")
        if name.startswith("mcp__"):
            name = name.split("__")[-1]
        inp = b.get("input") or {}
        target = ""
        if name in FILE_TOOLS and inp.get("file_path"):
            target = os.path.basename(inp["file_path"])
            if name != "Read":
                self.files.add(inp["file_path"])
                hub.files_today_add(t, inp["file_path"])
        elif name == "Bash":
            target = inp.get("description", "")
        elif name in ("Agent", "Task"):
            target = inp.get("description", "")
        elif name in ("WebSearch", "WebFetch"):
            target = "web"
        self.tools[name] += 1
        self.minutes[int(t // 60)] += 1
        self.last_tool = (name, target, t)
        hub.event(self, t, "subtool" if sub else "tool", name, target)
        hub.count_action(t, self, tool=name)


class AgentHub:
    _instance = None

    @classmethod
    def get_instance(cls):
        if cls._instance is None:
            cls._instance = AgentHub()
        return cls._instance

    def __init__(self):
        self.transcripts = {}
        self.events = deque(maxlen=80)
        self.seq = 0
        self.loading = True
        self.midnight = self._midnight()
        self.today = Counter()
        self.tools_today = Counter()
        self.files_today = set()
        self.hours = Counter()  # (hour epoch, project) -> actions
        self.cpu_prev = {}
        self.git = {}
        self.git_t = {}
        self.snapshot = None
        threading.Thread(target=self._run, daemon=True, name="screenie-agents").start()

    @staticmethod
    def _midnight():
        n = datetime.now()
        return datetime(n.year, n.month, n.day).timestamp()

    # --- counters fed by transcripts

    def count_tokens(self, t, inp, cw, cr, out, think):
        if t >= self.midnight:
            self.today.update(input=inp, cache_write=cw, cache_read=cr, output=out, thinking=think)

    def count_action(self, t, tr, tool=None, prompt=False):
        if t >= time.time() - 86400:
            self.hours[(int(t // 3600), project_of(tr.cwd))] += 1
        if t >= self.midnight:
            if tool:
                self.tools_today[tool] += 1
                self.today["tool_calls"] += 1
            if prompt:
                self.today["prompts"] += 1

    def files_today_add(self, t, path):
        if t >= self.midnight:
            self.files_today.add(path)

    def event(self, tr, t, kind, name, target):
        if t < time.time() - 3600:
            return
        self.seq += 1
        self.events.append((self.seq, t, tr.sid, kind, name, target))

    # --- worker

    def _run(self):
        while True:
            try:
                self._tick()
            except Exception:  # noqa: BLE001 - keep watching even if one pass hits something odd
                pass
            self.loading = False
            time.sleep(1)

    def _sessions(self):
        out = {}
        for f in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
            try:
                d = json.load(open(f))
            except (OSError, ValueError):
                continue
            pid = d.get("pid")
            if pid and os.path.exists(f"/proc/{pid}") and d.get("sessionId"):
                out[d["sessionId"]] = d
        return out

    def _tick(self):
        if self._midnight() != self.midnight:
            self.midnight = self._midnight()
            self.today.clear()
            self.tools_today.clear()
            self.files_today.clear()
        live = self._sessions()
        # Track live sessions plus anything active in the last 24 hours (for the day's totals).
        cutoff = time.time() - 86400
        wanted = {}
        for p in glob.glob(os.path.join(CLAUDE, "projects", "*", "*.jsonl")):
            sid = os.path.basename(p)[:-6]
            try:
                recent = os.path.getmtime(p) > cutoff
            except OSError:
                continue
            if sid in live or recent:
                wanted[sid] = p
        for sid, p in wanted.items():
            tr = self.transcripts.get(sid)
            if tr is None:
                tr = self.transcripts[sid] = Transcript(sid, p)
            tr.update(self)

        now = time.time()
        procs = self._procs()
        agents = []
        for sid, s in live.items():
            tr = self.transcripts.get(sid)
            if tr is None:
                continue
            pid = s["pid"]
            cwd = s.get("cwd") or tr.cwd or ""
            tree = self._descendants(pid, procs)
            cpu = self._cpu(pid, [pid] + tree, procs, now)
            rss = sum(procs.get(p, (0, 0, 0, ""))[2] for p in [pid] + tree)
            kids = Counter(procs[p][3] for p in tree if p in procs and procs[p][3] not in ("bash", "sh", "zsh"))
            spark = [tr.minutes.get(int(now // 60) - i, 0) for i in range(59, -1, -1)]
            out_rate = sum(n for ts, n in tr.out_times if ts > now - 120) / 2
            agents.append(dict(
                sid=sid, pid=pid, title=s.get("name") or tr.title or "Untitled session",
                project=project_of(cwd), cwd=cwd, model=pretty_model(tr.model or self._arg(pid, "--model")),
                effort=self._arg(pid, "--effort") or "default",
                busy=s.get("status") == "busy",
                since=(s.get("statusUpdatedAt") or s.get("updatedAt") or s.get("startedAt") or now * 1000) / 1000,
                started=(s.get("startedAt") or now * 1000) / 1000,
                prompts=tr.prompts, tool_calls=sum(tr.tools.values()), errors=tr.errors,
                tokens=dict(tr.tokens), ctx=tr.ctx, out_rate=out_rate, last=tr.last_tool,
                spark=spark, cpu=cpu, rss=rss, kids=kids.most_common(3), subagents=len(tr.subagents),
                files=len(tr.files), git=self._git(cwd, now), tools=tr.tools.most_common(4),
                entry=s.get("entrypoint", ""),
            ))
        agents.sort(key=lambda a: (not a["busy"], -(a["last"][2] if a["last"] else 0)))

        hour0 = int(now // 3600) - 23
        projects = sorted({a["project"] for a in agents} | {p for (h, p) in self.hours if h >= hour0})
        hours = [[(p, self.hours.get((hour0 + i, p), 0)) for p in projects] for i in range(24)]
        git_add = sum(a["git"]["add"] for a in agents if a["git"])
        git_del = sum(a["git"]["del"] for a in agents if a["git"])
        seen = set()
        for a in agents:  # count each repo once
            if a["git"] and a["cwd"] in seen:
                git_add -= a["git"]["add"]
                git_del -= a["git"]["del"]
            seen.add(a["cwd"])
        others = sorted({c for _, _, _, c in procs.values() if c in OTHER_RUNTIMES})
        self.snapshot = dict(
            t=now, agents=agents, events=list(self.events), today=dict(self.today),
            tools_today=self.tools_today.most_common(7), files_today=len(self.files_today),
            hours=hours, hour0=hour0, projects=projects, git_add=git_add, git_del=git_del,
            sessions_today=sum(1 for tr in self.transcripts.values() if (tr.last_t or 0) >= self.midnight),
            others=others, loading=False,
        )

    @staticmethod
    def _procs():
        """pid -> (ppid, cpu ticks, rss bytes, comm)."""
        out = {}
        page = os.sysconf("SC_PAGE_SIZE")
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open(f"/proc/{d}/stat") as f:
                    s = f.read()
                comm = s[s.index("(") + 1:s.rindex(")")]
                rest = s[s.rindex(")") + 2:].split()
                out[int(d)] = (int(rest[1]), int(rest[11]) + int(rest[12]), int(rest[21]) * page, comm)
            except (OSError, ValueError, IndexError):
                continue
        return out

    @staticmethod
    def _descendants(pid, procs):
        kids = {}
        for p, (pp, *_rest) in procs.items():
            kids.setdefault(pp, []).append(p)
        out, stack = [], list(kids.get(pid, []))
        while stack:
            p = stack.pop()
            out.append(p)
            stack.extend(kids.get(p, []))
        return out

    def _cpu(self, key, pids, procs, now):
        ticks = sum(procs[p][1] for p in pids if p in procs)
        prev = self.cpu_prev.get(key)
        self.cpu_prev[key] = (ticks, now)
        if not prev or now <= prev[1]:
            return 0.0
        return max(0.0, (ticks - prev[0]) / CLK_TCK / (now - prev[1]) * 100)

    @staticmethod
    def _arg(pid, flag):
        try:
            args = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
            i = args.index(flag.encode())
            return args[i + 1].decode()
        except (OSError, ValueError, IndexError):
            return None

    def _git(self, cwd, now):
        if not cwd:
            return None
        if now - self.git_t.get(cwd, 0) < 20:
            return self.git.get(cwd)
        self.git_t[cwd] = now
        try:
            run = lambda *a: subprocess.run(["git", "-C", cwd, *a], capture_output=True, text=True,  # noqa: E731
                                            timeout=3)
            br = run("rev-parse", "--abbrev-ref", "HEAD")
            if br.returncode != 0:
                self.git[cwd] = None
                return None
            add = dele = 0
            for line in run("diff", "--numstat", "HEAD").stdout.splitlines():
                a, d, _ = (line.split("\t") + ["", ""])[:3]
                add += int(a) if a.isdigit() else 0
                dele += int(d) if d.isdigit() else 0
            changed = len([l for l in run("status", "--porcelain").stdout.splitlines() if l.strip()])
            ahead = run("rev-list", "--count", "@{u}..HEAD")
            self.git[cwd] = dict(branch=br.stdout.strip(), add=add, del_=dele, changed=changed,
                                 ahead=int(ahead.stdout.strip()) if ahead.returncode == 0 else 0)
            self.git[cwd]["del"] = dele
        except (OSError, subprocess.SubprocessError, ValueError):
            self.git[cwd] = None
        return self.git.get(cwd)


def project_of(cwd):
    if not cwd:
        return "?"
    base = os.path.basename(cwd.rstrip("/")) or cwd
    if "scratch" in cwd and ".config/Claude" in cwd:
        return "scratch"
    return base
