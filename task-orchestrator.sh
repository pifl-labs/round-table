#!/usr/bin/env bash
set -euo pipefail

# Task Orchestrator — 동적 에이전트 파이프라인
#
# 사용법:
#   generate SESSION_ID       — 작업 분석 + 에이전트 파이프라인 생성
#   run SESSION_ID            — 파이프라인 실행 (phase 1 → 2 → 3 → 평가)
#   --continue SESSION_ID [N] — 추가 작업 사이클
#
# 파이프라인 흐름:
#   서버: meta.json 생성 → generate → [UI: 파이프라인 확인] → run → rating → 완료
#
# 특이사항:
#   - 각 에이전트는 매번 새 세션으로 실행 (컨텍스트 누적 없음)
#   - 이전 단계 결과는 파일 주입으로 전달
#   - --output-format json 으로 텍스트 추출

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# LOG_DIR은 세션 ID 결정 후 ${SESSION_DIR}/logs 로 설정 (per-session 격리)
TASK_SESSIONS_BASE="${SCRIPT_DIR}/sessions/tasks"
JSON_EXTRACTOR="${SCRIPT_DIR}/.extract_json.py"

RELEASE_THRESHOLD_DEFAULT="${RELEASE_THRESHOLD:-7.5}"

# ============================================================
# 모드 파싱
# ============================================================
MODE="${1:-}"
case "$MODE" in
  generate)  SESSION_ID="${2:?Usage: $0 generate SESSION_ID}" ;;
  run)       SESSION_ID="${2:?Usage: $0 run SESSION_ID}" ;;
  --continue)
    SESSION_ID="${2:?Usage: $0 --continue SESSION_ID [cycles]}"
    ADD_CYCLES="${3:-1}"
    ;;
  *)
    echo "Usage: $0 <generate|run|--continue> SESSION_ID [N]" >&2
    exit 1
    ;;
esac

SESSION_DIR="${TASK_SESSIONS_BASE}/${SESSION_ID}"
[ -d "$SESSION_DIR" ] || { echo "❌ 세션 디렉토리 없음: $SESSION_DIR" >&2; exit 1; }
[ -f "$SESSION_DIR/meta.json" ] || { echo "❌ meta.json 없음" >&2; exit 1; }

# ============================================================
# 환경 로드 (per-session logs/ 격리)
# ============================================================
LOG_DIR="${SESSION_DIR}/logs"
mkdir -p "$LOG_DIR"

SCRIPT_ENV="${SCRIPT_DIR}/.env"
if [ -f "$SCRIPT_ENV" ]; then
  set +u; set -a; source "$SCRIPT_ENV"; set +a; set -u
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

# Codex CLI 탐지 (선택)
CODEX_BIN="${CODEX_BIN:-$(which codex 2>/dev/null || true)}"
for candidate in "/opt/homebrew/bin/codex" "$HOME/.local/bin/codex" "/usr/local/bin/codex"; do
  [ -x "$candidate" ] && { CODEX_BIN="$candidate"; break; }
done

# Gemini CLI 탐지 (선택)
GEMINI_BIN="${GEMINI_BIN:-$(which gemini 2>/dev/null || true)}"
for candidate in "/opt/homebrew/bin/gemini" "$HOME/.local/bin/gemini" "/usr/local/bin/gemini"; do
  [ -x "$candidate" ] && { GEMINI_BIN="$candidate"; break; }
done

# ============================================================
# 유틸리티
# ============================================================
# LOG_PREFIX 제거: 로그는 세션 내부 logs/ 에 저장되므로 prefix 불필요

ensure_project_claudeignore() {
  local dir="$1"
  [ -f "$dir/.claudeignore" ] && return
  cat > "$dir/.claudeignore" << 'IGNORE_EOF'
# Round Table 자동 생성 — 토큰 절감을 위한 불필요 파일 제외
build/
.dart_tool/
.pub-cache/
.pub/
node_modules/
.npm/
.gradle/
.git/
__pycache__/
*.pyc
*.pyo
*.o
*.a
*.class
coverage/
dist/
out/
.DS_Store
*.png
*.jpg
*.jpeg
*.webp
*.gif
*.ico
*.svg
*.ttf
*.otf
*.woff
*.woff2
*.mp4
*.mp3
*.zip
*.tar.gz
*.tar
*.pdf
*.lock
IGNORE_EOF
}

log_progress() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_DIR/main.log"; }

py_get() { python3 -c "import json; d=json.load(open('$SESSION_DIR/meta.json')); print(d.get('$1','$2'))" 2>/dev/null || echo "$2"; }

extract_json() { python3 "$JSON_EXTRACTOR"; }

update_meta() {
  python3 - << PYEOF
import json
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
$1
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF
}

update_agent_status() {
  python3 -c "
import json
try:
    with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
    for a in d.get('agents', []):
        if a['id'] == '$1': a['status'] = '$2'
    with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
except: pass
" 2>/dev/null
}

get_agent_ids_for_phase() {
  python3 -c "
import json
try:
    with open('$SESSION_DIR/pipeline.json') as f: d = json.load(f)
    ids = [a['id'] for a in d.get('agents', []) if a.get('exec_phase', 1) == $1]
    print(' '.join(ids))
except: print('')
" 2>/dev/null
}

get_agent_field() {
  python3 -c "
import json
try:
    with open('$SESSION_DIR/pipeline.json') as f: d = json.load(f)
    for a in d.get('agents', []):
        if a['id'] == '$1':
            v = a.get('$2', '')
            print(v)
            break
except: print('')
" 2>/dev/null
}

# Claude JSON 출력에서 텍스트 추출
extract_result_text() {
  python3 -c "
import json, sys
data = sys.stdin.read().strip()
try:
    obj = json.loads(data)
    if 'result' in obj:
        print(obj['result'])
        exit(0)
except: pass
# NDJSON fallback
for line in data.split('\n'):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'result' and 'result' in obj:
            print(obj['result'])
            exit(0)
    except: pass
print(data)
" 2>/dev/null
}

# AI_PROFILE 로드 (선택 — 기본값: claude)
AI_PROFILE="${AI_PROFILE:-$(python3 -c "
import json
try:
  d = json.load(open('$SESSION_DIR/meta.json'))
  print(d.get('ai_profile','claude'))
except: print('claude')
" 2>/dev/null)}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"

# 에이전트 실행 — 매번 새 세션 (AI_PROFILE에 따라 프로바이더 선택)
run_task_agent() {
  local id="$1" phase="$2" prompt="$3"
  local output="$SESSION_DIR/phase-${phase}/${id}.md"
  local log="$LOG_DIR/${id}.log"
  local tmp; tmp=$(mktemp)

  # 프로바이더 결정: codex-cli 프로파일이면 Codex CLI 사용, 그 외 Claude
  local provider="claude"
  case "$AI_PROFILE" in
    "codex-cli") provider="codex-cli" ;;
    "gemini-cli") provider="gemini-cli" ;;
  esac

  echo "[$(date +%H:%M:%S)] [P${phase}] ${id} 시작 (${provider})..." >> "$log"
  update_agent_status "$id" "running"

  local ok=false
  local used_claude=false

  case "$provider" in
    "codex-cli")
      # OAuth 자격증명 자동 사용 (~/.codex/auth.json) — API 키 불필요
      if [ -x "${CODEX_BIN:-}" ]; then
        if "$CODEX_BIN" exec --full-auto --sandbox read-only \
            -C "$PROJECT_DIR" \
            --output-last-message "$tmp" \
            "$prompt" >> "$log" 2>&1; then
          ok=true
        fi
      else
        echo "(Codex CLI 미설치 — Claude 폴백)" >> "$log"
      fi
      ;;
    "gemini-cli")
      # OAuth 자격증명 자동 사용 (~/.gemini/oauth_creds.json) — API 키 불필요
      if [ -x "${GEMINI_BIN:-}" ]; then
        if (cd "$PROJECT_DIR" && "$GEMINI_BIN" -p "$prompt") > "$tmp" 2>> "$log"; then
          ok=true
        fi
      else
        echo "(Gemini CLI 미설치 — Claude 폴백)" >> "$log"
      fi
      ;;
  esac

  # Claude 폴백 또는 기본 실행
  if [ "$ok" = false ]; then
    if (cd "$PROJECT_DIR" && \
        CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        "$CLAUDE_BIN" --output-format json --tools "WebSearch,Read,Glob,Grep" -p "$prompt") > "$tmp" 2>> "$log"; then
      ok=true
      used_claude=true
    fi
  fi

  if [ "$ok" = true ]; then
    # Claude JSON 파싱 vs CLI plain text
    if [ "$provider" = "claude" ] || [ "$used_claude" = "true" ]; then
      extract_result_text < "$tmp" > "$output"
    else
      cat "$tmp" > "$output"
    fi
    update_agent_status "$id" "done"
    echo "[$(date +%H:%M:%S)] [P${phase}] ${id} 완료 ✓" >> "$log"
  else
    echo "*(에이전트 실행 실패)*" > "$output"
    update_agent_status "$id" "error"
    echo "[$(date +%H:%M:%S)] [P${phase}] ${id} 실패" >> "$log"
  fi
  rm -f "$tmp"
}

# ============================================================
# ============================================================
# MODE: generate — 파이프라인 생성
# ============================================================
# ============================================================
if [ "$MODE" = "generate" ]; then
  TASK=$(py_get task "")
  PROJECT_DIR=$(py_get project_dir "$(pwd)")
  AGENT_COUNT=$(py_get agent_count "5")

  log_progress "🔧 [generate] 작업 분석 + 파이프라인 설계 시작"
  ensure_project_claudeignore "$PROJECT_DIR"
  log_progress "   작업: $TASK"
  log_progress "   프로젝트: $PROJECT_DIR"
  log_progress "   에이전트 수: $AGENT_COUNT"

  CONTEXT=$(py_get context "")
  CONTEXT_LINE=""
  [ -n "$CONTEXT" ] && CONTEXT_LINE="추가 컨텍스트: ${CONTEXT}"

  PIPELINE_PROMPT="당신은 AI 에이전트 파이프라인 설계 전문가입니다. 한국어로 응답하세요.

주어진 작업을 분석하고 최적의 실행 파이프라인을 설계하세요.

작업: ${TASK}
프로젝트 경로: ${PROJECT_DIR}
에이전트 수: ${AGENT_COUNT}명 (2~${AGENT_COUNT} 범위 조정 가능)
${CONTEXT_LINE}

실행 단계 (exec_phase):
- 1: 조사/계획 (research, analysis, design) — 정보 수집, 요구사항 분석, 설계
- 2: 구현/실행 (implementation, creation) — 실제 작업 수행, 코드 작성, 문서 작성
- 3: 검증/평가 (testing, review, validation) — 품질 검증, 릴리즈 판단

규칙:
1. 같은 exec_phase 에이전트는 병렬 실행됨
2. exec_phase 2는 exec_phase 1의 결과를 입력으로 받음
3. exec_phase 3은 exec_phase 2의 결과를 입력으로 받음
4. 작업 유형에 맞게 최적화 (코드, 문서, 조사, 기획 등 모두 가능)
5. exec_phase 3에는 반드시 품질/완성도 판단 에이전트를 포함

output_type:
- \"code\": 코드 작성이 주 목적
- \"document\": 문서/보고서/기획서 작성
- \"analysis\": 분석/조사 결과
- \"mixed\": 복합 산출물

필수 JSON 형식으로만 응답 (마크다운 코드블록 사용 가능):
{
  \"task\": \"작업명\",
  \"output_type\": \"code\",
  \"release_threshold\": 7.5,
  \"summary\": \"이 파이프라인이 어떻게 작업을 처리할지 2~3줄 설명\",
  \"agents\": [
    {
      \"id\": \"researcher\",
      \"name\": \"리서처\",
      \"role\": \"기술 조사 및 요구사항 분석\",
      \"exec_phase\": 1,
      \"focus\": \"유사 프로젝트 조사, 기술 스택 선정\",
      \"persona\": \"방대한 경험을 가진 기술 리서처\"
    }
  ]
}"

  PIPELINE_RAW=$(cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" --tools "Read,Glob,Grep" -p "$PIPELINE_PROMPT" 2>>"$LOG_DIR/generator.log")

  PIPELINE_JSON=$(echo "$PIPELINE_RAW" | extract_json)

  PIPELINE_VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print('ok' if len(d.get('agents', [])) >= 2 else 'fail')
except: print('fail')
" <<< "$PIPELINE_JSON" 2>/dev/null || echo "fail")

  if [ "$PIPELINE_VALID" != "ok" ]; then
    log_progress "⚠️ 파이프라인 JSON 파싱 실패 — 기본 파이프라인으로 폴백"
    PIPELINE_JSON="{
  \"task\": \"${TASK}\",
  \"output_type\": \"code\",
  \"release_threshold\": 7.5,
  \"summary\": \"기본 3단계 파이프라인: 조사 → 구현 → 검증\",
  \"agents\": [
    {\"id\":\"researcher\",\"name\":\"리서처\",\"role\":\"기술 조사 및 요구사항 분석\",\"exec_phase\":1,\"focus\":\"관련 기술, 패턴, 레퍼런스 수집\",\"persona\":\"경험 많은 시니어 엔지니어\"},
    {\"id\":\"developer\",\"name\":\"개발자\",\"role\":\"실제 구현\",\"exec_phase\":2,\"focus\":\"기능 구현, 코드 품질\",\"persona\":\"실용적인 풀스택 개발자\"},
    {\"id\":\"reviewer\",\"name\":\"리뷰어\",\"role\":\"품질 검증 및 릴리즈 판단\",\"exec_phase\":3,\"focus\":\"코드 품질, 완성도, 릴리즈 기준\",\"persona\":\"엄격한 시니어 코드 리뷰어\"}
  ]
}"
  fi

  echo "$PIPELINE_JSON" > "$SESSION_DIR/pipeline.json"

  # meta.json 업데이트
  python3 - << PYEOF
import json
with open('$SESSION_DIR/pipeline.json') as f: pd = json.load(f)
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['agents'] = [
    {
        'id': a['id'], 'name': a['name'], 'role': a.get('role',''),
        'exec_phase': a.get('exec_phase', 1), 'status': 'pending'
    }
    for a in pd.get('agents', [])
]
d['output_type'] = pd.get('output_type', 'code')
d['release_threshold'] = float(pd.get('release_threshold', 7.5))
d['pipeline_summary'] = pd.get('summary', '')
total_phases = max((a.get('exec_phase', 1) for a in pd.get('agents', [])), default=3)
d['total_phases'] = total_phases
d['status'] = 'pipeline-ready'
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF

  log_progress "✅ [generate] 파이프라인 생성 완료 (에이전트: $(get_agent_ids_for_phase 1) | $(get_agent_ids_for_phase 2) | $(get_agent_ids_for_phase 3))"
  exit 0
fi

# ============================================================
# 공통 파라미터 로드 (run / --continue)
# ============================================================
TASK=$(py_get task "")
PROJECT_DIR=$(py_get project_dir "$(pwd)")
RELEASE_THRESHOLD_VALUE=$(py_get release_threshold "$RELEASE_THRESHOLD_DEFAULT")
TOTAL_PHASES=$(py_get total_phases "3")
OUTPUT_TYPE=$(py_get output_type "code")

# ============================================================
# ============================================================
# MODE: --continue — 추가 작업 사이클
# ============================================================
# ============================================================
if [ "$MODE" = "--continue" ]; then
  CURRENT_STATUS=$(py_get status "unknown")
  if [ "$CURRENT_STATUS" != "completed" ]; then
    echo "❌ --continue는 completed 상태에서만 가능 (현재: $CURRENT_STATUS)" >&2; exit 1
  fi
  update_meta "d['status'] = 'running'; d['add_cycles'] = int(d.get('add_cycles', 0)) + int('${ADD_CYCLES}')"
  log_progress "🔧 [continue] 추가 작업 사이클 ${ADD_CYCLES}회"
fi

# ============================================================
# ============================================================
# MODE: run — 파이프라인 실행
# ============================================================
# ============================================================
if [ "$MODE" = "run" ]; then
  CURRENT_STATUS=$(py_get status "unknown")
  if [ "$CURRENT_STATUS" != "pipeline-ready" ]; then
    echo "❌ run은 pipeline-ready 상태에서만 가능 (현재: $CURRENT_STATUS)" >&2; exit 1
  fi

  for p in $(seq 1 "$TOTAL_PHASES"); do mkdir -p "$SESSION_DIR/phase-${p}"; done
  mkdir -p "$SESSION_DIR/rating"

  update_meta "d['status'] = 'running'; d['current_phase'] = 0"
  log_progress "🔧 [run] 작업 파이프라인 시작"
  log_progress "   작업: $TASK"
  log_progress "   프로젝트: $PROJECT_DIR"
  log_progress "   단계: ${TOTAL_PHASES}개 + 최종 평가"
  log_progress "   릴리즈 임계값: ${RELEASE_THRESHOLD_VALUE}/10"
fi

# ============================================================
# 파이프라인 실행 헬퍼
# ============================================================

# 단계 결과 수집 (다음 단계 에이전트에게 컨텍스트로 전달)
collect_phase_outputs() {
  local phase="$1" result=""
  IFS=' ' read -ra ids <<< "$(get_agent_ids_for_phase "$phase")"
  for id in "${ids[@]}"; do
    local name; name=$(get_agent_field "$id" "name")
    local content; content=$(head -400 "$SESSION_DIR/phase-${phase}/${id}.md" 2>/dev/null || echo "(없음)")
    result+="=== ${name} (${id}) ===\n${content}\n\n---\n\n"
  done
  printf '%s' "$result"
}

# 사용자 피드백 수집 + 마킹
get_pending_feedback() {
  local FEEDBACK_FILE="${SESSION_DIR}/user-feedback.json"
  [ -f "$FEEDBACK_FILE" ] || { echo ""; return; }
  python3 -c "
import json
try:
    with open('${FEEDBACK_FILE}') as f: data = json.load(f)
    pending = [fb for fb in data.get('feedbacks', []) if not fb.get('used', False)]
    if pending:
        lines = ['\n\n=== 사용자 지시사항 (반드시 반영) ===']
        for fb in pending: lines.append('- ' + fb['text'])
        for fb in data['feedbacks']:
            if not fb.get('used', False): fb['used'] = True
        with open('${FEEDBACK_FILE}', 'w') as f: json.dump(data, f, ensure_ascii=False, indent=2)
        print('\n'.join(lines))
except: pass
" 2>/dev/null
}

# ============================================================
# 헬퍼 함수: QA 피드백 수집
# ============================================================
collect_qa_feedback() {
  local feedback=""
  local last_phase="$TOTAL_PHASES"

  # 마지막 Phase(검증) 에이전트 출력 수집
  IFS=' ' read -ra qa_ids <<< "$(get_agent_ids_for_phase "$last_phase")"
  for id in "${qa_ids[@]}"; do
    local name; name=$(get_agent_field "$id" "name")
    local content; content=$(head -300 "$SESSION_DIR/phase-${last_phase}/${id}.md" 2>/dev/null || echo "(없음)")
    feedback+="=== ${name} 검증 결과 ===\n${content}\n\n---\n\n"
  done

  # Rating 보고서 추가
  local rating_report; rating_report=$(cat "$SESSION_DIR/rating/report.md" 2>/dev/null || echo "")
  if [ -n "$rating_report" ]; then
    feedback+="=== 품질 평가 보고서 ===\n${rating_report}"
  fi

  printf '%s' "$feedback"
}

# ============================================================
# 헬퍼 함수: 단일 Phase 실행 (qa_feedback 선택적 주입)
# ============================================================
run_single_phase() {
  local phase="$1"
  local qa_feedback="${2:-}"

  log_progress ""
  log_progress "=========================================="
  log_progress "[Phase ${phase}/${TOTAL_PHASES}]"
  log_progress "=========================================="
  mkdir -p "$SESSION_DIR/phase-${phase}"
  update_meta "d['current_phase'] = ${phase}"

  # 이전 단계 출력 컨텍스트
  local PREV_CONTEXT_SECTION=""
  if [ "$phase" -gt 1 ]; then
    local PREV_OUTPUTS; PREV_OUTPUTS=$(collect_phase_outputs $((phase-1)))
    if [ -n "$PREV_OUTPUTS" ]; then
      PREV_CONTEXT_SECTION="
=== 이전 단계 결과 (참고/활용 필수) ===
${PREV_OUTPUTS}"
    fi
  fi

  # QA 피드백 섹션 (교정 사이클에서만 주입)
  local QA_FEEDBACK_SECTION=""
  if [ -n "$qa_feedback" ]; then
    QA_FEEDBACK_SECTION="
=== QA 피드백 — 반드시 이 문제들을 해결하세요 ===
이전 검증/평가에서 다음 문제가 발견되었습니다. 이를 직접 수정하여 품질을 향상시키세요:
${qa_feedback}
==="
  fi

  IFS=' ' read -ra PHASE_AGENTS <<< "$(get_agent_ids_for_phase "$phase")"
  if [ "${#PHASE_AGENTS[@]}" -eq 0 ]; then
    log_progress "⚠️ Phase ${phase}에 에이전트 없음 — 스킵"
    return
  fi

  log_progress "[P${phase}] ${#PHASE_AGENTS[@]}명 병렬 실행..."

  for id in "${PHASE_AGENTS[@]}"; do
    local NAME; NAME=$(get_agent_field "$id" "name")
    local ROLE; ROLE=$(get_agent_field "$id" "role")
    local FOCUS; FOCUS=$(get_agent_field "$id" "focus")
    local PERSONA; PERSONA=$(get_agent_field "$id" "persona")

    # 기존 결과 있으면 개선 모드
    local EXISTING=""
    if [ -f "$SESSION_DIR/phase-${phase}/${id}.md" ] && \
       [ -s "$SESSION_DIR/phase-${phase}/${id}.md" ]; then
      EXISTING=$(cat "$SESSION_DIR/phase-${phase}/${id}.md" 2>/dev/null || echo "")
    fi

    local AGENT_PROMPT
    if [ -n "$EXISTING" ]; then
      AGENT_PROMPT="당신은 ${NAME}입니다.
페르소나: ${PERSONA}
역할: ${ROLE} | 핵심 작업: ${FOCUS}

한국어로 응답하세요. 페르소나 어조를 유지하세요.

작업: ${TASK}
프로젝트: ${PROJECT_DIR}
현재 단계: Phase ${phase}/${TOTAL_PHASES}

=== 나의 이전 작업 결과 ===
${EXISTING}
${PREV_CONTEXT_SECTION}
${QA_FEEDBACK_SECTION}
${FEEDBACK_SECTION}

이전 결과와 QA 피드백을 반영하여 다음을 수행하세요:
1. QA 피드백에서 지적된 문제를 직접 코드/파일을 재확인하여 수정하세요
2. Read/Glob/Grep/WebSearch로 검증이 필요한 부분을 실제 확인하세요
3. 개선된 전체 결과물을 다시 작성하세요 (부분 패치가 아닌 완성된 버전)

## ${NAME} 개선된 작업 결과

### QA 피드백 반영 내용
(지적된 각 문제에 대해 무엇을 어떻게 수정했는지)

### 주요 발견 / 산출물

### 품질 검증 결과

### 다음 단계 권장사항"
    else
      AGENT_PROMPT="당신은 ${NAME}입니다.
페르소나: ${PERSONA}
역할: ${ROLE} | 핵심 작업: ${FOCUS}

한국어로 응답하세요. 페르소나 어조를 유지하세요.

작업: ${TASK}
프로젝트: ${PROJECT_DIR}
현재 단계: Phase ${phase}/${TOTAL_PHASES}
${PREV_CONTEXT_SECTION}
${QA_FEEDBACK_SECTION}
${FEEDBACK_SECTION}

작업 지침:
1. Read/Glob/Grep으로 프로젝트를 직접 탐색하세요 (코드, 설정, 문서 모두 확인)
2. WebSearch로 필요한 정보를 조사하세요 (출처 URL 포함)
3. 막연한 제안이 아닌 검증된 사실과 실제 코드/데이터에 기반해 작성하세요
4. 역할의 핵심 작업(${FOCUS})에 집중하여 깊이 있는 결과물을 작성하세요

## ${NAME} 작업 결과 (Phase ${phase})

### 수행한 조사 및 분석
(실제 확인한 파일, 코드, 데이터, 외부 자료 — 근거 포함)

### 주요 발견 / 산출물
(구체적 내용 — 파일 경로, 코드 예시, 수치 등 포함)

### 검증 및 근거
(주장을 뒷받침하는 실제 증거)

### 다음 단계 권장사항
(다음 Phase 에이전트가 활용할 수 있는 구체적 인사이트)"
    fi

    run_task_agent "$id" "$phase" "$AGENT_PROMPT" &
  done
  wait

  log_progress "[P${phase}] 완료"
}

# ============================================================
# 헬퍼 함수: 품질 평가 (QUALITY_SCORE, RELEASE_READY 전역 변수 설정)
# ============================================================
run_rating_cycle() {
  local cycle_label="${1:-초기}"

  log_progress ""
  log_progress "=========================================="
  log_progress "[Rating:${cycle_label}] 품질 평가 + 릴리즈 판정"
  log_progress "=========================================="
  mkdir -p "$SESSION_DIR/rating"
  update_meta "d['status'] = 'rating'"

  # 전체 결과물 수집
  local ALL_OUTPUTS=""
  for p in $(seq 1 "$TOTAL_PHASES"); do
    ALL_OUTPUTS+="## ── Phase ${p} 결과 ──\n\n"
    IFS=' ' read -ra ids <<< "$(get_agent_ids_for_phase "$p")"
    for id in "${ids[@]}"; do
      local n; n=$(get_agent_field "$id" "name")
      local c; c=$(head -400 "$SESSION_DIR/phase-${p}/${id}.md" 2>/dev/null || echo "(없음)")
      ALL_OUTPUTS+="### ${n}:\n${c}\n\n"
    done
  done

  local RATING_PROMPT="당신은 작업 품질 평가 전문가입니다. 한국어로 응답하세요.

작업: ${TASK}
산출물 유형: ${OUTPUT_TYPE}
릴리즈(완료) 임계값: ${RELEASE_THRESHOLD_VALUE}/10

=== 전체 작업 결과 ===
$(printf '%b' "$ALL_OUTPUTS")

이 결과물을 평가하고 릴리즈(완료) 가능 여부를 판정하세요.
overall_score >= ${RELEASE_THRESHOLD_VALUE} 이면 release_ready: true

반드시 다음 JSON 형식으로만 응답 (마크다운 코드블록 사용 가능):
{
  \"overall_score\": 8.2,
  \"release_ready\": true,
  \"breakdown\": {
    \"completeness\": 8,
    \"quality\": 8,
    \"correctness\": 9,
    \"maintainability\": 8
  },
  \"strengths\": [\"완성도 높은 구현\", \"명확한 구조\"],
  \"issues\": [\"테스트 커버리지 일부 부족\"],
  \"recommendation\": \"릴리즈 가능. 사소한 개선 권장.\",
  \"next_steps\": [\"단위 테스트 보완\"]
}"

  local RATING_RAW; RATING_RAW=$(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$RATING_PROMPT" 2>>"$LOG_DIR/rater.log")
  local RATING_JSON; RATING_JSON=$(echo "$RATING_RAW" | extract_json)

  local RATING_VALID; RATING_VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print('ok' if 'overall_score' in d else 'fail')
except: print('fail')
" <<< "$RATING_JSON" 2>/dev/null || echo "fail")

  [ "$RATING_VALID" != "ok" ] && \
    RATING_JSON="{\"overall_score\":5.0,\"release_ready\":false,\"breakdown\":{},\"strengths\":[],\"issues\":[\"평가 실패\"],\"recommendation\":\"수동 검토 필요\",\"next_steps\":[]}"

  echo "$RATING_JSON" > "$SESSION_DIR/rating/score.json"
  # 사이클별 스냅샷 보존
  cp "$SESSION_DIR/rating/score.json" \
     "$SESSION_DIR/rating/score-${cycle_label}.json" 2>/dev/null || true

  # 평가 보고서 생성
  python3 - << PYEOF
import json
with open('$SESSION_DIR/rating/score.json') as f: d = json.load(f)
score = d.get('overall_score', 0)
ready = d.get('release_ready', False)
threshold = float('$RELEASE_THRESHOLD_VALUE')
lines = [f"# 품질 평가 보고서 (${cycle_label})\n\n"]
lines.append(f"## 종합 점수: **{score}/10** &nbsp; {'✅ 릴리즈 가능' if ready else '❌ 추가 작업 필요'}\n\n")
lines.append(f"> {d.get('recommendation', '')}\n\n")
lines.append(f"릴리즈 기준: {threshold}/10 이상\n\n")
b = d.get('breakdown', {})
if b:
    lines.append('## 세부 평가\n\n| 항목 | 점수 |\n|------|------|\n')
    for k, v in b.items(): lines.append(f'| {k} | {v}/10 |\n')
    lines.append('\n')
if d.get('strengths'):
    lines.append('## 강점\n\n' + '\n'.join(f'- {s}' for s in d['strengths']) + '\n\n')
if d.get('issues'):
    lines.append('## 개선 필요\n\n' + '\n'.join(f'- {i}' for i in d['issues']) + '\n\n')
if d.get('next_steps'):
    lines.append('## 다음 단계\n\n' + '\n'.join(f'- {s}' for s in d['next_steps']) + '\n')
with open('$SESSION_DIR/rating/report.md', 'w') as f: f.writelines(lines)
PYEOF

  # 전역 변수 설정
  QUALITY_SCORE=$(python3 -c "
import json
with open('$SESSION_DIR/rating/score.json') as f: d = json.load(f)
print(d.get('overall_score', 0))
" 2>/dev/null || echo "0")

  RELEASE_READY=$(python3 -c "
import json
with open('$SESSION_DIR/rating/score.json') as f: d = json.load(f)
print('true' if d.get('release_ready', False) else 'false')
" 2>/dev/null || echo "false")

  log_progress "[Rating:${cycle_label}] 점수: ${QUALITY_SCORE}/10 | 릴리즈: ${RELEASE_READY}"
}

# ============================================================
# PHASE 실행 루프 — 초기 실행
# ============================================================
FEEDBACK_SECTION=$(get_pending_feedback)

for phase in $(seq 1 "$TOTAL_PHASES"); do
  run_single_phase "$phase" ""
done

# ============================================================
# 초기 평가
# ============================================================
run_rating_cycle "초기"

# ============================================================
# 교정 사이클 — QA 피드백 기반 자동 재실행
# Phase 2 이상을 재실행하여 QA가 발견한 문제를 수정
# ============================================================
MAX_CORRECTION_CYCLES=$(py_get max_correction_cycles "2")
CORRECTION_CYCLE=0

while [ "$RELEASE_READY" != "true" ] && \
      [ "$CORRECTION_CYCLE" -lt "$MAX_CORRECTION_CYCLES" ]; do

  CORRECTION_CYCLE=$((CORRECTION_CYCLE + 1))
  log_progress ""
  log_progress "=========================================="
  log_progress "🔄 [교정 사이클 ${CORRECTION_CYCLE}/${MAX_CORRECTION_CYCLES}]"
  log_progress "   현재 점수: ${QUALITY_SCORE}/10 → Phase 2 재실행"
  log_progress "=========================================="
  update_meta "d['status'] = 'correcting'; d['correction_cycle'] = ${CORRECTION_CYCLE}"

  # QA(마지막 Phase) + Rating 피드백 수집
  QA_FEEDBACK=$(collect_qa_feedback)

  # 사용자 추가 피드백 반영
  FEEDBACK_SECTION=$(get_pending_feedback)

  # Phase 2 이상 재실행 (Phase 1 조사/계획은 유지)
  for phase in $(seq 2 "$TOTAL_PHASES"); do
    run_single_phase "$phase" "$QA_FEEDBACK"
  done

  # 재평가
  run_rating_cycle "교정-${CORRECTION_CYCLE}"

done

if [ "$CORRECTION_CYCLE" -gt 0 ]; then
  if [ "$RELEASE_READY" = "true" ]; then
    log_progress "✅ 교정 사이클 ${CORRECTION_CYCLE}회 후 품질 기준 달성"
  else
    log_progress "⚠️ 교정 사이클 ${MAX_CORRECTION_CYCLES}회 완료. 최종 점수: ${QUALITY_SCORE}/10"
  fi
fi

# ============================================================
# 최종 종합 보고서
# ============================================================
log_progress "[최종] 종합 보고서 작성 중..."

AGENTS_SUMMARY=""
for phase in $(seq 1 "$TOTAL_PHASES"); do
  IFS=' ' read -ra ids <<< "$(get_agent_ids_for_phase "$phase")"
  for id in "${ids[@]}"; do
    NAME=$(get_agent_field "$id" "name")
    ROLE=$(get_agent_field "$id" "role")
    content=$(head -300 "$SESSION_DIR/phase-${phase}/${id}.md" 2>/dev/null || echo "(없음)")
    AGENTS_SUMMARY+="=== Phase ${phase}: ${NAME} (${ROLE}) ===\n${content}\n\n"
  done
done

RATING_REPORT=$(cat "$SESSION_DIR/rating/report.md" 2>/dev/null || echo "(없음)")
CORRECTION_NOTE=""
[ "$CORRECTION_CYCLE" -gt 0 ] && \
  CORRECTION_NOTE="교정 사이클: ${CORRECTION_CYCLE}회 실행 후 최종 점수 ${QUALITY_SCORE}/10 달성"

SYNTHESIS_PROMPT="[TASK: STRUCTURED DOCUMENT GENERATION]
한국어로 작성하세요. 마크다운 문서만 출력하세요.
도구 호출, 대화체, '다음에 진행하시겠습니까' 등 표현 금지.

작업: ${TASK}
품질 점수: ${QUALITY_SCORE}/10
릴리즈 가능: ${RELEASE_READY}
${CORRECTION_NOTE}

=== 에이전트 작업 결과 요약 ===
$(printf '%b' "$AGENTS_SUMMARY")

=== 품질 평가 보고서 ===
${RATING_REPORT}

아래 형식으로 최종 보고서를 작성하세요:

# 작업 완료 보고서

## 작업: [작업명]
## 최종 점수: [점수]/10 — [릴리즈 가능 / 추가 작업 필요]

## 수행된 작업 요약
단계별 주요 결과물과 성과 (3~5줄)

## 주요 산출물
생성된 파일, 코드, 문서 등 구체적 목록

## 품질 평가 요약
강점과 개선 필요 사항

## 릴리즈 판정
- **결정**: [릴리즈 가능 / 조건부 릴리즈 / 추가 작업 필요]
- **이유**: 구체적 이유
- **다음 단계**: 우선순위 순 액션 리스트"

(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  "$CLAUDE_BIN" --allowedTools "" -p "$SYNTHESIS_PROMPT") \
  > "$SESSION_DIR/conclusion.md" 2>>"$LOG_DIR/synthesis.log"

# 훅 아티팩트 제거
python3 - << 'PYEOF'
import re, os
path = os.environ.get('SESSION_DIR', '') + '/conclusion.md'
try:
    with open(path) as f: text = f.read()
    for pattern in [r'\n메모리 저장 완료됐습니다', r'\n✅ 메모리', r'\[DONE\]']:
        m = re.search(pattern, text)
        if m: text = text[:m.start()].rstrip()
    with open(path, 'w') as f: f.write(text)
except: pass
PYEOF

# meta.json 최종 업데이트
python3 - << PYEOF
import json, datetime
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['status'] = 'completed'
d['quality_score'] = float('$QUALITY_SCORE')
d['release_ready'] = ('$RELEASE_READY' == 'true')
d['correction_cycles_used'] = int('$CORRECTION_CYCLE')
d['completed_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
for a in d.get('agents', []): a['status'] = 'done'
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
PYEOF

# SUMMARY.md 자동 생성 — 한 눈에 세션 전체 훑기용
python3 - <<PYEOF 2>/dev/null || true
import json, os, glob
session_dir = "$SESSION_DIR"
try:
    meta = json.load(open(os.path.join(session_dir, "meta.json")))
except Exception:
    meta = {}
topic = meta.get("topic", "(unknown)")
phases = int(meta.get("total_phases", 0) or 0)
agents = [a.get("name", a.get("id", "?")) for a in meta.get("agents", [])]
lines = [
    "# Session Summary — Task",
    "",
    f"- **세션 ID**: $SESSION_ID",
    f"- **토픽**: {topic}",
    f"- **Phase 수**: {phases}",
    f"- **품질 점수**: {meta.get('quality_score', '?')}/10",
    f"- **릴리즈 가능**: {'예' if meta.get('release_ready') else '아니오'}",
    f"- **참여자**: {', '.join(agents) if agents else '(없음)'}",
    "",
    "## 결론",
    "",
]
try:
    with open(os.path.join(session_dir, "conclusion.md")) as f:
        lines.append(f.read().strip())
except Exception:
    lines.append("(없음)")
lines += ["", "## Phase별 산출물", ""]
for p in range(1, phases + 1):
    pdir = os.path.join(session_dir, f"phase-{p}")
    if not os.path.isdir(pdir):
        continue
    lines.append(f"### Phase {p}")
    for md in sorted(glob.glob(os.path.join(pdir, "*.md"))):
        lines.append(f"- [{os.path.basename(md)}](phase-{p}/{os.path.basename(md)})")
    lines.append("")
rating_report = os.path.join(session_dir, "rating", "report.md")
if os.path.exists(rating_report):
    lines += ["## 평가 리포트", ""]
    try:
        with open(rating_report) as f:
            lines.append(f.read().strip())
    except Exception:
        pass
with open(os.path.join(session_dir, "SUMMARY.md"), "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

# sessions/tasks/latest 심링크 갱신
ln -sfn "$SESSION_ID" "${TASK_SESSIONS_BASE}/latest" 2>/dev/null || true

log_progress ""
log_progress "🏴‍☠️ 작업 파이프라인 완료!"
log_progress "   요약: $SESSION_DIR/SUMMARY.md"
if [ "$RELEASE_READY" = "true" ]; then
  log_progress "   ✅ 릴리즈 가능! 점수: ${QUALITY_SCORE}/10"
else
  log_progress "   ⚠️  추가 작업 필요. 점수: ${QUALITY_SCORE}/10 (기준: ${RELEASE_THRESHOLD_VALUE})"
fi
[ "$CORRECTION_CYCLE" -gt 0 ] && log_progress "   🔄 교정 사이클: ${CORRECTION_CYCLE}회"
log_progress "   결과: $SESSION_DIR/conclusion.md"
log_progress "   세션: $SESSION_ID"
