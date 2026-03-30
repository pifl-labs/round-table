#!/usr/bin/env node
// Round Table Web UI — 토론 진행 상황 모니터링 서버
// Usage: node server.js [port]

import { createServer } from "node:http";
import { request } from "node:https";
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, statSync, existsSync } from "node:fs";
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
const CR_SESSIONS_DIR = join(BASE, "sessions", "code-review");
const TASK_SESSIONS_DIR = join(BASE, "sessions", "tasks");
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
    .filter((d) => {
      if (d === "code-review") return false; // code-review 세션은 별도 디렉토리
      try { return statSync(join(SESSIONS_DIR, d)).isDirectory(); } catch { return false; }
    })
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

function startDebateWithId({ topic, rounds = 2, agents = "analyst,developer,critic", projectDir, telegramChatId }) {
  const dir = projectDir && existsSync(projectDir) ? projectDir : WORKSPACE_DIR;
  const r = Math.min(Math.max(parseInt(rounds) || 2, 1), 9);
  const agentStr = (Array.isArray(agents) ? agents.join(",") : agents).trim() || "analyst,developer,critic";
  const sessionId = makeSessionId();
  const sessionDir = join(SESSIONS_DIR, sessionId);
  mkdirSync(sessionDir, { recursive: true });
  if (telegramChatId) writeFileSync(join(sessionDir, ".telegram"), String(telegramChatId));
  const script = join(BASE, "orchestrator.sh");
  const child = spawn("bash", [script, topic, String(r), agentStr, dir, sessionId], {
    cwd: BASE, detached: true, stdio: "ignore",
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId, rounds: r, agents: agentStr };
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

// --- Code Review API Handlers ---

function listCodeReviewSessions() {
  if (!existsSync(CR_SESSIONS_DIR)) return [];
  return readdirSync(CR_SESSIONS_DIR)
    .filter((d) => {
      try { return statSync(join(CR_SESSIONS_DIR, d)).isDirectory(); } catch { return false; }
    })
    .sort().reverse()
    .map((d) => {
      const meta = safeJson(join(CR_SESSIONS_DIR, d, "meta.json")) || {
        topic: "Unknown", status: "unknown",
      };
      return { id: d, ...meta };
    });
}

function getCodeReviewSession(id) {
  const dir = join(CR_SESSIONS_DIR, id);
  if (!existsSync(dir)) return null;
  const meta = safeJson(join(dir, "meta.json")) || {};
  const agents = safeJson(join(dir, "agents.json")) || {};

  const files = {};
  const collectMd = (d, prefix = "") => {
    if (!existsSync(d)) return;
    for (const f of readdirSync(d)) {
      const full = join(d, f);
      const rel = prefix ? `${prefix}/${f}` : f;
      if (statSync(full).isDirectory()) {
        collectMd(full, rel);
      } else if (f.endsWith(".md") || f.endsWith(".json")) {
        files[rel] = safeRead(full) || "";
      }
    }
  };
  collectMd(dir);
  return { ...meta, agents_detail: agents, files };
}

function getCodeReviewLogs(sessionId) {
  if (!existsSync(LOGS_DIR)) return {};
  const prefix = `cr-${sessionId}-`;
  const logs = {};
  for (const f of readdirSync(LOGS_DIR)) {
    if (f.startsWith(prefix) && f.endsWith(".log")) {
      const key = f.replace(prefix, "").replace(".log", "");
      const raw = safeRead(join(LOGS_DIR, f)) || "";
      logs[key] = raw.length > 4000 ? raw.slice(-4000) : raw;
    }
  }
  return logs;
}

function makeSessionId() {
  const now = new Date();
  const p = (x, l = 2) => String(x).padStart(l, "0");
  return `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}_${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
}

function startCodeReview({ topic, context = "", rounds = 2, agentCount = 5, projectDir, aiProfile = "claude" }) {
  const dir = projectDir && existsSync(projectDir) ? projectDir : WORKSPACE_DIR;
  const r = Math.min(Math.max(parseInt(rounds) || 2, 1), 9);
  const n = Math.min(Math.max(parseInt(agentCount) || 5, 2), 12);

  // 서버가 세션 디렉토리와 meta.json을 즉시 생성 (UI가 바로 표시할 수 있도록)
  const sessionId = makeSessionId();
  const sessionDir = join(CR_SESSIONS_DIR, sessionId);
  mkdirSync(sessionDir, { recursive: true });
  const meta = {
    type: "code-review",
    topic,
    context,
    rounds: r,
    agent_count: n,
    project_dir: dir,
    started_at: new Date().toISOString(),
    status: "generating-agents",
    converged: false,
    current_round: 0,
    quality_score: 0,
    release_ready: false,
    language: "",
    framework: "",
    agents: [],
    ai_profile: aiProfile,
  };
  writeFileSync(join(sessionDir, "meta.json"), JSON.stringify(meta, null, 2));

  // 에이전트 생성만 실행 (run은 UI에서 확인 후 별도 호출)
  const script = join(BASE, "code-review-orchestrator.sh");
  const child = spawn("bash", [script, "generate", sessionId], {
    cwd: BASE, detached: true, stdio: "ignore", env: { ...process.env },
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId, rounds: r, agentCount: n };
}

function runCodeReview(sessionId, aiProfile) {
  const sessionDir = join(CR_SESSIONS_DIR, sessionId);
  if (!existsSync(sessionDir)) return null;
  const meta = safeJson(join(sessionDir, "meta.json")) || {};
  if (meta.status !== "agents-ready") return { error: `잘못된 상태: ${meta.status}` };
  // AI 프로파일 변경이 있으면 meta.json에 반영
  const validProfiles = ["claude", "gemini-cli", "codex-cli"];
  if (aiProfile && validProfiles.includes(aiProfile) && aiProfile !== meta.ai_profile) {
    writeFileSync(
      join(sessionDir, "meta.json"),
      JSON.stringify({ ...meta, ai_profile: aiProfile }, null, 2)
    );
  }
  const script = join(BASE, "code-review-orchestrator.sh");
  const child = spawn("bash", [script, "run", sessionId], {
    cwd: BASE, detached: true, stdio: "ignore", env: { ...process.env },
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId, ai_profile: aiProfile || meta.ai_profile };
}

function continueCodeReview({ sessionId, rounds = 1 }) {
  const sessionDir = join(CR_SESSIONS_DIR, sessionId);
  if (!existsSync(sessionDir)) return null;
  const r = Math.min(Math.max(parseInt(rounds) || 1, 1), 9);
  const script = join(BASE, "code-review-orchestrator.sh");
  const child = spawn("bash", [script, "--continue", sessionId, String(r)], {
    cwd: BASE, detached: true, stdio: "ignore", env: { ...process.env },
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId, additionalRounds: r };
}

function streamCodeReviewLogs(res, sessionId) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
  });

  const sendLogs = () => {
    const logs = getCodeReviewLogs(sessionId || "");
    res.write(`data: ${JSON.stringify(logs)}\n\n`);
  };
  const sendSession = () => {
    if (!sessionId) return;
    const session = getCodeReviewSession(sessionId);
    if (session) res.write(`event: session\ndata: ${JSON.stringify(session)}\n\n`);
  };
  const sendSessions = () => {
    const sessions = listCodeReviewSessions().slice(0, 5);
    res.write(`event: sessions\ndata: ${JSON.stringify(sessions)}\n\n`);
  };

  sendLogs();
  sendSessions();
  const logInterval = setInterval(sendLogs, 2000);
  const sessionInterval = setInterval(() => { sendSession(); sendSessions(); }, 3000);

  res.on("close", () => {
    clearInterval(logInterval);
    clearInterval(sessionInterval);
  });
}

// --- Telegram Integration ---

const TELEGRAM_TOKEN = process.env.TELEGRAM_BOT_TOKEN || process.env.PIFL_BOT_TOKEN || "";
let telegramOffset = 0;
const notifiedSessions = new Set();
const convState = new Map(); // chatId -> { cmd, step, params }

function telegramPost(method, data) {
  return new Promise((resolve) => {
    const body = JSON.stringify(data);
    const req = request({
      hostname: "api.telegram.org",
      path: `/bot${TELEGRAM_TOKEN}/${method}`,
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, (res) => {
      let raw = "";
      res.on("data", c => raw += c);
      res.on("end", () => { try { resolve(JSON.parse(raw)); } catch { resolve({}); } });
    });
    req.on("error", () => resolve({}));
    req.write(body); req.end();
  });
}

async function sendTelegram(chatId, text, keyboard = null) {
  if (!TELEGRAM_TOKEN || !chatId) return;
  const payload = { chat_id: chatId, text, parse_mode: "Markdown" };
  if (keyboard) payload.reply_markup = { inline_keyboard: keyboard };
  try { return await telegramPost("sendMessage", payload); }
  catch(e) { console.error("Telegram send error:", e.message); }
}

// BotFather: register slash commands for autocomplete
async function registerBotCommands() {
  if (!TELEGRAM_TOKEN) return;
  try {
    await telegramPost("setMyCommands", {
      commands: [
        { command: "debate",   description: "🏴‍☠️ 전략 토론 시작" },
        { command: "review",   description: "🔍 코드 리뷰 시작" },
        { command: "task",     description: "🔧 작업 파이프라인 시작" },
        { command: "feedback", description: "💬 진행 중 세션에 의견 등록" },
        { command: "status",   description: "📊 진행 중인 세션 확인" },
        { command: "list",     description: "📋 최근 세션 목록" },
        { command: "help",     description: "❓ 명령어 도움말" },
      ]
    });
    console.log("📱 텔레그램 슬래시 명령어 등록 완료");
  } catch(e) { console.error("BotFather commands error:", e.message); }
}

// Inline keyboards
const ROUNDS_KB = [[
  { text: "2라운드", callback_data: "rounds:2" },
  { text: "3라운드", callback_data: "rounds:3" },
  { text: "4라운드", callback_data: "rounds:4" },
  { text: "직접 입력", callback_data: "rounds:custom" },
]];

const AGENTS_KB = [
  [{ text: "1️⃣ 기본 3명 (시장/기술/비판)", callback_data: "agents:analyst,developer,critic" }],
  [{ text: "2️⃣ 전략팀 5명 (시장/기술/비판/디자인/전략)", callback_data: "agents:analyst,developer,critic,designer,strategist" }],
  [{ text: "3️⃣ 전체 6명 (전 전문가)", callback_data: "agents:analyst,developer,critic,designer,financial,strategist" }],
  [{ text: "4️⃣ 직접 입력...", callback_data: "agents:custom" }],
];

const AGENTCOUNT_KB = [[
  { text: "3명", callback_data: "agentcount:3" },
  { text: "5명", callback_data: "agentcount:5" },
  { text: "7명", callback_data: "agentcount:7" },
  { text: "직접 입력", callback_data: "agentcount:custom" },
]];

// Wizard: start debate flow
async function startDebateFlow(chatId, topicInline) {
  if (topicInline) {
    convState.set(chatId, { cmd: "debate", step: "rounds", params: { topic: topicInline } });
    await sendTelegram(chatId, `🏴‍☠️ *토론 주제:* ${topicInline}\n\n몇 라운드로 진행할까요?`, ROUNDS_KB);
  } else {
    convState.set(chatId, { cmd: "debate", step: "topic", params: {} });
    await sendTelegram(chatId, "🏴‍☠️ *Round Table 토론*\n\n토론 주제를 입력해 주세요.\n\n_예: PiPi Words 지금 당장 출시해야 할까?_");
  }
}

// Wizard: start review flow
async function startReviewFlow(chatId, goalInline) {
  if (goalInline) {
    convState.set(chatId, { cmd: "review", step: "rounds", params: { topic: goalInline } });
    await sendTelegram(chatId, `🔍 *코드 리뷰 목표:* ${goalInline}\n\n몇 라운드로 진행할까요?`, ROUNDS_KB);
  } else {
    convState.set(chatId, { cmd: "review", step: "goal", params: {} });
    await sendTelegram(chatId, "🔍 *코드 리뷰*\n\n리뷰 목표를 입력해 주세요.\n\n_예: 전반적 코드 품질 향상 및 릴리즈 준비_");
  }
}

// Wizard: start task flow
async function startTaskFlow(chatId, taskInline) {
  if (taskInline) {
    convState.set(chatId, { cmd: "task", step: "agentcount", params: { task: taskInline } });
    await sendTelegram(chatId, `🔧 *작업:* ${taskInline}\n\n에이전트 수를 선택해 주세요:`, AGENTCOUNT_KB);
  } else {
    convState.set(chatId, { cmd: "task", step: "task", params: {} });
    await sendTelegram(chatId, "🔧 *작업 파이프라인*\n\n수행할 작업을 입력해 주세요.\n\n_예: 레트로 게임 만들어줘_\n_예: 경쟁사 분석 보고서 작성_\n_예: REST API 설계 및 구현_");
  }
}

// Wizard: start feedback flow (show active session list)
async function startFeedbackFlow(chatId) {
  const debateSessions = listSessions().filter(s => ["running","completed"].includes(s.status)).slice(0, 4);
  const crSessions = listCodeReviewSessions().filter(s => ["running","completed"].includes(s.status)).slice(0, 4);
  if (!debateSessions.length && !crSessions.length) {
    await sendTelegram(chatId, "❌ 진행 중이거나 최근 완료된 세션이 없습니다.");
    return;
  }
  const kb = [];
  for (const s of debateSessions) {
    const label = `🏴 ${(s.topic||"").slice(0,35)} (${s.status === "running" ? "진행중" : "완료"})`;
    kb.push([{ text: label, callback_data: `fb_session:${s.id}` }]);
  }
  for (const s of crSessions) {
    const label = `🔍 ${(s.topic||"").slice(0,35)} (${s.status === "running" ? "진행중" : "완료"})`;
    kb.push([{ text: label, callback_data: `fb_session:${s.id}` }]);
  }
  convState.set(chatId, { cmd: "feedback", step: "session", params: {} });
  await sendTelegram(chatId, "💬 *의견 등록*\n\n어느 세션에 의견을 남길까요?", kb);
}

// Handle inline keyboard callbacks
async function handleCallbackQuery(chatId, data) {
  const state = convState.get(chatId);

  if (data.startsWith("rounds:")) {
    if (!state) return;
    const val = data.slice(7);
    if (val === "custom") {
      state.step = "rounds_custom";
      await sendTelegram(chatId, "라운드 수를 직접 입력해 주세요 (1~9):");
    } else {
      state.params.rounds = parseInt(val);
      if (state.cmd === "debate") {
        state.step = "agents";
        await sendTelegram(chatId, `✅ ${val}라운드\n\n에이전트를 선택해 주세요:`, AGENTS_KB);
      } else {
        state.step = "agentcount";
        await sendTelegram(chatId, `✅ ${val}라운드\n\n에이전트 수를 선택해 주세요:`, AGENTCOUNT_KB);
      }
    }
    return;
  }

  if (data.startsWith("agents:")) {
    if (!state) return;
    const val = data.slice(7);
    if (val === "custom") {
      state.step = "agents_custom";
      await sendTelegram(chatId, "에이전트를 쉼표로 구분해 입력해 주세요:\n\n_analyst, developer, critic, designer, financial, strategist_");
    } else {
      state.params.agents = val;
      await launchDebate(chatId, state.params);
    }
    return;
  }

  if (data.startsWith("agentcount:")) {
    if (!state) return;
    const val = data.slice(11);
    if (val === "custom") {
      state.step = "agentcount_custom";
      await sendTelegram(chatId, "에이전트 수를 입력해 주세요 (2~12):");
    } else {
      state.params.agentCount = parseInt(val);
      if (state.cmd === "task") {
        await launchTask(chatId, state.params);
      } else {
        await launchReview(chatId, state.params);
      }
    }
    return;
  }

  if (data.startsWith("fb_session:")) {
    if (!state) return;
    state.params.sessionId = data.slice(11);
    state.step = "text";
    await sendTelegram(chatId, `세션: \`${state.params.sessionId}\`\n\n의견을 입력해 주세요:\n\n_예: 보안 측면에서 더 깊이 분석해 주세요_`);
    return;
  }
}

// Handle text in active conversation state
async function handleConvText(chatId, text) {
  const state = convState.get(chatId);
  if (!state) return false;
  const { cmd, step, params } = state;

  if (cmd === "debate") {
    if (step === "topic") {
      params.topic = text;
      state.step = "rounds";
      await sendTelegram(chatId, `🏴‍☠️ 주제: *${text}*\n\n몇 라운드로 진행할까요?`, ROUNDS_KB);
      return true;
    }
    if (step === "rounds_custom") {
      const n = parseInt(text);
      if (isNaN(n) || n < 1 || n > 9) { await sendTelegram(chatId, "❌ 1~9 사이 숫자를 입력해 주세요."); return true; }
      params.rounds = n;
      state.step = "agents";
      await sendTelegram(chatId, `✅ ${n}라운드\n\n에이전트를 선택해 주세요:`, AGENTS_KB);
      return true;
    }
    if (step === "agents_custom") {
      params.agents = text.replace(/\s/g, "");
      await launchDebate(chatId, params);
      return true;
    }
  }

  if (cmd === "review") {
    if (step === "goal") {
      params.topic = text;
      state.step = "rounds";
      await sendTelegram(chatId, `🔍 목표: *${text}*\n\n몇 라운드로 진행할까요?`, ROUNDS_KB);
      return true;
    }
    if (step === "rounds_custom") {
      const n = parseInt(text);
      if (isNaN(n) || n < 1 || n > 9) { await sendTelegram(chatId, "❌ 1~9 사이 숫자를 입력해 주세요."); return true; }
      params.rounds = n;
      state.step = "agentcount";
      await sendTelegram(chatId, `✅ ${n}라운드\n\n에이전트 수를 선택해 주세요:`, AGENTCOUNT_KB);
      return true;
    }
    if (step === "agentcount_custom") {
      const n = parseInt(text);
      if (isNaN(n) || n < 2 || n > 12) { await sendTelegram(chatId, "❌ 2~12 사이 숫자를 입력해 주세요."); return true; }
      params.agentCount = n;
      await launchReview(chatId, params);
      return true;
    }
  }

  if (cmd === "task") {
    if (step === "task") {
      params.task = text;
      state.step = "agentcount";
      await sendTelegram(chatId, `🔧 작업: *${text}*\n\n에이전트 수를 선택해 주세요:`, AGENTCOUNT_KB);
      return true;
    }
    if (step === "agentcount_custom") {
      const n = parseInt(text);
      if (isNaN(n) || n < 2 || n > 12) { await sendTelegram(chatId, "❌ 2~12 사이 숫자를 입력해 주세요."); return true; }
      params.agentCount = n;
      await launchTask(chatId, params);
      return true;
    }
  }

  if (cmd === "feedback" && step === "text") {
    const sessionId = params.sessionId;
    const debateDir = join(SESSIONS_DIR, sessionId);
    const crDir = join(CR_SESSIONS_DIR, sessionId);
    const dir = existsSync(debateDir) ? debateDir : existsSync(crDir) ? crDir : null;
    convState.delete(chatId);
    if (dir) {
      saveFeedback(dir, text);
      await sendTelegram(chatId, `✅ 의견이 등록되었습니다. 다음 라운드에 반영됩니다.\n\n💬 _"${text}"_`);
    } else {
      await sendTelegram(chatId, `❌ 세션을 찾을 수 없습니다: \`${sessionId}\``);
    }
    return true;
  }

  return false;
}

// Launch debate and notify
async function launchDebate(chatId, params) {
  convState.delete(chatId);
  const { topic, rounds = 2, agents = "analyst,developer,critic", projectDir = null } = params;
  const result = startDebateWithId({ topic, rounds, agents, projectDir, telegramChatId: chatId });
  await sendTelegram(chatId,
    `🏴‍☠️ *토론 시작!*\n\n📌 주제: ${topic}\n⏱ 라운드: ${rounds}\n👥 에이전트: ${agents}\n🆔 \`${result.sessionId}\`\n\n완료되면 결과를 전달해 드립니다.`
  );
}

// Launch code review and notify
async function launchReview(chatId, params) {
  convState.delete(chatId);
  const { topic, rounds = 2, agentCount = 5, projectDir = null } = params;
  const result = startCodeReview({ topic, rounds, agentCount, projectDir });
  writeFileSync(join(CR_SESSIONS_DIR, result.sessionId, ".telegram"), chatId);
  await sendTelegram(chatId,
    `🔍 *코드 리뷰 시작!*\n\n📌 목표: ${topic}\n⏱ 라운드: ${rounds}\n👥 에이전트: ${agentCount}명\n🆔 \`${result.sessionId}\`\n\n에이전트 구성 완료 후 리뷰가 시작됩니다.`
  );
}

// Launch task pipeline and notify
async function launchTask(chatId, params) {
  convState.delete(chatId);
  const { task, agentCount = 5, projectDir = null } = params;
  const result = startTask({ task, agentCount, projectDir });
  writeFileSync(join(TASK_SESSIONS_DIR, result.sessionId, ".telegram"), String(chatId));
  await sendTelegram(chatId,
    `🔧 *작업 파이프라인 시작!*\n\n📌 작업: ${task}\n👥 에이전트: ${agentCount}명\n🆔 \`${result.sessionId}\`\n\n파이프라인 구성 후 실행됩니다. 완료 시 결과를 전달해 드립니다.`
  );
}

// Feedback helpers
function saveFeedback(sessionDir, text) {
  const file = join(sessionDir, "user-feedback.json");
  let data = { feedbacks: [] };
  if (existsSync(file)) {
    try { data = JSON.parse(readFileSync(file, "utf-8")); } catch {}
  }
  if (!data.feedbacks) data.feedbacks = [];
  data.feedbacks.push({ text, created_at: new Date().toISOString(), used: false });
  writeFileSync(file, JSON.stringify(data, null, 2));
  return data;
}

function getFeedback(sessionDir) {
  const file = join(sessionDir, "user-feedback.json");
  if (!existsSync(file)) return { feedbacks: [] };
  try { return JSON.parse(readFileSync(file, "utf-8")); } catch { return { feedbacks: [] }; }
}

function deleteFeedbackItem(sessionDir, idx) {
  const file = join(sessionDir, "user-feedback.json");
  if (!existsSync(file)) return false;
  try {
    const data = JSON.parse(readFileSync(file, "utf-8"));
    if (!data.feedbacks || idx < 0 || idx >= data.feedbacks.length) return false;
    if (data.feedbacks[idx].used) return false;
    data.feedbacks.splice(idx, 1);
    writeFileSync(file, JSON.stringify(data, null, 2));
    return true;
  } catch { return false; }
}

async function pollTelegram() {
  if (!TELEGRAM_TOKEN) return;
  try {
    const data = await telegramPost("getUpdates", { offset: telegramOffset, timeout: 0, limit: 10 });
    if (!data.ok || !data.result?.length) return;
    for (const update of data.result) {
      telegramOffset = Math.max(telegramOffset, update.update_id + 1);

      // Inline keyboard button press
      if (update.callback_query) {
        const cq = update.callback_query;
        const chatId = String(cq.message.chat.id);
        await telegramPost("answerCallbackQuery", { callback_query_id: cq.id });
        await handleCallbackQuery(chatId, cq.data);
        continue;
      }

      const msg = update.message;
      if (!msg?.text) continue;
      const chatId = String(msg.chat.id);
      const text = msg.text.trim();

      // If in conversation and not a new slash command, handle the next step
      if (convState.has(chatId) && !text.startsWith("/")) {
        await handleConvText(chatId, text);
        continue;
      }

      // New slash command resets any active conversation
      if (text.startsWith("/") && convState.has(chatId)) convState.delete(chatId);

      // Command dispatch
      if (text.startsWith("/debate")) {
        const inline = text.slice(7).trim();
        await startDebateFlow(chatId, inline || null);
      } else if (text.startsWith("/review")) {
        const inline = text.slice(7).trim();
        await startReviewFlow(chatId, inline || null);
      } else if (text.startsWith("/task")) {
        const inline = text.slice(5).trim();
        await startTaskFlow(chatId, inline || null);
      } else if (text.startsWith("/feedback")) {
        await startFeedbackFlow(chatId);
      } else if (text === "/status") {
        const running = listSessions().filter(s => s.status === "running").slice(0, 5);
        const crRunning = listCodeReviewSessions().filter(s => ["running","generating-agents"].includes(s.status)).slice(0, 5);
        const taskRunning = listTaskSessions().filter(s => ["running","generating-pipeline","rating"].includes(s.status)).slice(0, 5);
        let t = "📊 *진행 중인 세션*\n\n";
        if (running.length) t += "*토론:*\n" + running.map(s => `• ${(s.topic||"").slice(0,50)}`).join("\n") + "\n\n";
        if (crRunning.length) t += "*코드 리뷰:*\n" + crRunning.map(s => `• ${(s.topic||"").slice(0,50)}`).join("\n") + "\n\n";
        if (taskRunning.length) t += "*작업 파이프라인:*\n" + taskRunning.map(s => `• ${(s.task||"").slice(0,50)}`).join("\n");
        if (!running.length && !crRunning.length && !taskRunning.length) t = "진행 중인 세션이 없습니다.";
        await sendTelegram(chatId, t);
      } else if (text === "/list") {
        const recent = listSessions().slice(0, 3);
        const crRecent = listCodeReviewSessions().slice(0, 3);
        let t = "📋 *최근 세션*\n\n";
        if (recent.length) t += "*토론:*\n" + recent.map(s => `• ${(s.topic||"").slice(0,40)} — ${s.status}`).join("\n") + "\n\n";
        if (crRecent.length) t += "*코드 리뷰:*\n" + crRecent.map(s => `• ${(s.topic||"").slice(0,40)} — ${s.status}`).join("\n");
        await sendTelegram(chatId, t || "세션이 없습니다.");
      } else if (text === "/help") {
        await sendTelegram(chatId,
          `🏴‍☠️ *Round Table 명령어*\n\n` +
          `/debate — 🏴 전략 토론 시작\n` +
          `/review — 🔍 코드 리뷰 시작\n` +
          `/task — 🔧 작업 파이프라인 시작\n` +
          `/feedback — 💬 진행 중 세션에 의견 등록\n` +
          `/status — 📊 진행 중인 세션 확인\n` +
          `/list — 📋 최근 세션 목록\n` +
          `/help — ❓ 도움말\n\n` +
          `_💡 명령어만 보내면 단계별 안내를 통해 설정합니다_`
        );
      }
    }
  } catch(e) { console.error("Telegram poll error:", e.message); }
}

async function checkAndNotifySessions() {
  if (!TELEGRAM_TOKEN) return;
  for (const s of listSessions()) {
    if (s.status !== "completed") continue;
    const key = `debate-${s.id}`;
    if (notifiedSessions.has(key)) continue;
    const chatFile = join(SESSIONS_DIR, s.id, ".telegram");
    if (!existsSync(chatFile)) continue;
    notifiedSessions.add(key);
    const chatId = readFileSync(chatFile, "utf-8").trim();
    const conclusion = safeRead(join(SESSIONS_DIR, s.id, "conclusion.md")) || safeRead(join(SESSIONS_DIR, s.id, "final", "synthesis.md")) || "";
    const summary = conclusion.slice(0, 800) + (conclusion.length > 800 ? "\n\n_(전체 결론은 웹 UI에서 확인하세요)_" : "");
    await sendTelegram(chatId, `🏴‍☠️ *토론 완료!*\n\n토픽: ${(s.topic||"").slice(0,100)}\n\n${summary}`);
  }
  for (const s of listCodeReviewSessions()) {
    if (s.status !== "completed") continue;
    const key = `cr-${s.id}`;
    if (notifiedSessions.has(key)) continue;
    const chatFile = join(CR_SESSIONS_DIR, s.id, ".telegram");
    if (!existsSync(chatFile)) continue;
    notifiedSessions.add(key);
    const chatId = readFileSync(chatFile, "utf-8").trim();
    const conclusion = safeRead(join(CR_SESSIONS_DIR, s.id, "conclusion.md")) || "";
    const scoreInfo = s.quality_score ? `품질 점수: *${s.quality_score}/10*\n` : "";
    const summary = conclusion.slice(0, 600) + (conclusion.length > 600 ? "\n\n_(전체 보고서는 웹 UI에서 확인하세요)_" : "");
    await sendTelegram(chatId, `🔍 *코드 리뷰 완료!*\n\n${scoreInfo}목표: ${(s.topic||"").slice(0,100)}\n\n${summary}`);
  }
  // 태스크 파이프라인 완료 알림
  for (const s of listTaskSessions()) {
    if (s.status !== "completed") continue;
    const key = `task-${s.id}`;
    if (notifiedSessions.has(key)) continue;
    const chatFile = join(TASK_SESSIONS_DIR, s.id, ".telegram");
    if (!existsSync(chatFile)) continue;
    notifiedSessions.add(key);
    const chatId = readFileSync(chatFile, "utf-8").trim();
    const conclusion = safeRead(join(TASK_SESSIONS_DIR, s.id, "conclusion.md")) || "";
    const scoreInfo = s.quality_score ? `점수: *${s.quality_score}/10* | ` : "";
    const readyInfo = s.release_ready ? "✅ 릴리즈 가능" : "⚠️ 추가 작업 필요";
    const summary = conclusion.slice(0, 600) + (conclusion.length > 600 ? "\n\n_(전체 보고서는 웹 UI에서 확인하세요)_" : "");
    await sendTelegram(chatId, `🔧 *작업 완료!*\n\n${scoreInfo}${readyInfo}\n작업: ${(s.task||"").slice(0,100)}\n\n${summary}`);
  }
}

// ============================================================
// --- Task Pipeline API Handlers ---
// ============================================================

function listTaskSessions() {
  if (!existsSync(TASK_SESSIONS_DIR)) return [];
  return readdirSync(TASK_SESSIONS_DIR)
    .filter((d) => {
      try { return statSync(join(TASK_SESSIONS_DIR, d)).isDirectory(); } catch { return false; }
    })
    .sort().reverse()
    .map((d) => {
      const meta = safeJson(join(TASK_SESSIONS_DIR, d, "meta.json")) || {
        task: "Unknown", status: "unknown",
      };
      return { id: d, ...meta };
    });
}

function getTaskSession(id) {
  const dir = join(TASK_SESSIONS_DIR, id);
  if (!existsSync(dir)) return null;
  const meta = safeJson(join(dir, "meta.json")) || {};
  const pipeline = safeJson(join(dir, "pipeline.json")) || {};

  const files = {};
  const collectFiles = (d, prefix = "") => {
    if (!existsSync(d)) return;
    for (const f of readdirSync(d)) {
      const full = join(d, f);
      const rel = prefix ? `${prefix}/${f}` : f;
      if (statSync(full).isDirectory()) {
        collectFiles(full, rel);
      } else if (f.endsWith(".md") || f.endsWith(".json")) {
        files[rel] = safeRead(full) || "";
      }
    }
  };
  collectFiles(dir);
  return { id, ...meta, pipeline_detail: pipeline, files };
}

function getTaskLogs(sessionId) {
  if (!existsSync(LOGS_DIR)) return {};
  const prefix = `task-${sessionId}-`;
  const logs = {};
  for (const f of readdirSync(LOGS_DIR)) {
    if (f.startsWith(prefix) && f.endsWith(".log")) {
      const key = f.replace(prefix, "").replace(".log", "");
      const raw = safeRead(join(LOGS_DIR, f)) || "";
      logs[key] = raw.length > 5000 ? raw.slice(-5000) : raw;
    }
  }
  return logs;
}

function streamTaskLogs(res, sessionId) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
  });

  const sendLogs = () => {
    const logs = getTaskLogs(sessionId || "");
    res.write(`data: ${JSON.stringify(logs)}\n\n`);
  };
  const sendSession = () => {
    if (!sessionId) return;
    const session = getTaskSession(sessionId);
    if (session) res.write(`event: session\ndata: ${JSON.stringify(session)}\n\n`);
  };
  const sendSessions = () => {
    const sessions = listTaskSessions().slice(0, 5);
    res.write(`event: sessions\ndata: ${JSON.stringify(sessions)}\n\n`);
  };

  sendLogs();
  sendSessions();
  const logInterval = setInterval(sendLogs, 2000);
  const sessionInterval = setInterval(() => { sendSession(); sendSessions(); }, 3000);

  res.on("close", () => {
    clearInterval(logInterval);
    clearInterval(sessionInterval);
  });
}

function startTask({ task, context = "", agentCount = 5, projectDir }) {
  const dir = projectDir && existsSync(projectDir) ? projectDir : WORKSPACE_DIR;
  const n = Math.min(Math.max(parseInt(agentCount) || 5, 2), 12);

  const sessionId = makeSessionId();
  const sessionDir = join(TASK_SESSIONS_DIR, sessionId);
  mkdirSync(sessionDir, { recursive: true });

  const meta = {
    type: "task",
    task,
    context,
    agent_count: n,
    project_dir: dir,
    started_at: new Date().toISOString(),
    status: "generating-pipeline",
    current_phase: 0,
    total_phases: 3,
    quality_score: 0,
    release_ready: false,
    release_threshold: 7.5,
    output_type: "code",
    pipeline_summary: "",
    agents: [],
    max_correction_cycles: 2,
    correction_cycle: 0,
    correction_cycles_used: 0,
  };
  writeFileSync(join(sessionDir, "meta.json"), JSON.stringify(meta, null, 2));

  const script = join(BASE, "task-orchestrator.sh");
  const child = spawn("bash", [script, "generate", sessionId], {
    cwd: BASE, detached: true, stdio: "ignore", env: { ...process.env },
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId, agentCount: n };
}

function runTask(sessionId) {
  const sessionDir = join(TASK_SESSIONS_DIR, sessionId);
  if (!existsSync(sessionDir)) return null;
  const meta = safeJson(join(sessionDir, "meta.json")) || {};
  if (meta.status !== "pipeline-ready") return { error: `잘못된 상태: ${meta.status}` };

  const script = join(BASE, "task-orchestrator.sh");
  const child = spawn("bash", [script, "run", sessionId], {
    cwd: BASE, detached: true, stdio: "ignore", env: { ...process.env },
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId };
}

function continueTask({ sessionId, cycles = 1 }) {
  const sessionDir = join(TASK_SESSIONS_DIR, sessionId);
  if (!existsSync(sessionDir)) return null;
  const c = Math.min(Math.max(parseInt(cycles) || 1, 1), 5);
  const script = join(BASE, "task-orchestrator.sh");
  const child = spawn("bash", [script, "--continue", sessionId, String(c)], {
    cwd: BASE, detached: true, stdio: "ignore", env: { ...process.env },
  });
  child.unref();
  return { started: true, pid: child.pid, sessionId, additionalCycles: c };
}

async function startTelegramPolling() {
  if (!TELEGRAM_TOKEN) { console.log("ℹ️  텔레그램 통합 비활성화 (TELEGRAM_BOT_TOKEN 미설정)"); return; }
  console.log("📱 텔레그램 폴링 시작...");
  await registerBotCommands();
  setInterval(pollTelegram, 3000);
  setInterval(checkAndNotifySessions, 5000);
}

// --- HTTP Server ---

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const path = url.pathname;

  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

  const json = (data, status = 200) => {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data));
  };

  // Task Pipeline API
  if (path === "/api/task/sessions") return json(listTaskSessions());

  if (path.startsWith("/api/task/session/") && req.method === "GET" && !path.includes("/feedback")) {
    const id = path.split("/")[4];
    const session = getTaskSession(id);
    return session ? json(session) : json({ error: "Not found" }, 404);
  }

  if (path === "/api/task/logs") {
    const sid = url.searchParams.get("sessionId") || "";
    return json(getTaskLogs(sid));
  }

  if (path === "/api/task/logs/stream") {
    const sid = url.searchParams.get("sessionId") || "";
    return streamTaskLogs(res, sid);
  }

  if (path === "/api/task/start" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const params = JSON.parse(body);
        if (!params.task?.trim()) return json({ error: "task is required" }, 400);
        return json(startTask(params));
      } catch (e) { return json({ error: e.message }, 400); }
    });
    return;
  }

  if (path === "/api/task/run" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const { sessionId } = JSON.parse(body);
        if (!sessionId) return json({ error: "sessionId is required" }, 400);
        const result = runTask(sessionId);
        return result ? json(result) : json({ error: "Session not found or invalid status" }, 400);
      } catch (e) { return json({ error: e.message }, 400); }
    });
    return;
  }

  if (path === "/api/task/continue" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const { sessionId, cycles = 1 } = JSON.parse(body);
        if (!sessionId) return json({ error: "sessionId is required" }, 400);
        const result = continueTask({ sessionId, cycles });
        return result ? json(result) : json({ error: "Session not found" }, 404);
      } catch (e) { return json({ error: e.message }, 400); }
    });
    return;
  }

  if (path.startsWith("/api/task/session/") && req.method === "DELETE") {
    const id = path.split("/")[4];
    if (!id || !/^\d{8}_\d{6}$/.test(id)) return json({ error: "Invalid session id" }, 400);
    const dir = join(TASK_SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    try {
      rmSync(dir, { recursive: true, force: true });
      const logPrefix = `task-${id}-`;
      if (existsSync(LOGS_DIR)) {
        for (const f of readdirSync(LOGS_DIR)) {
          if (f.startsWith(logPrefix) && f.endsWith(".log")) rmSync(join(LOGS_DIR, f), { force: true });
        }
      }
      return json({ deleted: true, id });
    } catch (e) { return json({ error: e.message }, 500); }
  }

  if (path.match(/^\/api\/task\/session\/[^/]+\/feedback$/) && req.method === "GET") {
    const id = path.split("/")[4];
    const dir = join(TASK_SESSIONS_DIR, id);
    return existsSync(dir) ? json(getFeedback(dir)) : json({ error: "Not found" }, 404);
  }
  if (path.match(/^\/api\/task\/session\/[^/]+\/feedback$/) && req.method === "POST") {
    const id = path.split("/")[4];
    const dir = join(TASK_SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    let body = "";
    req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { text } = JSON.parse(body);
        if (!text?.trim()) return json({ error: "text is required" }, 400);
        return json(saveFeedback(dir, text.trim()));
      } catch(e) { return json({ error: e.message }, 400); }
    });
    return;
  }

  if (path === "/api/agents") return json(listAgents());
  if (path === "/api/projects") return json(listProjects());
  if (path === "/api/sessions") return json(listSessions());

  // Code Review API
  if (path === "/api/code-review/sessions") return json(listCodeReviewSessions());

  if (path.startsWith("/api/code-review/session/") && req.method === "GET") {
    const id = path.split("/")[4];
    const session = getCodeReviewSession(id);
    return session ? json(session) : json({ error: "Not found" }, 404);
  }

  if (path === "/api/code-review/logs") {
    const sid = url.searchParams.get("sessionId") || "";
    return json(getCodeReviewLogs(sid));
  }

  if (path === "/api/code-review/logs/stream") {
    const sid = url.searchParams.get("sessionId") || "";
    return streamCodeReviewLogs(res, sid);
  }

  if (path === "/api/code-review/start" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const params = JSON.parse(body);
        if (!params.topic?.trim()) return json({ error: "topic is required" }, 400);
        return json(startCodeReview(params));
      } catch (e) {
        return json({ error: e.message }, 400);
      }
    });
    return;
  }

  if (path === "/api/code-review/run" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const { sessionId, aiProfile } = JSON.parse(body);
        if (!sessionId) return json({ error: "sessionId is required" }, 400);
        const result = runCodeReview(sessionId, aiProfile);
        return result ? json(result) : json({ error: "Session not found or invalid status" }, 400);
      } catch (e) {
        return json({ error: e.message }, 400);
      }
    });
    return;
  }

  if (path.startsWith("/api/code-review/session/") && req.method === "DELETE") {
    const id = path.split("/")[4];
    if (!id || !/^\d{8}_\d{6}$/.test(id)) return json({ error: "Invalid session id" }, 400);
    const dir = join(CR_SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    try {
      // 세션 디렉토리 삭제
      rmSync(dir, { recursive: true, force: true });
      // 관련 로그 파일 삭제 (logs/cr-{id}-*.log)
      const logPrefix = `cr-${id}-`;
      if (existsSync(LOGS_DIR)) {
        for (const f of readdirSync(LOGS_DIR)) {
          if (f.startsWith(logPrefix) && f.endsWith(".log")) {
            rmSync(join(LOGS_DIR, f), { force: true });
          }
        }
      }
      return json({ deleted: true, id });
    } catch (e) {
      return json({ error: e.message }, 500);
    }
  }

  if (path === "/api/code-review/continue" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        const { sessionId, rounds = 1 } = JSON.parse(body);
        if (!sessionId) return json({ error: "sessionId is required" }, 400);
        const result = continueCodeReview({ sessionId, rounds });
        return result ? json(result) : json({ error: "Session not found" }, 404);
      } catch (e) {
        return json({ error: e.message }, 400);
      }
    });
    return;
  }

  // Debate feedback API
  if (path.match(/^\/api\/session\/[^/]+\/feedback$/) && req.method === "GET") {
    const id = path.split("/")[3];
    const dir = join(SESSIONS_DIR, id);
    return existsSync(dir) ? json(getFeedback(dir)) : json({ error: "Not found" }, 404);
  }
  if (path.match(/^\/api\/session\/[^/]+\/feedback$/) && req.method === "POST") {
    const id = path.split("/")[3];
    const dir = join(SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    let body = "";
    req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { text } = JSON.parse(body);
        if (!text?.trim()) return json({ error: "text is required" }, 400);
        return json(saveFeedback(dir, text.trim()));
      } catch(e) { return json({ error: e.message }, 400); }
    });
    return;
  }
  if (path.match(/^\/api\/session\/[^/]+\/feedback\/\d+$/) && req.method === "DELETE") {
    const parts = path.split("/");
    const id = parts[3]; const idx = parseInt(parts[5]);
    const dir = join(SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    return deleteFeedbackItem(dir, idx) ? json({ deleted: true }) : json({ error: "Cannot delete" }, 400);
  }

  // Code review feedback API
  if (path.match(/^\/api\/code-review\/session\/[^/]+\/feedback$/) && req.method === "GET") {
    const id = path.split("/")[4];
    const dir = join(CR_SESSIONS_DIR, id);
    return existsSync(dir) ? json(getFeedback(dir)) : json({ error: "Not found" }, 404);
  }
  if (path.match(/^\/api\/code-review\/session\/[^/]+\/feedback$/) && req.method === "POST") {
    const id = path.split("/")[4];
    const dir = join(CR_SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    let body = "";
    req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { text } = JSON.parse(body);
        if (!text?.trim()) return json({ error: "text is required" }, 400);
        return json(saveFeedback(dir, text.trim()));
      } catch(e) { return json({ error: e.message }, 400); }
    });
    return;
  }
  if (path.match(/^\/api\/code-review\/session\/[^/]+\/feedback\/\d+$/) && req.method === "DELETE") {
    const parts = path.split("/");
    const id = parts[4]; const idx = parseInt(parts[6]);
    const dir = join(CR_SESSIONS_DIR, id);
    if (!existsSync(dir)) return json({ error: "Not found" }, 404);
    return deleteFeedbackItem(dir, idx) ? json({ deleted: true }) : json({ error: "Cannot delete" }, 400);
  }

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
  const filePath = path === "/" ? "/index.html"
    : path === "/code-review" ? "/code-review.html"
    : path === "/task" ? "/task.html"
    : path;
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

startTelegramPolling();

server.listen(PORT, () => {
  console.log(`🏴‍☠️ Round Table UI: http://localhost:${PORT}`);
});
