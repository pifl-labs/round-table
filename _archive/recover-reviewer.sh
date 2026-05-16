#!/usr/bin/env bash
#
# recover-reviewer.sh — code-review 세션의 특정 라운드 reviewer만 단독 재실행
#
# 사용:
#   ./recover-reviewer.sh <session_id> <round_num> [project_dir]
#
# 예시:
#   ./recover-reviewer.sh 20260423_073250 16
#
# 환경변수:
#   REVIEWER_MODEL  — 사용할 모델 (기본: claude-opus-4-7[1m])
#   REVIEWER_TIMEOUT — 초 단위 timeout (기본: 900 = 15분)
#   CLAUDE_BIN      — claude CLI 경로 (기본: which claude)
#
# 동작:
#   1. round-N/apply-changes.md의 첫 120줄을 APPLIED_SUMMARY로 추출
#   2. orchestrator의 REVIEWER_PROMPT와 100% 동일 형식으로 prompt 구성
#   3. claude CLI 호출 (timeout wrapper로 hang 차단)
#   4. round-N/code-reviewer.md 덮어쓰기 (기존은 .bak.<unix> 백업)
#   5. exit code · 결과 크기 · 키워드 검사로 silent 실패 차단

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------
# 인자
# ----------------------------------------------------------
if [ $# -lt 2 ]; then
  echo "사용: $0 <session_id> <round_num> [project_dir]" >&2
  echo "예시: $0 20260423_073250 16" >&2
  exit 1
fi

SESSION_ID="$1"
ROUND="$2"
PROJECT_DIR_ARG="${3:-}"

SESSION_DIR="${SCRIPT_DIR}/sessions/code-review/${SESSION_ID}"
[ -d "$SESSION_DIR" ] || { echo "❌ 세션 없음: $SESSION_DIR" >&2; exit 1; }

ROUND_DIR="$SESSION_DIR/round-${ROUND}"
[ -d "$ROUND_DIR" ] || { echo "❌ round-${ROUND} 없음" >&2; exit 1; }

APPLY_CHANGES="$ROUND_DIR/apply-changes.md"
[ -f "$APPLY_CHANGES" ] || { echo "❌ apply-changes.md 없음 — applier가 먼저 실행돼야 함" >&2; exit 1; }

META="$SESSION_DIR/meta.json"
[ -f "$META" ] || { echo "❌ meta.json 없음" >&2; exit 1; }

# ----------------------------------------------------------
# project_dir / language (인자 우선, 없으면 meta.json)
# ----------------------------------------------------------
if [ -n "$PROJECT_DIR_ARG" ]; then
  PROJECT_DIR="$PROJECT_DIR_ARG"
else
  PROJECT_DIR=$(python3 -c "
import json
d = json.load(open('$META'))
print(d.get('code_dir') or d.get('project_dir') or '')
")
fi
[ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ] || {
  echo "❌ project_dir 못 찾음. meta.json에 project_dir 없거나 디렉토리 미존재." >&2
  exit 1
}

LANGUAGE=$(python3 -c "
import json
d = json.load(open('$META'))
print(d.get('language', 'auto'))
" 2>/dev/null || echo "auto")

# ----------------------------------------------------------
# claude CLI 탐지
# ----------------------------------------------------------
CLAUDE_BIN="${CLAUDE_BIN:-$(which claude 2>/dev/null || true)}"
for candidate in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/opt/homebrew/bin/claude"; do
  [ -x "$candidate" ] && { CLAUDE_BIN="$candidate"; break; }
done
[ -x "${CLAUDE_BIN:-}" ] || {
  echo "❌ claude CLI를 찾을 수 없습니다." >&2
  exit 1
}

# OAuth 토큰
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(grep "CLAUDE_CODE_OAUTH_TOKEN" ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null \
    | tail -1 | sed "s/.*CLAUDE_CODE_OAUTH_TOKEN=//;s/['\"]//g;s/export //g" | xargs 2>/dev/null || true)
fi

# 모델 / timeout
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4-7[1m]}"
REVIEWER_TIMEOUT="${REVIEWER_TIMEOUT:-900}"

# ----------------------------------------------------------
# bash native timeout wrapper (orchestrator의 run_with_timeout과 동일)
# ----------------------------------------------------------
run_with_timeout() {
  local timeout_sec=$1
  shift
  # R17 BLOCKER 수정: stdin redirect 보존 (bash background 자동 /dev/null 우회)
  if [ ! -t 0 ]; then
    ("$@" <&0) &
  else
    ("$@" < /dev/null) &
  fi
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
  return $?
}

# ----------------------------------------------------------
# REVIEWER_PROMPT 구성 (orchestrator:1720~1749와 100% 동일)
# ----------------------------------------------------------
APPLIED_SUMMARY=$(head -120 "$APPLY_CHANGES" 2>/dev/null || echo "(없음)")

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

## ${LANGUAGE} 코드 리뷰 보고서 (Round ${ROUND})

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

# ----------------------------------------------------------
# 실행
# ----------------------------------------------------------
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/cr-${SESSION_ID}-reviewer-recover-r${ROUND}-$(date +%Y%m%d_%H%M%S).log"
OUT="$ROUND_DIR/code-reviewer.md"

# 기존 결과 백업
if [ -f "$OUT" ] && [ -s "$OUT" ]; then
  BAK="$OUT.bak.$(date +%s)"
  cp "$OUT" "$BAK"
  echo "💾 기존 결과 백업: $BAK"
fi

echo "===================================================="
echo "🔄 recover-reviewer 시작"
echo "  세션: $SESSION_ID  라운드: $ROUND"
echo "  프로젝트: $PROJECT_DIR"
echo "  언어: $LANGUAGE"
echo "  모델: $REVIEWER_MODEL"
echo "  Timeout: ${REVIEWER_TIMEOUT}초"
echo "  로그: $LOG"
echo "  결과: $OUT"
echo "===================================================="
echo ""

START_TS=$(date +%s)

(cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  run_with_timeout "$REVIEWER_TIMEOUT" "$CLAUDE_BIN" --model "$REVIEWER_MODEL" -p "$REVIEWER_PROMPT") \
  > "$OUT" 2>>"$LOG"
EXIT=$?

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

# ----------------------------------------------------------
# 검증
# ----------------------------------------------------------
echo ""
echo "===================================================="
echo "📊 결과 검증"
echo "===================================================="
echo "  Exit code: $EXIT"
echo "  소요 시간: ${DURATION}초"

OUT_SIZE=$(wc -c < "$OUT" 2>/dev/null || echo 0)
echo "  결과 크기: ${OUT_SIZE} bytes"

FIRST_LINE=$(head -1 "$OUT" 2>/dev/null || echo "")
echo "  첫 줄: ${FIRST_LINE:0:120}"

if [ "$EXIT" -eq 124 ]; then
  echo ""
  echo "❌ Reviewer 타임아웃 (${REVIEWER_TIMEOUT}초 도달)"
  echo "   더 큰 timeout 시도: REVIEWER_TIMEOUT=1800 $0 $SESSION_ID $ROUND"
  exit 124
fi

if echo "$FIRST_LINE" | grep -qiE "limit|exceed|hit your|usage|api error|stream idle|partial response"; then
  echo ""
  echo "❌ API 에러 감지 (limit/timeout/stream issue)"
  echo "   잠시 후 재시도하거나 5시간 윈도우 reset 대기"
  echo "   로그 마지막 20줄:"
  tail -20 "$LOG" >&2 || true
  exit 3
fi

if [ "$OUT_SIZE" -lt 300 ]; then
  echo ""
  echo "❌ 결과 부실 (300 bytes 미만)"
  echo "   로그 마지막 20줄:"
  tail -20 "$LOG" >&2 || true
  exit 4
fi

if [ "$EXIT" -ne 0 ]; then
  echo ""
  echo "❌ Reviewer exit code != 0 ($EXIT)"
  tail -20 "$LOG" >&2 || true
  exit "$EXIT"
fi

echo ""
echo "✅ recover-reviewer 성공"
echo ""
echo "📄 code-reviewer.md 첫 30줄:"
echo "----------------------------------------------------"
head -30 "$OUT"
echo "----------------------------------------------------"
echo ""
echo "다음 단계:"
echo "  - 리뷰 검토:    cat $OUT"
echo "  - 토론 재개:    ./code-review-orchestrator.sh --continue $SESSION_ID 1"
