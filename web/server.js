#!/usr/bin/env node
// Round Table Web UI — 토론 진행 상황 모니터링 서버
// Usage: node server.js [port]

import { createServer } from "node:http";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, extname, resolve } from "node:path";
import { spawn } from "node:child_process";

// .env 파일 로딩 (dotenv 없이)
const BASE = resolve(import.meta.dirname, "..");
const envPath = join(BASE, ".env");
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, "utf-8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eqIdx = trimmed.indexOf("=");
    if (eqIdx < 1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    const val = trimmed.slice(eqIdx + 1).trim().replace(/^["']|["']$/g, "");
    if (key && !(key in process.env)) process.env[key] = val;
  }
}

const PORT = parseInt(process.env.PORT || process.argv[2] || "3847", 10);
const SESSIONS_DIR = join(BASE, "sessions");
const LOGS_DIR = join(BASE, "logs");

// 프로젝트 루트: PROJECT_DIR 환경변수 > round-table의 상위 디렉토리
const WORKSPACE_DIR = process.env.PROJECT_DIR
  ? resolve(process.env.PROJECT_DIR)
  : resolve(BASE, "..");

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".md": "text/plain; charset=utf-8",
  ".log": "text/plain; charset=utf-8",
};

// 사용 가능한 에이전트 목록
const AVAILABLE_AGENTS = [
  { id: "analyst",    name: "시장 분석가",    description: "시장 데이터, 경쟁사 분석, WebSearch 활용" },
  { id: "developer",  name: "기술 리드",      description: "코드베이스 확인, 기술적 실현 가능성" },
  { id: "critic",     name: "악마의 변호인",  description: "반론, 리스크, 대안 제시" },
  { id: "designer",   name: "UX 디자이너",    description: "사용자 경험, 플로우, 모바일 UX" },
  { id: "financial",  name: "재무 분석가",    description: "비용, 수익, ROI, 손익분기점" },
  { id: "strategist", name: "장기 전략가",    description: "포지셔닝, 경쟁 우위, 포트폴리오 영향" },
];

// --- Helper ---

function safeRead(path) {
  try { return readFileSync(path, "utf-8"); } catch { return null; }
}

function safeJson(path) {
  const raw = safeRead(path);
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

// --- API Handlers ---

function listAgents() {
  return AVAILABLE_AGENTS;
}

function listProjects() {
  const wsName = WORKSPACE_DIR.split("/").pop() || "workspace";
  const projects = [{ id: "root", name: `${wsName} (전체)`, path: WORKSPACE_DIR }];
  if (!existsSync(WORKSPACE_DIR)) return projects;

  const SKIP = new Set(["node_modules", ".git", "packages", "logs", "sessions",
    "build", ".dart_tool", ".gradle", ".idea", "android", "ios", "web", ".fvm"]);

  const getLabel = (dir, name) => {
    if (existsSync(join(dir, "pubspec.yaml"))) return `${name} (Flutter)`;
    if (existsSync(join(dir, "package.json"))) return `${name} (Node)`;
    if (existsSync(join(dir, "pyproject.toml")) || existsSync(join(dir, "setup.py"))) return `${name} (Python)`;
    if (existsSync(join(dir, "go.mod"))) return `${name} (Go)`;
    return null;
  };

  for (const d of readdirSync(WORKSPACE_DIR).sort()) {
    if (d.startsWith(".") || SKIP.has(d)) continue;
    const full = join(WORKSPACE_DIR, d);
    try { if (!statSync(full).isDirectory()) continue; } catch { continue; }

    const label = getLabel(full, d);
    if (label) {
      projects.push({ id: d, name: label, path: full });
    } else {
      // 프로젝트 마커 없음 → 한 단계 더 탐색 (예: code/ 컨테이너)
      const children = [];
      try {
        for (const sub of readdirSync(full).sort()) {
          if (sub.startsWith(".") || SKIP.has(sub)) continue;
          const subFull = join(full, sub);
          try { if (!statSync(subFull).isDirectory()) continue; } catch { continue; }
          const subLabel = getLabel(subFull, sub);
          if (subLabel) children.push({ id: `${d}/${sub}`, name: subLabel, path: subFull });
        }
      } catch {}
      if (children.length) {
        projects.push({ id: d, name: `${d} (전체)`, path: full });
        projects.push(...children);
      }
    }
  }
  return projects;
}

function listSessions() {
  if (!existsSync(SESSIONS_DIR)) return [];
  return readdirSync(SESSIONS_DIR)
    .filter((d) => statSync(join(SESSIONS_DIR, d)).isDirectory())
    .sort()
    .reverse()
    .map((d) => {
      const meta = safeJson(join(SESSIONS_DIR, d, "meta.json")) || {
        topic: "Unknown", status: "unknown",
      };
      return { id: d, ...meta };
    });
}

function getSession(id) {
  const dir = join(SESSIONS_DIR, id);
  if (!existsSync(dir)) return null;
  const meta = safeJson(join(dir, "meta.json")) || {};

  const files = {};
  const collectMd = (d, prefix = "") => {
    if (!existsSync(d)) return;
    for (const f of readdirSync(d)) {
      const full = join(d, f);
      const rel = prefix ? `${prefix}/${f}` : f;
      if (statSync(full).isDirectory()) {
        collectMd(full, rel);
      } else if (f.endsWith(".md")) {
        files[rel] = safeRead(full) || "";
      }
    }
  };
  collectMd(dir);
  return { ...meta, files };
}

function getLogs() {
  if (!existsSync(LOGS_DIR)) return {};
  const logs = {};
  for (const f of readdirSync(LOGS_DIR)) {
    if (f.endsWith(".log")) {
      logs[f.replace(".log", "")] = safeRead(join(LOGS_DIR, f)) || "";
    }
  }
  return logs;
}

function startDebate({ topic, rounds = 2, agents = "analyst,developer,critic", projectDir }) {
  const dir = projectDir && existsSync(projectDir) ? projectDir : WORKSPACE_DIR;
  const r = Math.min(Math.max(parseInt(rounds) || 2, 1), 9);
  const agentStr = (Array.isArray(agents) ? agents.join(",") : agents).trim() || "analyst,developer,critic";

  const script = join(BASE, "orchestrator.sh");
  const child = spawn("bash", [script, topic, String(r), agentStr, dir], {
    cwd: BASE,
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  return { started: true, pid: child.pid, rounds: r, agents: agentStr };
}

// --- SSE Log Streaming ---

function streamLogs(res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
  });

  const sendLogs = () => {
    const logs = getLogs();
    res.write(`data: ${JSON.stringify(logs)}\n\n`);
  };
  const sendSessions = () => {
    const sessions = listSessions().slice(0, 5);
    res.write(`event: sessions\ndata: ${JSON.stringify(sessions)}\n\n`);
  };

  sendLogs();
  const logInterval = setInterval(sendLogs, 2000);
  const sessionInterval = setInterval(sendSessions, 3000);

  res.on("close", () => {
    clearInterval(logInterval);
    clearInterval(sessionInterval);
  });
}

// --- HTTP Server ---

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const path = url.pathname;

  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

  const json = (data, status = 200) => {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data));
  };

  if (path === "/api/agents") return json(listAgents());
  if (path === "/api/projects") return json(listProjects());
  if (path === "/api/sessions") return json(listSessions());

  if (path.startsWith("/api/session/")) {
    const id = path.split("/")[3];
    const session = getSession(id);
    return session ? json(session) : json({ error: "Not found" }, 404);
  }

  if (path === "/api/logs") return json(getLogs());
  if (path === "/api/logs/stream") return streamLogs(res);

  if (path === "/api/continue" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const { sessionId, rounds = 2 } = JSON.parse(body);
        if (!sessionId) return json({ error: "sessionId is required" }, 400);
        const sessionDir = join(SESSIONS_DIR, sessionId);
        if (!existsSync(sessionDir)) return json({ error: "Session not found" }, 404);
        const r = Math.min(Math.max(parseInt(rounds) || 2, 1), 9);
        const script = join(BASE, "orchestrator.sh");
        const child = spawn("bash", [script, "--continue", sessionId, String(r)], {
          cwd: BASE, detached: true, stdio: "ignore",
        });
        child.unref();
        return json({ started: true, pid: child.pid, sessionId, additionalRounds: r });
      } catch (e) {
        return json({ error: e.message }, 400);
      }
    });
    return;
  }

  if (path === "/api/start" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const params = JSON.parse(body);
        if (!params.topic?.trim()) return json({ error: "topic is required" }, 400);
        return json(startDebate(params));
      } catch (e) {
        return json({ error: e.message }, 400);
      }
    });
    return;
  }

  // Static files
  const filePath = path === "/" ? "/index.html" : path;
  const fullPath = join(import.meta.dirname, filePath);
  if (existsSync(fullPath) && statSync(fullPath).isFile()) {
    res.writeHead(200, { "Content-Type": MIME[extname(fullPath)] || "text/plain" });
    res.end(readFileSync(fullPath));
  } else {
    const indexPath = join(import.meta.dirname, "index.html");
    if (existsSync(indexPath)) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(readFileSync(indexPath));
    } else {
      res.writeHead(404); res.end("Not Found");
    }
  }
});

server.listen(PORT, () => {
  console.log(`🏴‍☠️ Round Table UI: http://localhost:${PORT}`);
});
