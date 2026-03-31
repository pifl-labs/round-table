#!/bin/bash
# Code Review Orchestrator — 2단계 실행
#
# 모드:
#   generate SESSION_ID   — 프로젝트 분석 + 에이전트 생성 (서버가 meta.json 사전 생성)
#   run      SESSION_ID   — 리뷰 라운드 실행 (agents-ready 상태에서 호출)
#   --continue SESSION_ID [N] — 완료된 세션에 라운드 추가
#
# 흐름:
#   서버: meta.json 생성 → generate → [UI: 에이전트 확인] → run → 완료

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
CR_SESSIONS_BASE="${SCRIPT_DIR}/sessions/code-review"
JSON_EXTRACTOR="${SCRIPT_DIR}/.extract_json.py"

# ============================================================
# 모드 파싱
# ============================================================
MODE="${1:-}"

case "$MODE" in
  generate)
    SESSION_ID="${2:?Usage: $0 generate SESSION_ID}"
    ;;
  run)
    SESSION_ID="${2:?Usage: $0 run SESSION_ID}"
    ;;
  --continue)
    SESSION_ID="${2:?Usage: $0 --continue SESSION_ID [add_rounds]}"
    ADD_ROUNDS="${3:-1}"
    ;;
  *)
    echo "Usage: $0 <generate|run|--continue> SESSION_ID [N]" >&2
    exit 1
    ;;
esac

SESSION_DIR="${CR_SESSIONS_BASE}/${SESSION_ID}"
if [ ! -d "$SESSION_DIR" ]; then
  echo "❌ 세션 디렉토리 없음: $SESSION_DIR" >&2; exit 1
fi
if [ ! -f "$SESSION_DIR/meta.json" ]; then
  echo "❌ meta.json 없음: $SESSION_DIR/meta.json" >&2; exit 1
fi

# ============================================================
# meta.json에서 공통 파라미터 로드
# ============================================================
py_get() { python3 -c "import json; d=json.load(open('$SESSION_DIR/meta.json')); print(d.get('$1','$2'))" 2>/dev/null || echo "$2"; }

TOPIC=$(py_get topic "")
CONTEXT=$(py_get context "")
PROJECT_DIR=$(py_get project_dir "$(pwd)")
CODE_DIR=$(py_get code_dir "$PROJECT_DIR")  # 실제 코드 위치 (project_dir과 다를 수 있음)
AGENT_COUNT=$(py_get agent_count "5")
TOTAL_ROUNDS=$(py_get rounds "2")

# ============================================================
# 디렉토리 & 환경
# ============================================================
mkdir -p "$LOG_DIR"
# 7일 이상 된 로그 자동 삭제
find "$LOG_DIR" -name "cr-*.log" -mtime +7 -delete 2>/dev/null || true

SCRIPT_ENV="${SCRIPT_DIR}/.env"
if [ -f "$SCRIPT_ENV" ]; then
  set +u; set -a
  # shellcheck disable=SC1090
  source "$SCRIPT_ENV"
  set +a; set -u
fi

CLAUDE_BIN="${CLAUDE_BIN:-$(which claude 2>/dev/null || true)}"
for candidate in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
  [ -x "$candidate" ] && { CLAUDE_BIN="$candidate"; break; }
done
[ -x "${CLAUDE_BIN:-}" ] || { echo "❌ claude CLI를 찾을 수 없습니다." >&2; exit 1; }

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(grep "CLAUDE_CODE_OAUTH_TOKEN" ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null \
    | tail -1 | sed "s/.*CLAUDE_CODE_OAUTH_TOKEN=//;s/['\"]//g;s/export //g" | xargs 2>/dev/null || true)
fi
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && { echo "❌ CLAUDE_CODE_OAUTH_TOKEN 미설정" >&2; exit 1; }

# Codex CLI 탐지 (선택 — codex-cli 프로파일 사용 시 필요)
CODEX_BIN="${CODEX_BIN:-$(which codex 2>/dev/null || true)}"
for candidate in "/opt/homebrew/bin/codex" "$HOME/.local/bin/codex" "/usr/local/bin/codex"; do
  [ -x "$candidate" ] && { CODEX_BIN="$candidate"; break; }
done

# Gemini CLI 탐지 (선택 — gemini-cli 프로파일 사용 시 필요)
GEMINI_BIN="${GEMINI_BIN:-$(which gemini 2>/dev/null || true)}"
for candidate in "/opt/homebrew/bin/gemini" "$HOME/.local/bin/gemini" "/usr/local/bin/gemini"; do
  [ -x "$candidate" ] && { GEMINI_BIN="$candidate"; break; }
done

# ============================================================
# 멀티 AI 프로바이더 설정
# ============================================================
AI_PROFILE="${AI_PROFILE:-claude}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
# 세션 meta.json에 ai_profile이 있으면 우선 적용
_META_AI_PROFILE=$(python3 -c "
import json
try:
  d = json.load(open('$SESSION_DIR/meta.json'))
  print(d.get('ai_profile',''))
except: print('')
" 2>/dev/null)
[ -n "$_META_AI_PROFILE" ] && AI_PROFILE="$_META_AI_PROFILE"

# ============================================================
# 멀티 AI 래퍼 함수들
# ============================================================

# call_openai PROMPT LOG_FILE MODEL
call_openai() {
  local prompt="$1" log="$2" model="${3:-gpt-4o-mini}"
  if [ -z "$OPENAI_API_KEY" ]; then
    echo "(OpenAI API 키 없음 — .env에 OPENAI_API_KEY 추가 필요)" >> "$log"
    echo ""
    return 1
  fi
  local payload; payload=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({'model': '$model', 'messages': [{'role': 'user', 'content': prompt}], 'max_tokens': 4096}))" <<< "$prompt")
  local response; response=$(curl -sf "https://api.openai.com/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d "$payload" 2>>"$log")
  if [ -z "$response" ]; then
    echo "(OpenAI API 호출 실패)" >> "$log"
    echo ""; return 1
  fi
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" <<< "$response" 2>>"$log"
}

# call_gemini PROMPT LOG_FILE MODEL
call_gemini() {
  local prompt="$1" log="$2" model="${3:-gemini-2.0-flash}"
  if [ -z "$GEMINI_API_KEY" ]; then
    echo "(Gemini API 키 없음 — aistudio.google.com에서 무료 발급 후 .env에 GEMINI_API_KEY 추가)" >> "$log"
    echo ""
    return 1
  fi
  local payload; payload=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({'contents': [{'parts': [{'text': prompt}]}], 'generationConfig': {'maxOutputTokens': 4096}}))" <<< "$prompt")
  local response; response=$(curl -sf \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>>"$log")
  if [ -z "$response" ]; then
    echo "(Gemini API 호출 실패)" >> "$log"
    echo ""; return 1
  fi
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['candidates'][0]['content']['parts'][0]['text'])" <<< "$response" 2>>"$log"
}

# call_gemini_cli PROMPT LOG_FILE [DIR]
# Gemini CLI — Google OAuth 인증 (~/.gemini/oauth_creds.json), API 키 불필요
# 파일 직접 읽기 가능 (REST API와 달리 collect_code_context 불필요)
call_gemini_cli() {
  local prompt="$1" log="$2" dir="${3:-$PROJECT_DIR}"
  if [ -z "${GEMINI_BIN:-}" ] || [ ! -x "${GEMINI_BIN}" ]; then
    echo "(Gemini CLI 없음 — /opt/homebrew/bin/gemini 경로 확인)" >> "$log"
    return 1
  fi
  local tmp; tmp=$(mktemp)
  # -p: 비대화형 단일 응답 모드 (claude -p 와 동일 역할)
  # OAuth 자격증명은 ~/.gemini/oauth_creds.json 에서 자동 로드됨
  if (cd "$dir" && "$GEMINI_BIN" -p "$prompt") > "$tmp" 2>> "$log"; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  else
    echo "(Gemini CLI 호출 실패)" >> "$log"
    rm -f "$tmp"
    return 1
  fi
}

# call_codex_cli PROMPT LOG_FILE [DIR]
# Codex CLI — ChatGPT 계정 OAuth 인증 (~/.codex/auth.json), API 키 불필요
# 파일 직접 읽기 가능 (collect_code_context 불필요)
call_codex_cli() {
  local prompt="$1" log="$2" dir="${3:-$PROJECT_DIR}"
  if [ -z "${CODEX_BIN:-}" ] || [ ! -x "${CODEX_BIN}" ]; then
    echo "(Codex CLI 없음 — /opt/homebrew/bin/codex 경로 확인)" >> "$log"
    return 1
  fi
  local tmp; tmp=$(mktemp)
  # 프롬프트를 stdin으로 전달 (ARG_MAX 한계 우회 + 긴 프롬프트 안전 처리)
  # --skip-git-repo-check: git repo 아닌 디렉토리에서도 실행
  # --sandbox read-only: 파일 읽기만 허용
  # --output-last-message: 최종 응답을 파일로 저장
  # -C: 프로젝트 작업 디렉토리
  if printf '%s' "$prompt" | "$CODEX_BIN" exec --full-auto --sandbox read-only \
      --skip-git-repo-check \
      -C "$dir" \
      --output-last-message "$tmp" \
      >> "$log" 2>&1; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  else
    local exit_code=$?
    echo "(Codex CLI 호출 실패 — exit=$exit_code)" >> "$log"
    rm -f "$tmp"
    return 1
  fi
}

# collect_code_context: 비-Claude 에이전트에게 줄 코드 컨텍스트 수집
# 결과를 $SESSION_DIR/code-context.md 에 캐싱
collect_code_context() {
  local ctx_file="$SESSION_DIR/code-context.md"
  [ -f "$ctx_file" ] && { cat "$ctx_file"; return; }

  local ctx="# 프로젝트 코드 컨텍스트\n프로젝트: $PROJECT_DIR\n\n"
  # 의존성 파일 우선
  for dep in pubspec.yaml package.json go.mod pyproject.toml Cargo.toml requirements.txt; do
    [ -f "$PROJECT_DIR/$dep" ] && ctx+="=== $dep ===\n$(cat "$PROJECT_DIR/$dep" 2>/dev/null | head -100)\n\n"
  done
  # README
  for readme in README.md README.txt readme.md; do
    [ -f "$PROJECT_DIR/$readme" ] && ctx+="=== $readme ===\n$(head -80 "$PROJECT_DIR/$readme" 2>/dev/null)\n\n" && break
  done
  # 주요 소스 파일 (각 최대 200줄, 전체 20파일 이내)
  local file_count=0
  while IFS= read -r f; do
    [ "$file_count" -ge 20 ] && break
    local size; size=$(wc -c < "$f" 2>/dev/null || echo 99999)
    [ "$size" -gt 30000 ] && continue  # 30KB 이상 스킵
    ctx+="=== ${f#$PROJECT_DIR/} ===\n$(head -200 "$f" 2>/dev/null)\n\n"
    file_count=$((file_count + 1))
  done < <(find "$PROJECT_DIR" -type f \( -name "*.dart" -o -name "*.kt" -o -name "*.swift" -o -name "*.ts" -o -name "*.tsx" -o -name "*.py" -o -name "*.go" \) \
    ! -path "*/build/*" ! -path "*/.dart_tool/*" ! -path "*/node_modules/*" ! -path "*/.pub-cache/*" \
    | sort | head -30)

  printf '%b' "$ctx" > "$ctx_file"
  cat "$ctx_file"
}

# resolve_agent_provider: 에이전트 ID에 대한 AI 프로바이더 결정
# 출력: "claude" | "gemini" | "gemini-cli" | "gpt4o-mini" | "gpt4o" | "codex-cli"
resolve_agent_provider() {
  local agent_id="$1"
  # 에이전트 수준 오버라이드가 있으면 사용
  local override; override=$(python3 -c "
import json
try:
  d = json.load(open('$SESSION_DIR/agents.json'))
  for a in d.get('agents', []):
    if a['id'] == '$agent_id':
      print(a.get('provider', ''))
      break
except: print('')
" 2>/dev/null)
  [ -n "$override" ] && { echo "$override"; return; }

  # 첫 에이전트 ID 조회 (프로파일별 Claude 유지 대상)
  local first_agent; first_agent=$(python3 -c "
import json
try:
  d = json.load(open('$SESSION_DIR/agents.json'))
  agents = d.get('agents', [])
  print(agents[0]['id'] if agents else '')
except: print('')
" 2>/dev/null)

  # 프로파일별 기본 배정
  case "$AI_PROFILE" in
    "mixed")
      # 첫 에이전트는 Claude (코드 탐색용), 나머지는 Gemini REST API
      [ "$agent_id" = "$first_agent" ] && echo "claude" || echo "gemini"
      ;;
    "gemini-primary")
      [ "$agent_id" = "$first_agent" ] && echo "claude" || echo "gemini"
      ;;
    "gemini-cli")
      # 첫 에이전트는 Claude, 나머지는 Gemini CLI (파일 직접 읽기)
      [ "$agent_id" = "$first_agent" ] && echo "claude" || echo "gemini-cli"
      ;;
    "codex-cli")
      # 첫 에이전트는 Claude, 나머지는 Codex CLI (파일 직접 읽기)
      [ "$agent_id" = "$first_agent" ] && echo "claude" || echo "codex-cli"
      ;;
    *)  # "claude" 기본값
      echo "claude"
      ;;
  esac
}

# ============================================================
# 유틸리티
# ============================================================
LOG_PREFIX="cr-${SESSION_ID}"

log_progress() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_DIR/${LOG_PREFIX}-main.log"; }

update_meta() {
  python3 - << PYEOF
import json
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
$1
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF
}

extract_json() { python3 "$JSON_EXTRACTOR"; }

get_agent_ids() {
  python3 -c "
import json
try:
    with open('$SESSION_DIR/agents.json') as f: d = json.load(f)
    print(' '.join(a['id'] for a in d.get('agents', [])))
except: print('')
" 2>/dev/null
}

get_agent_field() {
  local agent_id="$1" field="$2"
  python3 -c "
import json
try:
    with open('$SESSION_DIR/agents.json') as f: d = json.load(f)
    for a in d.get('agents', []):
        if a['id'] == '$agent_id':
            v = a.get('$field', '')
            print(', '.join(v) if isinstance(v, list) else str(v))
            break
except: print('')
" 2>/dev/null
}

get_language() {
  python3 -c "
import json
try:
    with open('$SESSION_DIR/agents.json') as f: d = json.load(f)
    print(d.get('language', 'Unknown'))
except: print('Unknown')
" 2>/dev/null
}

update_agent_status() {
  local agent_id="$1" status="$2"
  python3 -c "
import json
try:
    with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
    for a in d.get('agents', []):
        if a['id'] == '$agent_id': a['status'] = '$status'
    with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
except: pass
" 2>/dev/null
}

run_cr_agent() {
  local id="$1" round="$2" prompt="$3"
  local output="$SESSION_DIR/round-${round}/${id}.md"
  local log="$LOG_DIR/${LOG_PREFIX}-${id}.log"
  local provider; provider=$(resolve_agent_provider "$id")

  echo "[$(date +%H:%M:%S)] [R${round}] ${id} 시작 (${provider})..." >> "$log"
  update_agent_status "$id" "running"

  local result="" ok=false

  case "$provider" in
    "claude")
      local tmp; tmp=$(mktemp)
      # stream-json: tool call·파일 읽기·생각 과정을 로그에 스트리밍
      # tee로 log에 실시간 기록하면서 result만 추출
      if (cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
          "$CLAUDE_BIN" --output-format stream-json --verbose -p "$prompt") \
          2>> "$log" | tee -a "$log" > "$tmp"; then
        result=$(python3 -c "
import json, sys
data = sys.stdin.read().strip()
# 1순위: type=result 라인에서 result 필드 추출
for line in reversed(data.split('\n')):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'result' and 'result' in obj:
            print(obj['result']); exit(0)
    except: pass
# 2순위: assistant 메시지의 text 블록 추출 (JSON 원본 저장 방지)
texts = []
for line in data.split('\n'):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'assistant':
            for block in obj.get('message', {}).get('content', []):
                if block.get('type') == 'text' and block.get('text','').strip():
                    texts.append(block['text'])
    except: pass
if texts:
    print('\n'.join(texts)); exit(0)
# 3순위: 텍스트 라인만 (JSON 라인 제외)
plain = [l for l in data.split('\n') if l.strip() and not l.strip().startswith('{')]
if plain:
    print('\n'.join(plain[:200])); exit(0)
print('(결과 없음)')
" < "$tmp")
        ok=true
      fi
      rm -f "$tmp"
      ;;

    "gemini" | "gemini-flash" | "gemini-pro")
      local model="gemini-2.0-flash"
      [ "$provider" = "gemini-pro" ] && model="gemini-1.5-pro"
      # 코드 컨텍스트 주입 (비-Claude는 파일 읽기 불가)
      local ctx; ctx=$(collect_code_context)
      local full_prompt="아래는 분석할 코드베이스입니다. 한국어로 응답하세요.

${ctx}

---
## 리뷰 지시사항
${prompt}"
      result=$(call_gemini "$full_prompt" "$log" "$model")
      [ -n "$result" ] && ok=true
      ;;

    "gpt4o-mini" | "gpt4o" | "openai")
      local model="gpt-4o-mini"
      [ "$provider" = "gpt4o" ] && model="gpt-4o"
      local ctx; ctx=$(collect_code_context)
      local full_prompt="아래는 분석할 코드베이스입니다. 한국어로 응답하세요.

${ctx}

---
## 리뷰 지시사항
${prompt}"
      result=$(call_openai "$full_prompt" "$log" "$model")
      [ -n "$result" ] && ok=true
      ;;

    "gemini-cli")
      # Gemini CLI — 프로젝트 디렉토리에서 직접 파일 읽기 가능
      result=$(call_gemini_cli "$prompt" "$log" "$PROJECT_DIR")
      [ -n "$result" ] && ok=true
      ;;

    "codex-cli")
      # Codex CLI — 프로젝트 디렉토리에서 직접 파일 읽기 가능
      result=$(call_codex_cli "$prompt" "$log" "$PROJECT_DIR")
      [ -n "$result" ] && ok=true
      ;;

    *)
      echo "[$(date +%H:%M:%S)] [R${round}] ${id} 알 수 없는 프로바이더: ${provider}" >> "$log"
      ;;
  esac

  if [ "$ok" = true ] && [ -n "$result" ]; then
    echo "$result" > "$output"
    # provider 태그 추가 (UI에서 표시용)
    echo "" >> "$output"
    echo "---" >> "$output"
    echo "*분석 엔진: ${provider}*" >> "$output"
    update_agent_status "$id" "done"
    echo "[$(date +%H:%M:%S)] [R${round}] ${id} 완료 ✓" >> "$log"
  else
    update_agent_status "$id" "error"
    echo "[$(date +%H:%M:%S)] [R${round}] ${id} 실패" >> "$log"
    echo "*(에이전트 분석 실패 — provider: ${provider})*" > "$output"
  fi
}

# ============================================================
# ============================================================
# MODE: generate — 에이전트 생성 (status: generating-agents → agents-ready)
# ============================================================
# ============================================================
if [ "$MODE" = "generate" ]; then
  log_progress "🔍 [generate] 에이전트 생성 시작"
  log_progress "   목표: $TOPIC"
  log_progress "   프로젝트: $PROJECT_DIR"
  log_progress "   에이전트 수: $AGENT_COUNT"

  CONTEXT_LINE=""
  [ -n "$CONTEXT" ] && CONTEXT_LINE="추가 컨텍스트: ${CONTEXT}"

  AGENT_GEN_PROMPT=$(cat <<PROMPT_EOF
당신은 소프트웨어 아키텍처 전문가입니다. 한국어로 응답하세요.

다음 프로젝트를 실제 분석하고 코드 리뷰에 최적화된 ${AGENT_COUNT}명의 전문 에이전트를 생성하세요.

프로젝트 경로: ${PROJECT_DIR}
리뷰 목표: ${TOPIC}
${CONTEXT_LINE}

필수 작업:
1. Read/Glob/Grep으로 프로젝트를 실제 탐색하세요
   - 의존성 파일 (pubspec.yaml / package.json / go.mod / pyproject.toml / Cargo.toml)
   - 주요 소스 파일 구조 (lib/, src/, main 등)
   - README, 아키텍처 문서
2. 언어, 프레임워크, 아키텍처 패턴 파악
3. 코드에서 눈에 띄는 이슈 또는 개선 가능성 1차 파악
4. 이 프로젝트 특성에 맞는 ${AGENT_COUNT}명 전문가 역할 결정

각 에이전트는:
- 명확한 전문 도메인을 가져야 함
- 다른 에이전트와 관점이 달라야 함 (중복 역할 금지)
- 프로젝트 언어/프레임워크에 특화되어야 함

페르소나 작성 원칙 (중요):
- 목표는 '문제 찾기'가 아닌 '코드 품질 8점 이상으로 향상'입니다
- 페르소나는 건설적이고 실용적이어야 합니다 — 문제를 발견했으면 반드시 구체적 해결책을 제시하는 사람
- '엄격한', '집착하는' 같은 표현 대신 '실용적인', '해결 지향적인' 같은 표현 사용
- 코드의 좋은 점도 인정하고, 개선 가능한 부분에 집중하는 균형 잡힌 전문가로 설정

반드시 다음 JSON 형식으로 응답하세요 (마크다운 코드블록 사용 가능):
{
  "language": "Flutter/Dart",
  "framework": "Flutter 3.x + Riverpod",
  "detected_issues": ["상태관리 불일치", "테스트 부재"],
  "agents": [
    {
      "id": "arch_reviewer",
      "name": "아키텍처 전문가",
      "role": "클린 아키텍처 및 SOLID 원칙 검토",
      "expertise": ["Clean Architecture", "SOLID 원칙", "레이어 분리", "DI"],
      "focus": "도메인/프레젠테이션 레이어 분리, 의존성 방향, 관심사 분리",
      "persona": "10년 경력의 Flutter 아키텍처 전문가. 문제를 발견하면 반드시 구체적 리팩터링 방안을 함께 제시하며, 코드를 출시 가능한 수준으로 끌어올리는 것을 목표로 삼는 실용적 엔지니어"
    }
  ]
}
PROMPT_EOF
)

  AGENT_RAW=$(cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$AGENT_GEN_PROMPT" 2>>"$LOG_DIR/${LOG_PREFIX}-generator.log")

  AGENTS_JSON=$(echo "$AGENT_RAW" | extract_json)

  AGENTS_VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print('ok' if len(d.get('agents', [])) >= 2 else 'fail')
except: print('fail')
" <<< "$AGENTS_JSON" 2>/dev/null || echo "fail")

  if [ "$AGENTS_VALID" != "ok" ]; then
    log_progress "⚠️ 에이전트 JSON 파싱 실패 — 기본 에이전트로 폴백"
    AGENTS_JSON='{
  "language": "Unknown",
  "framework": "Unknown",
  "detected_issues": ["구조 분석 필요"],
  "agents": [
    {"id":"code_quality","name":"코드 품질 전문가","role":"전반적 코드 품질","expertise":["가독성","유지보수성","SOLID"],"focus":"코드 구조, 중복, 네이밍","persona":"10년 경력의 시니어 개발자. 문제를 발견하면 반드시 구체적 개선 코드를 함께 제시하며, 코드를 출시 가능한 수준으로 끌어올리는 것을 목표로 삼는 실용적 엔지니어"},
    {"id":"security","name":"보안 전문가","role":"보안 취약점","expertise":["인증","인가","입력 검증"],"focus":"취약점, 데이터 노출","persona":"보안 감사 경험이 많은 실용적 엔지니어. 취약점을 발견하면 즉시 수정 가능한 패치 코드를 제시하며, 보안 강화를 통해 코드 품질 향상을 이끄는 전문가"},
    {"id":"performance","name":"성능 전문가","role":"성능 최적화","expertise":["메모리","CPU","네트워크"],"focus":"병목, 비효율 패턴","persona":"프로파일링과 최적화 경험이 풍부한 엔지니어. 성능 개선 기회를 발견하면 수치 기반 근거와 구체적 최적화 코드를 함께 제시"},
    {"id":"testing","name":"테스트 전문가","role":"테스트 커버리지","expertise":["단위 테스트","통합 테스트","TDD"],"focus":"커버리지, 격리, 모킹","persona":"QA 경험이 풍부한 개발자. 테스트 공백을 발견하면 즉시 작성 가능한 테스트 코드를 제시하며, 안정성 향상을 통해 릴리즈 가능성을 높이는 것을 목표"},
    {"id":"arch","name":"아키텍처 전문가","role":"시스템 구조","expertise":["아키텍처","DI","레이어 분리"],"focus":"의존성, 결합도","persona":"대규모 시스템 설계 경험을 가진 아키텍트. 구조적 문제를 발견하면 단계적 리팩터링 계획과 구체적 코드 예시를 함께 제시하는 해결 지향적 전문가"}
  ]
}'
  fi

  echo "$AGENTS_JSON" > "$SESSION_DIR/agents.json"

  # meta.json 업데이트: 에이전트 목록 + status → agents-ready
  python3 - << PYEOF
import json
with open('$SESSION_DIR/agents.json') as f: ad = json.load(f)
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['agents'] = [
    {'id': a['id'], 'name': a['name'], 'role': a.get('role',''), 'persona': a.get('persona',''), 'status': 'pending'}
    for a in ad.get('agents', [])
]
d['language'] = ad.get('language', 'Unknown')
d['framework'] = ad.get('framework', 'Unknown')
d['detected_issues'] = ad.get('detected_issues', [])
d['status'] = 'agents-ready'
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF

  AGENT_IDS=$(get_agent_ids)
  log_progress "✅ [generate] 에이전트 생성 완료: ${AGENT_IDS}"
  exit 0
fi

# ============================================================
# ============================================================
# MODE: --continue — 기존 세션에 라운드 추가
# ============================================================
# ============================================================
if [ "$MODE" = "--continue" ]; then
  CURRENT_STATUS=$(py_get status "unknown")
  if [ "$CURRENT_STATUS" != "completed" ] && [ "$CURRENT_STATUS" != "running" ]; then
    echo "❌ --continue는 completed 또는 running 상태에서만 가능 (현재: $CURRENT_STATUS)" >&2; exit 1
  fi

  LAST_DONE=0
  for r in $(seq 1 99); do
    [ -d "$SESSION_DIR/round-${r}" ] || break
    if [ -f "$SESSION_DIR/round-${r}/votes.json" ]; then
      LAST_DONE=$r
    fi
  done
  if [ "$LAST_DONE" -eq 0 ]; then
    echo "❌ 완료된 라운드 없음" >&2; exit 1
  fi

  START_ROUND=$((LAST_DONE + 1))
  TOTAL_ROUNDS=$((LAST_DONE + ADD_ROUNDS))

  for r in $(seq "$START_ROUND" "$TOTAL_ROUNDS"); do mkdir -p "$SESSION_DIR/round-${r}"; done

  python3 - << PYEOF
import json
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['status'] = 'running'
d['rounds'] = $TOTAL_ROUNDS
for a in d.get('agents', []): a['status'] = 'pending'
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF
  log_progress "🔍 [continue] Round ${LAST_DONE} → ${TOTAL_ROUNDS}"
fi

# ============================================================
# ============================================================
# MODE: run / --continue — 리뷰 라운드 실행
# ============================================================
# ============================================================
if [ "$MODE" = "run" ]; then
  CURRENT_STATUS=$(py_get status "unknown")
  if [ "$CURRENT_STATUS" != "agents-ready" ]; then
    echo "❌ run은 agents-ready 상태에서만 가능 (현재: $CURRENT_STATUS)" >&2; exit 1
  fi
  START_ROUND=1
  for r in $(seq 1 "$TOTAL_ROUNDS"); do mkdir -p "$SESSION_DIR/round-${r}"; done
  mkdir -p "$SESSION_DIR/final"

  python3 - << PYEOF
import json
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['status'] = 'running'
d['current_round'] = 0
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF
  log_progress "🔍 [run] 리뷰 시작: $TOPIC"
  log_progress "   프로젝트: $PROJECT_DIR | 라운드: $TOTAL_ROUNDS"
fi

if [ "$MODE" = "--continue" ]; then
  # continue 모드의 start round
  true  # already set above
fi

# ============================================================
# 에이전트 목록 로드 (run / --continue 공통)
# ============================================================
IFS=' ' read -ra CR_AGENT_IDS <<< "$(get_agent_ids)"
if [ "${#CR_AGENT_IDS[@]}" -eq 0 ]; then
  log_progress "❌ 에이전트 목록 없음"
  update_meta "d['status'] = 'error'"
  exit 1
fi

LANGUAGE=$(get_language)
AGENT_COUNT_ACTUAL="${#CR_AGENT_IDS[@]}"
MAJORITY=$(( (AGENT_COUNT_ACTUAL / 2) + 1 ))

[ "$MODE" = "--continue" ] || START_ROUND=1

# ============================================================
# PHASE 2: 리뷰 라운드
# ============================================================
CONVERGED=false

for round in $(seq "$START_ROUND" "$TOTAL_ROUNDS"); do
  log_progress ""
  log_progress "=========================================="
  log_progress "[Round ${round}/${TOTAL_ROUNDS}] 코드 리뷰 시작"
  log_progress "=========================================="
  mkdir -p "$SESSION_DIR/round-${round}"

  # === 사용자 피드백 확인 (라운드별 1회) ===
  FEEDBACK_FILE="${SESSION_DIR}/user-feedback.json"
  USER_FEEDBACK_SECTION=""
  if [ -f "$FEEDBACK_FILE" ]; then
    USER_FEEDBACK_SECTION=$(python3 -c "
import json
try:
    with open('${FEEDBACK_FILE}') as f:
        data = json.load(f)
    pending = [fb for fb in data.get('feedbacks', []) if not fb.get('used', False)]
    if pending:
        lines = ['\n\n=== 사용자 지시사항 (이번 라운드에 반드시 반영) ===']
        for fb in pending:
            lines.append('- ' + fb['text'])
        for fb in data['feedbacks']:
            if not fb.get('used', False):
                fb['used'] = True
                fb['used_at_round'] = ${round}
        with open('${FEEDBACK_FILE}', 'w') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print('\n'.join(lines))
except Exception:
    pass
" 2>/dev/null)
  fi

  # ----------------------------------------------------------
  # 2a. 에이전트 병렬 분석
  # ----------------------------------------------------------
  # 이전 라운드 점수 추출 (라운드 단위, 에이전트 공통)
  ROUND_PREV_SCORE="?"
  if [ "$round" -gt 1 ]; then
    rp=$((round - 1))
    ROUND_PREV_SCORE=$(python3 -c "
import json
try:
    with open('$SESSION_DIR/round-${rp}/votes.json') as f: d = json.load(f)
    print(f'{d.get(\"overall_quality_score\", 0):.1f}')
except: print('?')
" 2>/dev/null || echo "?")
  fi
  log_progress "[R${round}] 에이전트 병렬 분석 시작 (${AGENT_COUNT_ACTUAL}명)..."

  for id in "${CR_AGENT_IDS[@]}"; do
    NAME=$(get_agent_field "$id" "name")
    ROLE=$(get_agent_field "$id" "role")
    EXPERTISE=$(get_agent_field "$id" "expertise")
    FOCUS=$(get_agent_field "$id" "focus")
    PERSONA=$(get_agent_field "$id" "persona")

    PREV_CONTEXT=""
    PREV_SCORE_LINE=""
    if [ "$round" -gt 1 ]; then
      prev=$((round - 1))
      # 이전 분석: 코드 블록 제거 후 80줄로 제한 (코드 예시는 현재 파일을 직접 읽어 확인)
      MY_PREV=$(sed '/^```/,/^```$/d' "$SESSION_DIR/round-${prev}/${id}.md" 2>/dev/null | head -80 || echo "(없음)")
      # 적용된 변경사항: 파일명과 요약만 (50줄)
      PREV_APPLIED=$(head -50 "$SESSION_DIR/round-${prev}/apply-changes.md" 2>/dev/null || echo "(없음)")
      # 코드 리뷰어 피드백: 핵심만 (40줄)
      PREV_REVIEW=$(head -40 "$SESSION_DIR/round-${prev}/code-reviewer.md" 2>/dev/null || echo "(없음)")
      PREV_SCORE=$(python3 -c "
import json
try:
    with open('$SESSION_DIR/round-${prev}/votes.json') as f: d = json.load(f)
    print(f'{d.get(\"overall_quality_score\", 0):.1f}')
except: print('?')
" 2>/dev/null || echo "?")
      PREV_SCORE_LINE="이전 라운드(Round ${prev}) 품질 점수: ${PREV_SCORE}/10"

      PREV_CONTEXT="
${PREV_SCORE_LINE}

=== 나(${NAME})의 Round ${prev} 분석 ===
${MY_PREV}

=== Round ${prev} 적용된 변경사항 ===
${PREV_APPLIED}

=== Round ${prev} 코드 리뷰어 피드백 ===
${PREV_REVIEW}

---
이번 라운드 지침:
- 다른 에이전트의 개선 제안은 **기본적으로 긍정적으로 수용**하되, 적용 시 주의사항이 있으면 함께 명시
- 단순 반복 동의보다는 새로운 문제점·리스크·엣지케이스 발굴에 집중
- 코드를 직접 재읽어 이전 변경사항이 실제 반영되었는지 확인
- 새 이슈가 없으면 명시적으로 '이번 라운드 신규 이슈 없음' 선언 (빈 칸 채우기 금지)"
    fi

    REVIEW_PROMPT="당신은 ${NAME}입니다.
페르소나: ${PERSONA}
전문 역할: ${ROLE}
핵심 역량: ${EXPERTISE}
검토 포인트: ${FOCUS}

한국어로 응답하세요. 페르소나에 맞는 어조와 관점을 유지하세요.

프로젝트: ${PROJECT_DIR}
코드 위치: ${CODE_DIR}
리뷰 목표: ${TOPIC}
언어/프레임워크: ${LANGUAGE}
현재 라운드: ${round}/${TOTAL_ROUNDS}
${PREV_CONTEXT}

작업:
1. Read/Glob/Grep으로 프로젝트 코드를 직접 확인하세요 — 코드의 현재 실제 상태를 파악하세요
2. ${FOCUS} 관점에서 점수를 8.0 이상으로 올리기 위한 개선사항을 우선 파악하세요
3. 모든 이슈에 수정 후 코드 예시를 반드시 포함하세요 (문제만 나열 금지)
4. 이전 라운드 변경사항이 실제 반영되었는지 확인하고 결과를 명시하세요

다음 형식으로 상세하게 응답하세요:

## ${NAME} 코드 분석 (Round ${round})

### 발견된 이슈 (최우선)
코드를 직접 읽어 확인한 실제 문제점:
**[이슈-N]** 제목
- 위치: 파일경로:라인번호
- 심각도: critical / high / medium / low
- 근본 원인: (설계 결함 / 누락 / 잘못된 패턴 등)
- 현재 코드:
  \`\`\`
  (문제 코드 발췌)
  \`\`\`
- 수정 방안:
  \`\`\`
  (수정된 코드 예시)
  \`\`\`
(이슈가 없으면 이번 라운드 신규 이슈 없음 으로 명시)

### 다른 에이전트 제안 검토 (Round 2 이상)
각 제안을 **긍정적 관점에서 먼저 검토**하세요. 좋은 제안이면 적극적으로 수용하고, 수용하되 조건이나 주의사항이 있을 경우에만 추가하세요:
**[제안명]**: ✅ 수용 / ⚠️ 조건부 수용 / ❌ 반대(타당한 근거 필수)
- 좋은 점: (이 제안이 왜 유효한지 인정)
- 주의사항: (적용 시 추가로 고려할 점 — 없으면 생략)

### 이전 라운드 이슈 추적 (Round 2 이상)
- [이슈명]: ✅ 해결 / ⚠️ 부분 해결 / ❌ 미해결 (코드 확인 결과)

### 개선 제안 (이슈 기반만)
발견된 이슈가 있는 경우에만 작성. 문제 없는 곳을 억지로 개선하지 마세요:
**[개선-N]** 제목
- 위치: 파일경로:라인번호
- 현재 코드:
  \`\`\`
  (실제 코드 발췌)
  \`\`\`
- 개선된 코드:
  \`\`\`
  (수정된 코드 — 바로 적용 가능하게)
  \`\`\`

### 전체 코드 평가
- 품질 점수: X/10 (점수 기준: 7=기능 정상, 8=출시 가능, 9=우수, 10=완벽)
  근거: (2~3줄, 이전 라운드 대비 변화 이유 포함)
- 릴리즈 가능: 가능 / 조건부 / 불가능
- 이번 라운드 개선 제안 적용 시 예상 점수: X/10"

    REVIEW_PROMPT="${REVIEW_PROMPT}${USER_FEEDBACK_SECTION}"
    run_cr_agent "$id" "$round" "$REVIEW_PROMPT" &
  done
  wait
  log_progress "[R${round}] 에이전트 분석 완료"

  # ----------------------------------------------------------
  # 2a-2. 저참여 이슈 강제 투표 (2라운드 이상 참여자 1명 이하)
  # ----------------------------------------------------------
  # 비전문가 에이전트도 기권 대신 코드를 직접 분석해 찬성/반대를 표명하도록 강제
  if [ "$round" -ge 2 ]; then
    prev=$((round - 1))
    FORCE_ISSUES_TMP=$(mktemp)

    python3 - << FORCE_PYEOF > "$FORCE_ISSUES_TMP" 2>/dev/null || echo "[]" > "$FORCE_ISSUES_TMP"
import json, os

session_dir = "$SESSION_DIR"
prev_round  = $prev

def load_json(path):
    try:
        with open(path) as f: return json.load(f)
    except: return {}

prev_votes = load_json(f"{session_dir}/round-{prev_round}/votes.json")
all_issues = prev_votes.get("agreed_changes", []) + prev_votes.get("rejected_changes", [])

result = []
for issue in all_issues:
    agree       = issue.get("votes", 0)
    oppose      = issue.get("opposing_votes", 0)
    participating = issue.get("participating_votes") or (agree + oppose)

    if participating > 1:
        continue  # 이미 충분한 참여

    title     = issue.get("title", "")

    def title_tokens(t):
        import re
        # 한글, 영숫자 토큰 (길이 3 이상) — 보조사/조사 등 단어는 제외
        tokens = re.findall(r'[A-Za-z0-9]{3,}|[\uAC00-\uD7A3]{2,}', t.lower())
        return set(tokens)

    cur_tokens = title_tokens(title)

    def title_match(t1_tokens, t2):
        t2_tokens = title_tokens(t2)
        if not t1_tokens or not t2_tokens:
            return False
        overlap = t1_tokens & t2_tokens
        min_len = min(len(t1_tokens), len(t2_tokens))
        return min_len > 0 and len(overlap) / min_len >= 0.4

    # 이전-이전 라운드에서도 동일 이슈가 저참여였는지 확인 (2라운드 연속)
    persistent = False
    if prev_round >= 2:
        pp_votes = load_json(f"{session_dir}/round-{prev_round-1}/votes.json")
        pp_all   = pp_votes.get("agreed_changes", []) + pp_votes.get("rejected_changes", [])
        for pp in pp_all:
            if title_match(cur_tokens, pp.get("title", "")):
                pp_agree  = pp.get("votes", 0)
                pp_oppose = pp.get("opposing_votes", 0)
                pp_part   = pp.get("participating_votes") or (pp_agree + pp_oppose)
                if pp_part <= 1:
                    persistent = True
                    break
    else:
        persistent = True  # round 2: 이전 라운드(1)만 존재

    if not persistent:
        continue

    abstaining = [av["agent"] for av in issue.get("agent_votes", []) if av.get("stance") == "abstain"]
    if not abstaining:
        continue

    result.append({
        "title":             title,
        "description":       issue.get("description", ""),
        "severity":          issue.get("severity", "medium"),
        "file":              issue.get("file", ""),
        "why_critical":      issue.get("why_critical", ""),
        "abstaining_agents": abstaining,
    })

print(json.dumps(result, ensure_ascii=False))
FORCE_PYEOF

    FORCE_ISSUE_COUNT=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" < "$FORCE_ISSUES_TMP" 2>/dev/null || echo "0")

    if [ "$FORCE_ISSUE_COUNT" -gt 0 ]; then
      log_progress "[R${round}] ⚠️ 저참여 이슈 ${FORCE_ISSUE_COUNT}개 — 기권 에이전트 강제 분석 시작"

      for id in "${CR_AGENT_IDS[@]}"; do
        NAME=$(get_agent_field "$id" "name")
        ROLE=$(get_agent_field "$id" "role")
        EXPERTISE=$(get_agent_field "$id" "expertise")

        # 이 에이전트가 기권한 이슈 목록
        MY_FORCE_TMP=$(mktemp)
        python3 -c "
import json, sys
agent_name = '$NAME'
all_issues = json.load(open('$FORCE_ISSUES_TMP'))
my = [i for i in all_issues if agent_name in i.get('abstaining_agents', [])]
print(json.dumps(my, ensure_ascii=False))
" > "$MY_FORCE_TMP" 2>/dev/null || echo "[]" > "$MY_FORCE_TMP"

        MY_FORCE_COUNT=$(python3 -c "import json,sys; print(len(json.load(open('$MY_FORCE_TMP'))))" 2>/dev/null || echo "0")

        if [ "$MY_FORCE_COUNT" -eq 0 ]; then
          rm -f "$MY_FORCE_TMP"; continue
        fi

        ISSUE_LIST=$(python3 -c "
import json
issues = json.load(open('$MY_FORCE_TMP'))
lines = []
for i, issue in enumerate(issues, 1):
    lines.append(f'이슈 {i}: [{issue[\"severity\"].upper()}] {issue[\"title\"]}')
    lines.append(f'  파일: {issue.get(\"file\", \"?\")}'[:120])
    lines.append(f'  설명: {issue.get(\"description\", \"\")}'[:200])
    lines.append(f'  중요도: {issue.get(\"why_critical\", \"\")}'[:200])
    lines.append('')
print('\n'.join(lines))
" 2>/dev/null)

        (
          FORCED_PROMPT="당신은 ${NAME}입니다.
역할: ${ROLE}
전문 역량: ${EXPERTISE}

[긴급 강제 투표 요청]
아래 이슈들은 2라운드 이상 전문가 1명만 언급하여 채택/기각이 결정되지 못한 중요 이슈입니다.
당신의 전문 영역이 아니더라도, 직접 코드를 읽어 분석하고 반드시 찬성 또는 반대 입장을 표명해야 합니다.
기권은 허용되지 않습니다 — 치명적인 문제가 장기간 방치되는 것을 막기 위해 모든 에이전트의 참여가 필요합니다.

프로젝트 코드 위치: ${CODE_DIR}

=== 강제 분석 대상 이슈 ===
${ISSUE_LIST}

각 이슈에 대해 수행:
1. Read/Grep으로 해당 파일의 실제 코드를 직접 확인
2. 이슈가 실제로 존재하는지, 수정이 필요한지 판단
3. ✅ 찬성 또는 ❌ 반대를 반드시 선택 (기권 불가)

## [강제 투표 결과] ${NAME}

### 이슈 N: [이슈 제목]
코드 확인:
\`\`\`
(직접 읽은 코드 핵심 부분)
\`\`\`
판단: ✅ 찬성 — 이유: (1-2문장)
또는
판단: ❌ 반대 — 이유: (1-2문장)"

          LOG="$LOG_DIR/${LOG_PREFIX}-${id}.log"
          OUTPUT="$SESSION_DIR/round-${round}/${id}.md"
          provider=$(resolve_agent_provider "$id")

          {
            echo ""
            echo "---"
            echo "## [강제 투표] ${NAME}"
            echo ""
          } >> "$OUTPUT"

          force_result=""
          case "$provider" in
            "claude")
              ftmp=$(mktemp)
              if (cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
                  "$CLAUDE_BIN" --output-format stream-json --verbose -p "$FORCED_PROMPT") \
                  2>> "$LOG" > "$ftmp"; then
                force_result=$(python3 -c "
import json, sys
data = sys.stdin.read().strip()
for line in reversed(data.split('\n')):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'result' and 'result' in obj:
            print(obj['result']); exit(0)
    except: pass
texts = []
for line in data.split('\n'):
    try:
        obj = json.loads(line.strip())
        if obj.get('type') == 'assistant':
            for block in obj.get('message', {}).get('content', []):
                if block.get('type') == 'text' and block.get('text','').strip():
                    texts.append(block['text'])
    except: pass
if texts: print('\n'.join(texts))
" < "$ftmp" 2>/dev/null)
              fi
              rm -f "$ftmp"
              ;;
            "gemini"|"gemini-flash"|"gemini-pro")
              _model="gemini-2.0-flash"
              [ "$provider" = "gemini-pro" ] && _model="gemini-1.5-pro"
              _ctx=$(collect_code_context)
              force_result=$(call_gemini "${_ctx}\n\n---\n${FORCED_PROMPT}" "$LOG" "$_model")
              ;;
            "gpt4o-mini"|"gpt4o"|"openai")
              _model="gpt-4o-mini"
              [ "$provider" = "gpt4o" ] && _model="gpt-4o"
              _ctx=$(collect_code_context)
              force_result=$(call_openai "${_ctx}\n\n---\n${FORCED_PROMPT}" "$LOG" "$_model")
              ;;
            "gemini-cli")
              force_result=$(call_gemini_cli "$FORCED_PROMPT" "$LOG" "$PROJECT_DIR")
              ;;
            "codex-cli")
              force_result=$(call_codex_cli "$FORCED_PROMPT" "$LOG" "$PROJECT_DIR")
              ;;
          esac

          if [ -n "$force_result" ]; then
            echo "$force_result" >> "$OUTPUT"
            echo "[$(date +%H:%M:%S)] [R${round}] ${id} 강제 투표 완료 ✓" >> "$LOG"
          else
            echo "*(강제 투표 분석 실패)*" >> "$OUTPUT"
            echo "[$(date +%H:%M:%S)] [R${round}] ${id} 강제 투표 실패" >> "$LOG"
          fi
        ) &
        rm -f "$MY_FORCE_TMP"
      done
      wait
      log_progress "[R${round}] 강제 투표 완료"
    fi
    rm -f "$FORCE_ISSUES_TMP"
  fi

  # ----------------------------------------------------------
  # 2b. 투표 집계
  # ----------------------------------------------------------
  log_progress "[R${round}] 투표 집계 중..."

  ALL_REVIEWS=""
  for id in "${CR_AGENT_IDS[@]}"; do
    NAME=$(get_agent_field "$id" "name")
    content=$(head -400 "$SESSION_DIR/round-${round}/${id}.md" 2>/dev/null || echo "(없음)")
    ALL_REVIEWS+="=== ${NAME} ===
${content}

---

"
  done

  VOTE_PROMPT="당신은 코드 리뷰 투표 집계 전문가입니다. 한국어로 응답하세요.

총 에이전트: ${AGENT_COUNT_ACTUAL}명
이전 라운드 품질 점수: ${ROUND_PREV_SCORE}/10

## 투표 규칙 (반드시 준수)
각 에이전트는 이슈별로 세 가지 입장 중 하나입니다:
- **agree(찬성)**: 이슈를 명시적으로 언급하고 수정 필요하다고 판단
- **oppose(반대)**: 이슈에 명시적으로 반대 의견을 표명
- **abstain(기권)**: 이슈를 전혀 언급하지 않은 에이전트 (해당 도메인 전문가가 아니므로 의사결정 불가)

채택 기준: **참여 에이전트(agree+oppose) 중 과반수 이상이 찬성**
- 참여 에이전트 = agree 수 + oppose 수 (abstain 제외)
- 참여 에이전트가 0명이면 기각
- agree > oppose이면 채택 (예: 2찬성 0반대 5기권 → 참여2명 중 2찬성 → 채택)
- agree <= oppose이면 기각

## 점수 기준 (반드시 이 루브릭으로 평가):
- 5점: 기본 기능만 동작, 다수의 심각한 문제
- 6점: 동작하지만 중요한 개선 필요
- 7점: 기능 정상, 일부 개선 권장
- 8점: 출시 가능, 소소한 개선 여지 있음
- 9점: 코드 품질 우수, 최적화 수준
- 10점: 완벽, 개선할 것이 없음

=== 에이전트 리뷰 결과 ===
${ALL_REVIEWS}

${AGENT_COUNT_ACTUAL}개 리뷰에서:
1. 모든 이슈/개선사항을 식별하고, 각 에이전트의 입장을 agree/oppose/abstain으로 분류
2. 참여 에이전트(agree+oppose) 중 agree가 더 많으면 채택 목록에 포함
3. 나머지는 기각 목록에 포함
4. agent_votes에는 전체 에이전트(${AGENT_COUNT_ACTUAL}명)를 반드시 모두 포함할 것
5. overall_quality_score는 위 루브릭 기준으로 공정하게 평가하세요
   (이전 점수 ${ROUND_PREV_SCORE}에서 이번에 적용된 개선사항이 반영된 점수)

다음 JSON 형식으로만 응답하세요 (마크다운 코드블록 사용 가능):
{
  \"total_agents\": ${AGENT_COUNT_ACTUAL},
  \"agreed_changes\": [
    {
      \"id\": \"change-1\",
      \"title\": \"변경 제목\",
      \"file\": \"lib/main.dart\",
      \"description\": \"구체적인 변경 내용\",
      \"reason\": \"왜 필요한가\",
      \"votes\": 2,
      \"opposing_votes\": 0,
      \"abstain_votes\": 5,
      \"participating_votes\": 2,
      \"severity\": \"high\",
      \"why_critical\": \"왜 중요한지 1-2문장\",
      \"proposer\": \"제안한 에이전트명\",
      \"supporters\": [\"에이전트명1\", \"에이전트명2\"],
      \"agent_votes\": [
        {\"agent\": \"에이전트명\", \"stance\": \"agree\", \"reason\": \"한 줄 이유\"},
        {\"agent\": \"에이전트명\", \"stance\": \"abstain\", \"reason\": \"언급 없음\"},
        {\"agent\": \"에이전트명\", \"stance\": \"oppose\", \"reason\": \"한 줄 이유\"}
      ]
    }
  ],
  \"rejected_changes\": [
    {
      \"title\": \"기각된 변경\",
      \"votes\": 0,
      \"opposing_votes\": 1,
      \"abstain_votes\": 6,
      \"participating_votes\": 1,
      \"proposer\": \"제안한 에이전트명\",
      \"severity\": \"low\",
      \"why_critical\": \"왜 제안됐는지 1-2문장\",
      \"reason\": \"기각 이유 (반대 우세 또는 참여자 없음)\",
      \"agent_votes\": [
        {\"agent\": \"에이전트명\", \"stance\": \"abstain\", \"reason\": \"언급 없음\"},
        {\"agent\": \"에이전트명\", \"stance\": \"oppose\", \"reason\": \"한 줄 이유\"}
      ]
    }
  ],
  \"overall_quality_score\": 7.5,
  \"prev_quality_score\": ${ROUND_PREV_SCORE},
  \"score_change\": 1.0,
  \"release_ready\": false,
  \"summary\": \"이번 라운드 핵심 개선사항 요약\"
}"

  VOTE_RAW=$(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$VOTE_PROMPT" 2>>"$LOG_DIR/${LOG_PREFIX}-voter.log") || true
  VOTES_JSON=$(echo "$VOTE_RAW" | extract_json)
  VOTES_VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print('ok' if 'agreed_changes' in d else 'fail')
except: print('fail')
" <<< "$VOTES_JSON" 2>/dev/null)

  [ "$VOTES_VALID" != "ok" ] && VOTES_JSON="{\"agreed_changes\":[],\"rejected_changes\":[],\"overall_quality_score\":5,\"release_ready\":false,\"summary\":\"집계 실패\"}"
  echo "$VOTES_JSON" > "$SESSION_DIR/round-${round}/votes.json"

  python3 - << PYEOF
import json
with open('$SESSION_DIR/round-${round}/votes.json') as f: d = json.load(f)
lines = ['# Round ${round} 투표 결과\n\n']
lines.append(f"총 에이전트: {d.get('total_agents', ${AGENT_COUNT_ACTUAL})}명 | 과반수: {d.get('majority_threshold', ${MAJORITY})}명\n\n")
lines.append(f"**품질 점수: {d.get('overall_quality_score', 0)}/10** | **릴리즈 가능: {'✅' if d.get('release_ready') else '❌'}**\n\n")
lines.append(f"> {d.get('summary', '')}\n\n")
changes = d.get('agreed_changes', [])
lines.append(f'## ✅ 채택 ({len(changes)}개)\n\n')
for c in changes:
    lines.append(f"### [{c.get('severity','?').upper()}] {c.get('title','')}\n")
    lines.append(f"- 파일: \`{c.get('file','?')}\`\n- 찬성: {c.get('votes',0)}표\n- 설명: {c.get('description','')}\n\n")
rejected = d.get('rejected_changes', [])
if rejected:
    lines.append(f'## ❌ 기각 ({len(rejected)}개)\n\n')
    for r in rejected:
        lines.append(f"- {r.get('title','')}: {r.get('votes',0)}표\n")
with open('$SESSION_DIR/round-${round}/votes.md', 'w') as f: f.writelines(lines)
PYEOF

  AGREED_COUNT=$(python3 -c "
import json
with open('$SESSION_DIR/round-${round}/votes.json') as f: d = json.load(f)
print(len(d.get('agreed_changes', [])))
" 2>/dev/null || echo "0")
  log_progress "[R${round}] 투표 완료 — 채택 ${AGREED_COUNT}개"

  # ----------------------------------------------------------
  # 2c. 변경사항 적용 (--dangerously-skip-permissions: 파일 편집 필요)
  # ----------------------------------------------------------
  APPLIER_LOG="$LOG_DIR/${LOG_PREFIX}-applier.log"
  if [ "$AGREED_COUNT" -gt 0 ]; then
    log_progress "[R${round}] 변경사항 적용 중 (${AGREED_COUNT}개)..."

    AGREED_DETAILS=$(python3 - << PYEOF
import json
with open('$SESSION_DIR/round-${round}/votes.json') as f: d = json.load(f)
for i, c in enumerate(d.get('agreed_changes', []), 1):
    print(f"변경 {i}: {c.get('title','')}")
    print(f"  파일: {c.get('file','?')}")
    print(f"  심각도: {c.get('severity','?')}")
    print(f"  설명: {c.get('description','')}")
    print(f"  이유: {c.get('reason','')}")
    print()
PYEOF
)

    # APPLIER 시작 로그
    {
      echo "[$(date +%H:%M:%S)] [R${round}] APPLIER 시작 — ${AGREED_COUNT}개 변경사항 적용 예정"
      echo "[$(date +%H:%M:%S)] 프로젝트: $PROJECT_DIR | 언어: $LANGUAGE"
      echo ""
      echo "=== 적용 대상 ==="
      echo "$AGREED_DETAILS"
      echo "=================="
      echo ""
    } >> "$APPLIER_LOG"

    APPLY_PROMPT="당신은 코드 수정 전문가입니다. 한국어로 응답하세요.

프로젝트: ${PROJECT_DIR}
언어/프레임워크: ${LANGUAGE}

다음 코드 변경사항을 실제 파일에 적용하세요.
Read로 먼저 확인 → Edit/Write/MultiEdit으로 수정.

=== 적용할 변경사항 ===
${AGREED_DETAILS}

주의:
- 각 파일을 Read로 먼저 읽어 현재 내용 확인
- 최소한의 변경만 적용 (불필요한 수정 금지)
- 프로젝트 외부 파일 절대 수정 금지
- 적용 불가한 경우 이유 명시

완료 후 보고:

## 변경사항 적용 결과

### ✅ 성공
- **파일**: 경로 / **변경**: 설명

### ❌ 실패/스킵
- **파일**: 경로 / **이유**: 설명

## 요약
총 ${AGREED_COUNT}개 중 N개 적용"

    (cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
      "$CLAUDE_BIN" --dangerously-skip-permissions -p "$APPLY_PROMPT") \
      > "$SESSION_DIR/round-${round}/apply-changes.md" \
      2>>"$APPLIER_LOG"
    APPLY_EXIT=$?

    if [ "$APPLY_EXIT" -eq 0 ]; then
      echo "[$(date +%H:%M:%S)] [R${round}] APPLIER 완료 ✓ (exit: 0)" >> "$APPLIER_LOG"
      echo "[$(date +%H:%M:%S)] 결과: $SESSION_DIR/round-${round}/apply-changes.md" >> "$APPLIER_LOG"
    else
      echo "[$(date +%H:%M:%S)] [R${round}] APPLIER 실패 (exit: $APPLY_EXIT)" >> "$APPLIER_LOG"
    fi
    log_progress "[R${round}] 변경사항 적용 완료"
  else
    {
      echo "[$(date +%H:%M:%S)] [R${round}] 채택된 변경사항 없음 — 코드 수정 스킵"
    } >> "$APPLIER_LOG"
    printf '# 이번 라운드 적용 변경사항 없음\n\n과반수 동의 변경사항이 없어 코드 수정 생략.\n' \
      > "$SESSION_DIR/round-${round}/apply-changes.md"
    log_progress "[R${round}] 합의된 변경사항 없음"
  fi

  # ----------------------------------------------------------
  # 2d. 언어별 코드 리뷰어
  # ----------------------------------------------------------
  log_progress "[R${round}] ${LANGUAGE} 코드 리뷰어 실행 중..."

  APPLIED_SUMMARY=$(head -120 "$SESSION_DIR/round-${round}/apply-changes.md" 2>/dev/null || echo "(없음)")

  REVIEWER_PROMPT="당신은 ${LANGUAGE} 코드 전문 리뷰어입니다. 한국어로 응답하세요.

프로젝트: ${PROJECT_DIR}
이번 라운드 적용된 변경사항:
${APPLIED_SUMMARY}

작업:
1. Read/Glob/Grep으로 변경된 파일과 관련 코드 실제 확인
2. ${LANGUAGE} 관점의 심층 검토

검토 항목:
- 언어/프레임워크 관용구 및 베스트 프랙티스
- 타입 안정성 및 null 안전성
- 성능 (불필요한 재빌드/메모리 누수/비효율)
- 테스트 가능성
- 보안

## ${LANGUAGE} 코드 리뷰 보고서 (Round ${round})

### 변경사항 검증
### 코드 품질 평가
| 항목 | 점수 | 코멘트 |
|------|------|--------|
| 가독성 | X/10 | |
| 유지보수성 | X/10 | |
| 성능 | X/10 | |
| 보안 | X/10 | |

### 추가 발견된 이슈
### 다음 라운드 권장사항"

  (cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$REVIEWER_PROMPT") \
    > "$SESSION_DIR/round-${round}/code-reviewer.md" \
    2>>"$LOG_DIR/${LOG_PREFIX}-reviewer.log"
  log_progress "[R${round}] 코드 리뷰 완료"

  # ----------------------------------------------------------
  # 2e. 수렴 확인 (votes.json 기반 — Claude 호출 없이 즉시 판단)
  # ----------------------------------------------------------
  log_progress "[R${round}] 수렴 확인 중..."

  SESSION_DIR="$SESSION_DIR" ROUND_NUM="$round" TOTAL_ROUNDS="$TOTAL_ROUNDS" \
  python3 - << 'CONV_PYEOF' > "$SESSION_DIR/round-${round}/convergence.json"
import json, os, sys

session_dir = os.environ.get('SESSION_DIR', '')
round_num   = int(os.environ.get('ROUND_NUM', '0'))
total       = int(os.environ.get('TOTAL_ROUNDS', '0'))

def load_json(path):
    try:
        with open(path) as f: return json.load(f)
    except: return {}

votes = load_json(f'{session_dir}/round-{round_num}/votes.json')
q           = float(votes.get('overall_quality_score') or 0)
_pq         = votes.get('prev_quality_score')
prev_q      = float(_pq) if _pq is not None else q
_sc         = votes.get('score_change')
score_change= float(_sc) if _sc is not None else 0.0
release_ready = bool(votes.get('release_ready', False))
agreed      = votes.get('agreed_changes', [])
rejected    = votes.get('rejected_changes', [])

# 이전 2라운드 연속 정체 감지
stagnant_rounds = 0
for r in range(round_num - 1, max(0, round_num - 3), -1):
    pv = load_json(f'{session_dir}/round-{r}/votes.json')
    if len(pv.get('agreed_changes', [])) == 0:
        stagnant_rounds += 1
    else:
        break

converged = False
reason    = ""

if q >= 8.0:
    converged = True
    reason = f"품질 점수 {q}/10 달성 — 출시 가능 수준"
elif release_ready and q >= 7.5:
    converged = True
    reason = f"릴리즈 준비 완료 (품질 {q}/10)"
elif stagnant_rounds >= 2 and abs(score_change) < 0.1:
    converged = True
    reason = f"정체로 인한 종료 — {stagnant_rounds}라운드 연속 변경 없음 (품질 {q}/10)"
elif round_num >= total:
    converged = True
    reason = f"최대 라운드 도달 ({total}라운드, 품질 {q}/10)"
else:
    reason = f"계속 진행 (품질 {q}/10, 이전 대비 {score_change:+.1f})"

convergence_rate = round(min(1.0, q / 10.0), 2)
top_issues = [r['title'] for r in rejected[:5]]

result = {
    "converged": converged,
    "convergence_rate": convergence_rate,
    "release_ready": release_ready,
    "quality_score": q,
    "remaining_critical_issues": top_issues,
    "consensus_summary": reason,
}
print(json.dumps(result, ensure_ascii=False, indent=2))
CONV_PYEOF

  python3 - << PYEOF
import json
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
try:
    with open('$SESSION_DIR/round-${round}/convergence.json') as f2: cv = json.load(f2)
except: cv = {}
d['current_round'] = ${round}
d['converged'] = cv.get('converged', False)
d['quality_score'] = cv.get('quality_score', 0)
d['release_ready'] = cv.get('release_ready', False)
d['convergence_rate'] = cv.get('convergence_rate', 0)
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF

  CONVERGED_VAL=$(python3 -c "
import json
try:
    d = json.load(open('$SESSION_DIR/round-${round}/convergence.json'))
    print('true' if d.get('converged', False) else 'false')
except: print('false')
" 2>/dev/null)

  # 코드 레벨 stagnation 감지: LLM 판단과 무관하게 강제 종료
  # 채택 변경 0건 + 이전 점수와 동일하면 더 이상 토론해도 의미 없음
  if [ "$AGREED_COUNT" -eq 0 ] && [ "$round" -gt 1 ]; then
    CURR_SCORE=$(python3 -c "
import json
try:
    d = json.load(open('$SESSION_DIR/round-${round}/votes.json'))
    print(f'{d.get(\"overall_quality_score\", 0):.1f}')
except: print('0')
" 2>/dev/null || echo "0")
    if [ "$CURR_SCORE" = "$ROUND_PREV_SCORE" ]; then
      log_progress "[R${round}] ⚠️ 정체 감지 — 변경 0건, 점수 동일(${CURR_SCORE}) → 조기 종료"
      CONVERGED_VAL="true"
    fi
  fi

  log_progress "[R${round}] 수렴: ${CONVERGED_VAL}"

  if [ "$CONVERGED_VAL" = "true" ]; then
    log_progress "✅ 모든 에이전트 합의 — 조기 종료"
    CONVERGED=true
    break
  fi
  log_progress "[R${round}] 완료 → 다음 라운드"
done

# ============================================================
# PHASE 3: 최종 보고서
# ============================================================
log_progress ""
log_progress "=== 최종 보고서 생성 중 ==="
mkdir -p "$SESSION_DIR/final"

ROUNDS_SUMMARY=""
for r in $(seq 1 "$TOTAL_ROUNDS"); do
  [ -d "$SESSION_DIR/round-${r}" ] || continue
  V=$(python3 -c "
import json, os
vpath='$SESSION_DIR/round-${r}/votes.json'
if os.path.exists(vpath):
    with open(vpath) as f: d=json.load(f)
    print(f'품질점수: {d.get(\"overall_quality_score\",\"?\")}/10, 채택: {len(d.get(\"agreed_changes\",[]))}개, {d.get(\"summary\",\"\")}')
" 2>/dev/null)
  ROUNDS_SUMMARY+="### Round ${r}: ${V}
"
done

FINAL_CONV=$(python3 - << PYEOF
import json, os
for r in range($TOTAL_ROUNDS, 0, -1):
    p = '$SESSION_DIR/round-' + str(r) + '/convergence.json'
    if os.path.exists(p):
        with open(p) as f: d = json.load(f)
        print(f"수렴: {'예' if d.get('converged',False) else '아니오'}, 품질: {d.get('quality_score',0)}/10")
        print(f"릴리즈: {'가능' if d.get('release_ready',False) else '불가능'}")
        issues = d.get('remaining_critical_issues', [])
        if issues: print("잔존: " + ", ".join(issues))
        print(f"요약: {d.get('consensus_summary','')}")
        break
PYEOF
)

FINAL_PROMPT="[TASK: STRUCTURED DOCUMENT GENERATION]
당신은 코드 리뷰 최종 보고서 작성기입니다. 한국어로 작성하세요.

출력 규칙 (반드시 준수):
1. 아래 형식의 마크다운 문서만 출력하세요
2. 메모리 저장, 도구 호출, 질문, 대화체 응답 절대 금지
3. '다음 세션', '어느 것부터', '진행하시겠습니까' 등의 표현 사용 금지
4. 문서 이외의 어떤 내용도 출력하지 마세요

=== 입력 데이터 ===
프로젝트: ${PROJECT_DIR}
리뷰 목표: ${TOPIC}
언어/프레임워크: ${LANGUAGE}
진행 라운드: ${TOTAL_ROUNDS}

라운드별 요약:
${ROUNDS_SUMMARY}

최종 수렴 결과:
${FINAL_CONV}

=== 출력할 문서 형식 ===

## 코드 리뷰 최종 보고서

### 전체 요약
| 항목 | 내용 |
|------|------|
| 리뷰 목표 | |
| 언어/프레임워크 | |
| 진행 라운드 | |
| 최종 결론 | 릴리즈 가능 / 조건부 / 추가 수정 필요 |
| 최종 품질 점수 | X/10 |

### 라운드별 주요 변경사항

### 잔존 이슈

### 최종 코드 품질 평가
| 항목 | 점수 |
|------|------|

### 릴리즈 체크리스트
- [ ] 항목

### 다음 단계 권고사항"

(cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  "$CLAUDE_BIN" --allowedTools "" -p "$FINAL_PROMPT") \
  > "$SESSION_DIR/final/synthesis.md" \
  2>>"$LOG_DIR/${LOG_PREFIX}-final.log"

# 훅 아티팩트 제거
python3 - << 'PYEOF'
import re
path = "$SESSION_DIR/final/synthesis.md"
try:
    with open(path) as f: text = f.read()
    for pattern in [r'\n메모리 저장 완료됐습니다', r'\n✅ 메모리', r'\[DONE\]']:
        m = re.search(pattern, text)
        if m:
            text = text[:m.start()].rstrip()
    with open(path, 'w') as f: f.write(text)
except: pass
PYEOF

cp "$SESSION_DIR/final/synthesis.md" "$SESSION_DIR/conclusion.md" 2>/dev/null

CONVERGED_PY=$([[ "$CONVERGED" == "true" ]] && echo "True" || echo "False")
python3 - << PYEOF
import json, datetime
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['status'] = 'completed'
d['converged'] = ${CONVERGED_PY}
d['completed_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF

log_progress "🔍 Code Review 완료! 수렴: ${CONVERGED} | 세션: ${SESSION_ID}"
