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
AGENT_COUNT=$(py_get agent_count "5")
TOTAL_ROUNDS=$(py_get rounds "2")

# ============================================================
# 디렉토리 & 환경
# ============================================================
mkdir -p "$LOG_DIR"

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

  echo "[$(date +%H:%M:%S)] [R${round}] ${id} 시작..." >> "$log"
  update_agent_status "$id" "running"

  if (cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
      "$CLAUDE_BIN" -p "$prompt") > "$output" 2>> "$log"; then
    update_agent_status "$id" "done"
    echo "[$(date +%H:%M:%S)] [R${round}] ${id} 완료 ✓" >> "$log"
  else
    update_agent_status "$id" "error"
    echo "[$(date +%H:%M:%S)] [R${round}] ${id} 실패" >> "$log"
    echo "*(에이전트 분석 실패)*" >> "$output"
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

  AGENT_GEN_PROMPT="당신은 소프트웨어 아키텍처 전문가입니다. 한국어로 응답하세요.

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

반드시 다음 JSON 형식으로 응답하세요 (마크다운 코드블록 사용 가능):
{
  \"language\": \"Flutter/Dart\",
  \"framework\": \"Flutter 3.x + Riverpod\",
  \"detected_issues\": [\"상태관리 불일치\", \"테스트 부재\"],
  \"agents\": [
    {
      \"id\": \"arch_reviewer\",
      \"name\": \"아키텍처 전문가\",
      \"role\": \"클린 아키텍처 및 SOLID 원칙 검토\",
      \"expertise\": [\"Clean Architecture\", \"SOLID 원칙\", \"레이어 분리\", \"DI\"],
      \"focus\": \"도메인/프레젠테이션 레이어 분리, 의존성 방향, 관심사 분리\",
      \"persona\": \"10년 경력의 Flutter 아키텍처 전문가로, 코드의 구조적 건강성을 최우선으로 판단\"
    }
  ]
}"

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
    {"id":"code_quality","name":"코드 품질 전문가","role":"전반적 코드 품질","expertise":["가독성","유지보수성","SOLID"],"focus":"코드 구조, 중복, 네이밍","persona":"엄격한 코드 품질 기준을 가진 시니어 개발자"},
    {"id":"security","name":"보안 전문가","role":"보안 취약점","expertise":["인증","인가","입력 검증"],"focus":"취약점, 데이터 노출","persona":"보안 감사 경험이 많은 화이트햇 엔지니어"},
    {"id":"performance","name":"성능 전문가","role":"성능 최적화","expertise":["메모리","CPU","네트워크"],"focus":"병목, 비효율 패턴","persona":"프로파일링과 최적화에 집착하는 퍼포먼스 엔지니어"},
    {"id":"testing","name":"테스트 전문가","role":"테스트 커버리지","expertise":["단위 테스트","통합 테스트","TDD"],"focus":"커버리지, 격리, 모킹","persona":"TDD 신봉자이자 QA 전문가"},
    {"id":"arch","name":"아키텍처 전문가","role":"시스템 구조","expertise":["아키텍처","DI","레이어 분리"],"focus":"의존성, 결합도","persona":"대규모 시스템 설계 경험을 가진 아키텍트"}
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
  if [ "$CURRENT_STATUS" != "completed" ]; then
    echo "❌ --continue는 completed 상태에서만 가능 (현재: $CURRENT_STATUS)" >&2; exit 1
  fi

  LAST_DONE=0
  for r in $(seq 1 9); do
    if ls "$SESSION_DIR/round-${r}/"*.md 2>/dev/null | head -1 | grep -q .; then
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

  # ----------------------------------------------------------
  # 2a. 에이전트 병렬 분석
  # ----------------------------------------------------------
  log_progress "[R${round}] 에이전트 병렬 분석 시작 (${AGENT_COUNT_ACTUAL}명)..."

  for id in "${CR_AGENT_IDS[@]}"; do
    NAME=$(get_agent_field "$id" "name")
    ROLE=$(get_agent_field "$id" "role")
    EXPERTISE=$(get_agent_field "$id" "expertise")
    FOCUS=$(get_agent_field "$id" "focus")
    PERSONA=$(get_agent_field "$id" "persona")

    PREV_CONTEXT=""
    if [ "$round" -gt 1 ]; then
      prev=$((round - 1))
      MY_PREV=$(head -80 "$SESSION_DIR/round-${prev}/${id}.md" 2>/dev/null || echo "(없음)")
      PREV_APPLIED=$(head -80 "$SESSION_DIR/round-${prev}/apply-changes.md" 2>/dev/null || echo "(없음)")
      PREV_REVIEW=$(head -60 "$SESSION_DIR/round-${prev}/code-reviewer.md" 2>/dev/null || echo "(없음)")
      PREV_CONTEXT="
=== Round ${prev} 적용된 변경사항 ===
${PREV_APPLIED}

=== Round ${prev} 코드 리뷰어 피드백 ===
${PREV_REVIEW}

=== 나(${NAME})의 Round ${prev} 의견 ===
${MY_PREV}

---
위 내용을 반영하여 새로운 관점에서 재분석하세요."
    fi

    REVIEW_PROMPT="당신은 ${NAME}입니다.
페르소나: ${PERSONA}
전문 역할: ${ROLE}
핵심 역량: ${EXPERTISE}
검토 포인트: ${FOCUS}

한국어로 응답하세요. 페르소나에 맞는 어조와 관점을 유지하세요.

프로젝트: ${PROJECT_DIR}
리뷰 목표: ${TOPIC}
언어/프레임워크: ${LANGUAGE}
현재 라운드: ${round}/${TOTAL_ROUNDS}
${PREV_CONTEXT}

작업:
1. Read/Glob/Grep으로 프로젝트 코드를 실제 분석하세요
2. ${FOCUS} 관점에서 문제점과 개선사항 파악
3. 구체적인 파일 경로와 코드 수정 방안 제시

다음 형식으로 응답하세요:

## ${NAME} 코드 분석 (Round ${round})

### 발견된 이슈
각 이슈별로:
**[이슈-N]** 제목
- 위치: 파일경로 (라인번호 가능하면 포함)
- 심각도: critical / high / medium / low
- 문제: 무엇이 문제인지
- 수정 방안: 구체적인 접근법 또는 코드 예시

### 즉시 수정 필요 (critical / high)
우선순위 상위 이슈 최대 3개:
1. 파일: ...  /  변경: ...

### 전체 코드 평가
- 품질 점수: X/10
- 릴리즈 가능: 가능 / 조건부 / 불가능
- 주요 우려사항:"

    run_cr_agent "$id" "$round" "$REVIEW_PROMPT" &
  done
  wait
  log_progress "[R${round}] 에이전트 분석 완료"

  # ----------------------------------------------------------
  # 2b. 투표 집계
  # ----------------------------------------------------------
  log_progress "[R${round}] 투표 집계 중..."

  ALL_REVIEWS=""
  for id in "${CR_AGENT_IDS[@]}"; do
    NAME=$(get_agent_field "$id" "name")
    content=$(head -200 "$SESSION_DIR/round-${round}/${id}.md" 2>/dev/null || echo "(없음)")
    ALL_REVIEWS+="=== ${NAME} ===
${content}

---

"
  done

  VOTE_PROMPT="당신은 코드 리뷰 투표 집계 전문가입니다. 한국어로 응답하세요.

총 에이전트: ${AGENT_COUNT_ACTUAL}명 | 과반수 기준: ${MAJORITY}명 이상

=== 에이전트 리뷰 결과 ===
${ALL_REVIEWS}

${AGENT_COUNT_ACTUAL}개 리뷰에서:
1. 같은 또는 유사한 이슈를 언급한 에이전트 수를 집계하세요
2. ${MAJORITY}명 이상 동의한 변경사항을 채택 목록에 포함하세요
3. 미달인 것은 기각 목록에 포함하세요

다음 JSON 형식으로만 응답하세요 (마크다운 코드블록 사용 가능):
{
  \"total_agents\": ${AGENT_COUNT_ACTUAL},
  \"majority_threshold\": ${MAJORITY},
  \"agreed_changes\": [
    {
      \"id\": \"change-1\",
      \"title\": \"변경 제목\",
      \"file\": \"lib/main.dart\",
      \"description\": \"구체적인 변경 내용\",
      \"reason\": \"왜 필요한가\",
      \"votes\": 4,
      \"severity\": \"high\",
      \"supporters\": [\"에이전트명1\", \"에이전트명2\"]
    }
  ],
  \"rejected_changes\": [
    {\"title\": \"기각된 변경\", \"votes\": 1, \"reason\": \"과반수 미달\"}
  ],
  \"overall_quality_score\": 6.5,
  \"release_ready\": false,
  \"summary\": \"이번 라운드 핵심 발견사항 요약\"
}"

  VOTE_RAW=$(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$VOTE_PROMPT" 2>>"$LOG_DIR/${LOG_PREFIX}-voter.log")
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
    lines.append(f"- 파일: `{c.get('file','?')}`\n- 찬성: {c.get('votes',0)}표\n- 설명: {c.get('description','')}\n\n")
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
  # 2e. 수렴 확인
  # ----------------------------------------------------------
  log_progress "[R${round}] 수렴 확인 중..."

  ALL_OPINIONS=""
  for id in "${CR_AGENT_IDS[@]}"; do
    NAME=$(get_agent_field "$id" "name")
    tail_content=$(tail -20 "$SESSION_DIR/round-${round}/${id}.md" 2>/dev/null || echo "(없음)")
    ALL_OPINIONS+="${NAME}: ${tail_content}
---
"
  done

  REVIEWER_TAIL=$(tail -40 "$SESSION_DIR/round-${round}/code-reviewer.md" 2>/dev/null || echo "(없음)")
  VOTES_BRIEF=$(python3 -c "
import json
with open('$SESSION_DIR/round-${round}/votes.json') as f: d = json.load(f)
print(f'품질 {d.get(\"overall_quality_score\",0)}/10, 릴리즈={d.get(\"release_ready\",False)}, 채택={len(d.get(\"agreed_changes\",[]))}')
" 2>/dev/null || echo "")

  CONVERGENCE_PROMPT="당신은 코드 리뷰 수렴 판정자입니다. 한국어로 응답하세요.

현재 라운드: ${round}/${TOTAL_ROUNDS}
${VOTES_BRIEF}

에이전트 최종 의견:
${ALL_OPINIONS}

코드 리뷰어:
${REVIEWER_TAIL}

판정 기준:
- 수렴(true): 모든 에이전트가 critical/high 이슈 없음 + 릴리즈 가능
- 비수렴(false): 한 명 이상이 중요 미해결 이슈 제기

JSON으로만 응답:
{
  \"converged\": false,
  \"convergence_rate\": 0.6,
  \"release_ready\": false,
  \"quality_score\": 7.0,
  \"remaining_critical_issues\": [\"이슈1\"],
  \"consensus_summary\": \"2~3문장 요약\"
}"

  CONV_RAW=$(CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$CONVERGENCE_PROMPT" 2>>"$LOG_DIR/${LOG_PREFIX}-convergence.log")
  CONV_JSON=$(echo "$CONV_RAW" | extract_json)
  [ "$CONV_JSON" = "{}" ] && CONV_JSON="{\"converged\":false,\"convergence_rate\":0,\"release_ready\":false,\"quality_score\":5,\"remaining_critical_issues\":[],\"consensus_summary\":\"수렴 확인 실패\"}"

  echo "$CONV_JSON" > "$SESSION_DIR/round-${round}/convergence.json"

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
