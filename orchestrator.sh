#!/bin/bash
# Round Table — Claude 멀티 세션 토론 오케스트레이터
# Usage:
#   신규: ./orchestrator.sh "토픽" [라운드수] [에이전트목록] [프로젝트디렉토리]
#   계속: ./orchestrator.sh --continue SESSION_ID [추가라운드수]
#
# 에이전트: analyst, developer, critic, designer, financial, strategist
# 예: ./orchestrator.sh "AI 추가 여부" 3 "analyst,developer,critic,financial"
# 계속: ./orchestrator.sh --continue 20260324_112143 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

# ============================================================
# === 모드 감지: 신규 vs 계속 ===
# ============================================================
CONTINUE_MODE=false

if [ "$1" = "--continue" ]; then
  CONTINUE_MODE=true
  SESSION_ID="${2:?Usage: ./orchestrator.sh --continue SESSION_ID [additional_rounds]}"
  ADD_ROUNDS="${3:-2}"
  SESSION_DIR="${SCRIPT_DIR}/sessions/${SESSION_ID}"

  if [ ! -f "${SESSION_DIR}/meta.json" ]; then
    echo "❌ 세션 없음: ${SESSION_ID}" >&2; exit 1
  fi
  if ! [[ "$ADD_ROUNDS" =~ ^[1-9]$ ]]; then
    echo "❌ 추가 라운드 수는 1~9 사이여야 합니다 (입력: $ADD_ROUNDS)" >&2; exit 1
  fi

  TOPIC=$(python3 -c "import json; print(json.load(open('${SESSION_DIR}/meta.json')).get('topic',''))" 2>/dev/null)
  AGENTS_ARG=$(python3 -c "import json; print(json.load(open('${SESSION_DIR}/meta.json')).get('agents_config','analyst,developer,critic'))" 2>/dev/null)
  PROJECT_DIR=$(python3 -c "import json; print(json.load(open('${SESSION_DIR}/meta.json')).get('project_dir','.'))" 2>/dev/null)

  # 실제 완료된 마지막 라운드 탐색
  LAST_DONE=0
  for r in $(seq 1 9); do
    if ls "${SESSION_DIR}/round-${r}/"*.md 2>/dev/null | head -1 | grep -q .; then
      LAST_DONE=$r
    fi
  done
  if [ "$LAST_DONE" -eq 0 ]; then
    echo "❌ 완료된 라운드가 없습니다." >&2; exit 1
  fi

  START_DEBATE_ROUND=$((LAST_DONE + 1))
  TOTAL_ROUNDS=$((LAST_DONE + ADD_ROUNDS))
  TIMESTAMP="${SESSION_ID}"

else
  TOPIC="${1:?Usage: ./orchestrator.sh \"토픽\" [rounds] [agents] [project_dir]}"
  ROUNDS="${2:-2}"
  AGENTS_ARG="${3:-analyst,developer,critic}"
  PROJECT_DIR="${4:-$(pwd)}"
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  SESSION_DIR="${SCRIPT_DIR}/sessions/${TIMESTAMP}"
  START_DEBATE_ROUND=2
  TOTAL_ROUNDS=$ROUNDS

  if ! [[ "$ROUNDS" =~ ^[1-9]$ ]]; then
    echo "❌ 라운드 수는 1~9 사이여야 합니다 (입력: $ROUNDS)" >&2
    exit 1
  fi
fi

# Create directories
mkdir -p "$LOG_DIR"
if [ "$CONTINUE_MODE" = true ]; then
  for r in $(seq "$START_DEBATE_ROUND" "$TOTAL_ROUNDS"); do mkdir -p "$SESSION_DIR/round-$r"; done
else
  for r in $(seq 1 "$TOTAL_ROUNDS"); do mkdir -p "$SESSION_DIR/round-$r"; done
fi
mkdir -p "$SESSION_DIR/final"

# === 환경변수 로딩 (.env 파일 지원) ===
SCRIPT_ENV="${SCRIPT_DIR}/.env"
if [ -f "$SCRIPT_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$SCRIPT_ENV"
  set +a
fi

# === Claude CLI 설정 ===
CLAUDE_BIN="${CLAUDE_BIN:-$(which claude 2>/dev/null)}"
if [ ! -x "$CLAUDE_BIN" ]; then
  # 일반적인 설치 경로 탐색
  for candidate in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
    if [ -x "$candidate" ]; then CLAUDE_BIN="$candidate"; break; fi
  done
fi
if [ ! -x "$CLAUDE_BIN" ]; then
  echo "❌ claude CLI를 찾을 수 없습니다."
  echo "   설치: https://docs.anthropic.com/claude-code"
  echo "   또는 CLAUDE_BIN 환경변수로 경로를 지정하세요." >&2
  exit 1
fi

# Token: env var > shell rc files
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(grep "CLAUDE_CODE_OAUTH_TOKEN" ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null \
    | tail -1 | sed "s/.*CLAUDE_CODE_OAUTH_TOKEN=//;s/['\"]//g;s/export //g" | xargs)
fi
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "❌ CLAUDE_CODE_OAUTH_TOKEN이 설정되지 않았습니다."
  echo "   .env 파일에 추가하거나 환경변수로 export하세요."
  echo "   토큰 확인: claude auth status" >&2
  exit 1
fi

# Parse agents (comma-separated → array)
IFS=',' read -ra SELECTED_AGENTS <<< "$AGENTS_ARG"

# ============================================================
# === Agent 정의 (bash 3.2 호환 — declare -A 미사용)
# ============================================================

get_agent_name() {
  case "$1" in
    analyst)    echo "시장 분석가" ;;
    developer)  echo "기술 리드" ;;
    critic)     echo "악마의 변호인" ;;
    designer)   echo "UX 디자이너" ;;
    financial)  echo "재무 분석가" ;;
    strategist) echo "장기 전략가" ;;
    *)          echo "$1" ;;
  esac
}

get_agent_prompt_r1() {
  local id="$1" topic="$2" proj="$3"
  case "$id" in
    analyst)
      printf '%s\n' "당신은 시장 분석가입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" "다음을 수행하세요:" \
        "- WebSearch로 관련 시장 데이터, 경쟁사 동향 조사 (출처 URL 필수 포함)" \
        "- 시장 규모와 성장률을 구체적 숫자로 제시" \
        "- 기회와 위협 요인 각 3개 이상" \
        "- 경쟁사 대비 차별화 가능성 평가" \
        "- 3~5개의 핵심 인사이트 도출"
      ;;
    developer)
      printf '%s\n' "당신은 기술 리드입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" "다음을 수행하세요:" \
        "- 프로젝트 디렉토리의 코드베이스를 Read/Glob/Grep으로 실제 확인" \
        "- 기술적 실현 가능성 평가 (구체적 파일명, 코드 위치 포함)" \
        "- 예상 개발 기간과 복잡도 추정" \
        "- 기술 부채 및 아키텍처 리스크" \
        "- 현재 스택과의 정합성 평가"
      ;;
    critic)
      printf '%s\n' "당신은 악마의 변호인입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" "다음을 수행하세요:" \
        "- 이것을 하지 말아야 하는 이유 5가지 (각각 구체적 근거 포함)" \
        "- 낙관적 가정의 허점 파헤치기" \
        "- 숨겨진 비용과 기회비용 분석" \
        "- 실패 시나리오 구체적으로 묘사" \
        "- 더 나은 대안 제시 (최소 2가지)"
      ;;
    designer)
      printf '%s\n' "당신은 UX/제품 디자이너입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" "다음을 수행하세요:" \
        "- 사용자 관점에서 핵심 플로우와 이탈 포인트 분석" \
        "- WebSearch로 경쟁 앱의 UX 패턴 조사" \
        "- 온보딩 경험 설계 제안" \
        "- 모바일 UX 원칙 기반 개선안 (구체적 화면 설명)" \
        "- 접근성과 다국어 지원 고려사항"
      ;;
    financial)
      printf '%s\n' "당신은 재무 분석가입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" "다음을 수행하세요:" \
        "- 초기 개발 비용 (인건비 포함) 구체적 숫자 추정" \
        "- 월간 운영 비용 (서버, API, 마케팅) 상세 내역" \
        "- 수익 예측 (비관/기본/낙관 시나리오, 12개월)" \
        "- ROI와 손익분기점 계산" \
        "- 현금흐름 리스크와 재무적 지속가능성 평가"
      ;;
    strategist)
      printf '%s\n' "당신은 장기 전략가입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" "다음을 수행하세요:" \
        "- 6개월/1년/2년 후 시장 포지셔닝 로드맵" \
        "- 경쟁 우위와 방어 가능성 (모방 난이도)" \
        "- 네트워크 효과 및 데이터 축적 가능성" \
        "- 전체 포트폴리오 전략에 미치는 영향" \
        "- 전략적 옵션 가치 (피벗 가능성, 인수합병 가능성)"
      ;;
    *)
      printf '%s\n' "당신은 ${id} 전문가입니다. 한국어로 응답하세요." \
        "" "토픽: ${topic}" "프로젝트: ${proj}" "" \
        "전문가 관점에서 핵심 인사이트를 분석하세요."
      ;;
  esac
}

DEBATE_PROMPT_BASE="당신은 {AGENT_NAME}입니다. 한국어로 응답하세요.

토픽: {TOPIC}

=== Round {PREV_ROUND} 다른 전문가들의 의견 ===
{PREV_OUTPUTS}

위 의견들을 읽고 다음을 작성하세요:

### 동의하는 포인트 (이유 포함)
각 전문가의 의견 중 수용할 근거가 있는 포인트를 구체적으로 언급하세요.

### 반박하는 포인트 (구체적 반론)
동의하지 않는 부분에 대해 데이터나 논리로 반박하세요. 감정적 반박 금지.

### 이전 라운드에서 놓친 새로운 관점
앞선 토론에서 언급되지 않은 중요한 요소를 제시하세요.

### {AGENT_NAME}의 수정된 최종 입장
이전 라운드 자신의 의견과 비교해 무엇이 바뀌었고 왜 바뀌었는지 명확히 서술하세요."

# ============================================================
# === Helper Functions ===
# ============================================================

clean_logs() { rm -f "$LOG_DIR"/*.log; }

update_agent_status() {
  local id="$1" status="$2"
  python3 -c "
import json
try:
    with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
    for a in d.get('agents', []):
        if a['id'] == '$id': a['status'] = '$status'
    with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
except Exception as e: pass
" 2>/dev/null
}

update_session_status() {
  python3 -c "
import json, datetime
try:
    with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
    d['status'] = '$1'
    if '$1' == 'completed': d['completed_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
except: pass
" 2>/dev/null
}

run_agent() {
  local id="$1" label="$2" prompt="$3" output="$4"
  echo "[$(date +%H:%M:%S)] ${label} 시작..." >> "$LOG_DIR/${id}.log"
  update_agent_status "$id" "running"

  if (cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
      "$CLAUDE_BIN" -p "$prompt") > "$output" 2>> "$LOG_DIR/${id}.log"; then
    update_agent_status "$id" "done"
    echo "[$(date +%H:%M:%S)] ${label} 완료 ✓" >> "$LOG_DIR/${id}.log"
  else
    update_agent_status "$id" "error"
    echo "[$(date +%H:%M:%S)] ${label} 실패 (exit: $?)" >> "$LOG_DIR/${id}.log"
  fi
}

# ============================================================
# === Session 초기화 ===
# ============================================================
clean_logs

AGENTS_JSON="["
for id in "${SELECTED_AGENTS[@]}"; do
  name="$(get_agent_name "$id")"
  AGENTS_JSON+="{\"id\": \"$id\", \"name\": \"$name\", \"status\": \"pending\"},"
done
AGENTS_JSON="${AGENTS_JSON%,}]"

if [ "$CONTINUE_MODE" = true ]; then
  # 기존 meta.json 업데이트: 라운드 수 확장 + status 재설정
  python3 -c "
import json
with open('$SESSION_DIR/meta.json') as f: d = json.load(f)
d['rounds'] = $TOTAL_ROUNDS
d['status'] = 'running'
for a in d.get('agents', []): a['status'] = 'pending'
with open('$SESSION_DIR/meta.json', 'w') as f: json.dump(d, f, ensure_ascii=False, indent=2)
" 2>/dev/null
  echo "🏴‍☠️ Round Table 계속 (Round ${LAST_DONE} → ${TOTAL_ROUNDS})"
else
  cat > "$SESSION_DIR/meta.json" <<METAEOF
{
  "topic": "$TOPIC",
  "rounds": $TOTAL_ROUNDS,
  "agents_config": "$AGENTS_ARG",
  "project_dir": "$PROJECT_DIR",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "running",
  "agents": $AGENTS_JSON
}
METAEOF
  echo "🏴‍☠️ Round Table 시작"
fi
echo "   토픽: $TOPIC"
echo "   에이전트: ${SELECTED_AGENTS[*]}"
echo "   토론 라운드: $TOTAL_ROUNDS + 최종 종합"
echo "   프로젝트: $PROJECT_DIR"
echo ""

# ============================================================
# === Round 1: 초기 입장 (신규 세션만) ===
# ============================================================
if [ "$CONTINUE_MODE" = false ]; then
  echo "[Round 1/$(($TOTAL_ROUNDS+1))] 초기 분석 시작 (병렬)..."
  for id in "${SELECTED_AGENTS[@]}"; do
    name="$(get_agent_name "$id")"
    prompt="$(get_agent_prompt_r1 "$id" "$TOPIC" "$PROJECT_DIR")"
    run_agent "$id" "${name} [R1]" "$prompt" "$SESSION_DIR/round-1/${id}.md" &
  done
  wait
  echo "[$(date +%H:%M:%S)] Round 1 완료"
fi

# ============================================================
# === 토론 라운드 (병렬) ===
# ============================================================
for round in $(seq "$START_DEBATE_ROUND" "$TOTAL_ROUNDS"); do
  prev=$((round-1))
  echo ""
  echo "[Round ${round}/$(($TOTAL_ROUNDS+1))] 토론 라운드 시작 (병렬)..."

  for id in "${SELECTED_AGENTS[@]}"; do
    name="$(get_agent_name "$id")"

    # 이전 라운드의 다른 에이전트 출력 수집
    PREV_OUTPUTS=""
    for other_id in "${SELECTED_AGENTS[@]}"; do
      if [ "$other_id" != "$id" ]; then
        other_name="$(get_agent_name "$other_id")"
        other_content=$(head -200 "$SESSION_DIR/round-${prev}/${other_id}.md" 2>/dev/null || echo "(출력 없음)")
        PREV_OUTPUTS+="### ${other_name}:\n${other_content}\n\n---\n\n"
      fi
    done

    # 토론 프롬프트 생성
    prompt="${DEBATE_PROMPT_BASE}"
    prompt="${prompt//\{AGENT_NAME\}/$name}"
    prompt="${prompt//\{TOPIC\}/$TOPIC}"
    prompt="${prompt//\{PREV_ROUND\}/$prev}"
    prompt="${prompt//\{PREV_OUTPUTS\}/$PREV_OUTPUTS}"

    run_agent "$id" "${name} [R${round}]" "$prompt" "$SESSION_DIR/round-${round}/${id}.md" &
  done
  wait
  echo "[$(date +%H:%M:%S)] Round $round 완료"
done

# ============================================================
# === 최종 종합: CEO 결정 ===
# ============================================================
echo ""
echo "[최종/$(($TOTAL_ROUNDS+1))] CEO 종합 분석 시작..."
echo "[$(date +%H:%M:%S)] 최종 종합 시작..." > "$LOG_DIR/synthesizer.log"

# 전체 라운드 × 전체 에이전트 출력 수집
ALL_CONTEXT=""
for round in $(seq 1 "$TOTAL_ROUNDS"); do
  ALL_CONTEXT+="## ============ Round $round ============\n\n"
  for id in "${SELECTED_AGENTS[@]}"; do
    name="$(get_agent_name "$id")"
    content=$(head -150 "$SESSION_DIR/round-${round}/${id}.md" 2>/dev/null || echo "(없음)")
    ALL_CONTEXT+="### ${name}:\n${content}\n\n"
  done
done

AGENT_LIST=""
for id in "${SELECTED_AGENTS[@]}"; do
  AGENT_LIST+="$(get_agent_name "$id"), "
done
AGENT_LIST="${AGENT_LIST%, }"
SYNTHESIS_PROMPT="당신은 CEO이자 최종 의사결정자입니다. 한국어로 응답하세요.

토픽: $TOPIC
참여 전문가: $AGENTS_ARG
진행 라운드: $TOTAL_ROUNDS

$ALL_CONTEXT

위 ${TOTAL_ROUNDS}라운드 토론 전체를 검토하고 최종 결정을 내려주세요:

### 최종 결정: [실행 / 조건부 실행 / 보류 / 기각]

### 결정 근거 (5줄 이내)

### 라운드별 입장 변화 요약
각 전문가의 포지션이 라운드를 거치며 어떻게 바뀌었는지 1줄로 요약

### 채택한 핵심 인사이트
| 전문가 | 채택한 포인트 | 반영 방식 |

### 실행 액션 플랜
- 즉시 (1주 이내):
- 단기 (1개월):
- 중기 (3개월):

### 리스크 완화 방안

### 의사결정 번복 조건
어떤 데이터/상황이 나타나면 이 결정을 재검토할 것인가"

(cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    "$CLAUDE_BIN" -p "$SYNTHESIS_PROMPT") \
    > "$SESSION_DIR/final/synthesis.md" 2>> "$LOG_DIR/synthesizer.log"

cp "$SESSION_DIR/final/synthesis.md" "$SESSION_DIR/conclusion.md" 2>/dev/null
update_session_status "completed"

echo ""
echo "🏴‍☠️ Round Table 완료!"
echo "   결과: $SESSION_DIR/conclusion.md"
echo "   세션: $TIMESTAMP"
