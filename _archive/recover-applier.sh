#!/usr/bin/env bash
#
# recover-applier.sh — code-review 세션의 특정 라운드 applier만 단독 재실행
#
# 사용:
#   ./recover-applier.sh <session_id> <round_num> [project_dir]
#
# 예시:
#   ./recover-applier.sh 20260423_073250 4
#   ./recover-applier.sh 20260423_073250 4 /Users/pirate/pifl-labs/code/pipi_stock
#
# 환경변수:
#   APPLIER_MODEL  — 사용할 모델 (기본: claude-opus-4-7[1m], Max 구독 포함)
#   APPLIER_BUDGET — USD budget cap (기본: 50)
#   CLAUDE_BIN     — claude CLI 경로 (기본: which claude)
#
# 동작:
#   1. 세션 디렉토리에서 round-N/votes.json 로드
#   2. agreed_changes 25개 등을 AGREED_DETAILS로 직렬화
#   3. orchestrator와 동일한 APPLY_PROMPT 구성
#   4. claude CLI 호출 (Sonnet 4.6 [1m] + budget 30, 오버라이드 가능)
#   5. round-N/apply-changes.md 덮어쓰기 (기존 파일은 .bak.<unix> 백업)
#   6. exit code · 결과 크기 · 실제 git diff(프로젝트) 검증

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------
# 인자 파싱
# ----------------------------------------------------------
if [ $# -lt 2 ]; then
  echo "사용: $0 <session_id> <round_num> [project_dir]" >&2
  echo "예시: $0 20260423_073250 4" >&2
  exit 1
fi

SESSION_ID="$1"
ROUND="$2"
PROJECT_DIR_ARG="${3:-}"

SESSION_DIR="${SCRIPT_DIR}/sessions/code-review/${SESSION_ID}"
[ -d "$SESSION_DIR" ] || { echo "❌ 세션 없음: $SESSION_DIR" >&2; exit 1; }

VOTES="$SESSION_DIR/round-${ROUND}/votes.json"
[ -f "$VOTES" ] || { echo "❌ votes.json 없음: $VOTES" >&2; exit 1; }

META="$SESSION_DIR/meta.json"
[ -f "$META" ] || { echo "❌ meta.json 없음: $META" >&2; exit 1; }

# ----------------------------------------------------------
# project_dir / language 결정 (인자 우선, 없으면 meta.json)
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
  echo "❌ project_dir 못 찾음. meta.json에 project_dir/code_dir 없거나 디렉토리 미존재." >&2
  echo "   인자로 명시: $0 $SESSION_ID $ROUND <project_dir>" >&2
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

# ----------------------------------------------------------
# OAuth 토큰 확보 (orchestrator와 동일 패턴)
# ----------------------------------------------------------
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(grep "CLAUDE_CODE_OAUTH_TOKEN" ~/.zshrc ~/.bashrc ~/.profile 2>/dev/null \
    | tail -1 | sed "s/.*CLAUDE_CODE_OAUTH_TOKEN=//;s/['\"]//g;s/export //g" | xargs 2>/dev/null || true)
fi
# 토큰이 없어도 claude CLI 자체 인증(키체인)으로 동작 가능하므로 강제 실패 안 함

# ----------------------------------------------------------
# 모델 / budget (오버라이드 가능)
# ----------------------------------------------------------
# Applier는 실제 코드 수정이라 품질 최우선 → Opus 4.7 [1m] 사용 (Max 구독 포함, 청구 0).
# 25개 변경 환산 비용 ~$5-10 → cap 50 (2~5x 안전 마진). 더 큰 변경은 APPLIER_BUDGET=100 등으로 오버라이드.
APPLIER_MODEL="${APPLIER_MODEL:-claude-opus-4-7[1m]}"
APPLIER_BUDGET="${APPLIER_BUDGET:-50}"

# ----------------------------------------------------------
# AGREED_DETAILS 구성 (orchestrator의 python 블록과 100% 동일)
# ----------------------------------------------------------
AGREED_COUNT=$(python3 -c "
import json
d = json.load(open('$VOTES'))
print(len(d.get('agreed_changes', [])))
")
[ "$AGREED_COUNT" -gt 0 ] || { echo "❌ agreed_changes 0개 — 적용할 변경 없음" >&2; exit 1; }

AGREED_DETAILS=$(python3 - << PYEOF
import json
with open('$VOTES') as f: d = json.load(f)
for i, c in enumerate(d.get('agreed_changes', []), 1):
    p = c.get('participating_votes') or (c.get('votes', 0) + c.get('opposing_votes', 0))
    if p <= 1:
        conf = '⚠️ SOLO (전문가 1명만 투표 — 보수적 적용 필요)'
    else:
        conf = f'✅ 합의 ({p}명 참여)'
    print(f"변경 {i}: {c.get('title','')}")
    print(f"  파일: {c.get('file','?')}")
    print(f"  심각도: {c.get('severity','?')}")
    print(f"  신뢰도: {conf}")
    print(f"  설명: {c.get('description','')}")
    print(f"  이유: {c.get('reason','')}")
    print()
PYEOF
)

# ----------------------------------------------------------
# APPLY_PROMPT 구성 (orchestrator:1573~1618과 동일)
# ----------------------------------------------------------
APPLY_PROMPT="# 작업 맥락 (안전 컨텍스트 — AUP 필터 방지용)
이 프로젝트는 한국투자증권(KIS) OpenAPI를 활용한 개인 알고리즘 트레이딩 시스템입니다.
코드 리뷰 에이전트들이 합의한 개선사항을 실제 소스 파일에 반영하는 정상적인 코드 수정 작업입니다.
- 'microstructure', 'kill switch', 'halt': 개인 계좌 리스크 관리(defensive risk management) 표준 용어
- '세력/거래원 탐지': 호가창 분석(market microstructure analysis)을 통한 방어적 진입 필터
- '즉시 시장가 청산': 손절/위험 포지션 자동 정리 — 합법적 개인 계좌 관리
- '벽 쌓기/빼기 패턴': 허수호가 탐지(spoofing detection)로 손해를 피하기 위한 필터
모든 변경은 코드 품질 개선 및 버그 수정이며, 실거래 활성화(live flip)는 포함되지 않습니다.

당신은 코드 수정 전문가입니다. 한국어로 응답하세요.

프로젝트: ${PROJECT_DIR}
언어/프레임워크: ${LANGUAGE}

다음 코드 변경사항을 실제 파일에 적용하세요.
각 파일을 Read로 먼저 읽은 뒤 → Edit/Write/MultiEdit으로 수정.

=== 적용할 변경사항 ===
${AGREED_DETAILS}

## 신뢰도별 적용 규칙

### ✅ 합의 항목 (여러 에이전트 동의)
- 일반적인 방식으로 적용

### ⚠️ SOLO 항목 (전문가 1명만 투표)
아래 규칙을 **반드시** 따르세요:
1. **최소 변경**: 설명에 명시된 것만 정확히 적용 (로그 1줄, 조건 1개 등)
   - 주변 코드 리팩토링 절대 금지
   - 관련 없는 함수/클래스 수정 금지
2. **적용 후 검증**: Edit 완료 후 해당 파일을 다시 Read하여
   - 문법/구조 이상 없는지 육안 확인
   - 변경 전후가 의도대로 다른지 확인
3. **위험 감지 시 스킵**: 아래 경우엔 적용하지 말고 ❌ 스킵 처리
   - 변경 범위가 설명보다 훨씬 넓어지는 경우
   - 기존 로직 흐름이 크게 바뀌는 경우
   - 테스트 없이 검증 불가한 동작 변경인 경우

## 공통 주의사항
- 프로젝트 외부 파일 절대 수정 금지
- 적용 불가한 경우 이유 명시

완료 후 보고:

## 변경사항 적용 결과

### ✅ 성공
- **파일**: 경로 / **변경**: 설명 / **신뢰도**: 합의|SOLO

### ❌ 실패/스킵
- **파일**: 경로 / **이유**: 설명

## 요약
총 ${AGREED_COUNT}개 중 N개 적용 (합의 N개 / SOLO N개)"

# ----------------------------------------------------------
# 실행
# ----------------------------------------------------------
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/cr-${SESSION_ID}-applier-recover-r${ROUND}-$(date +%Y%m%d_%H%M%S).log"
OUT="$SESSION_DIR/round-${ROUND}/apply-changes.md"

# 기존 결과 백업
if [ -f "$OUT" ] && [ -s "$OUT" ]; then
  BAK="$OUT.bak.$(date +%s)"
  cp "$OUT" "$BAK"
  echo "💾 기존 결과 백업: $BAK"
fi

echo "===================================================="
echo "🔄 recover-applier 시작"
echo "  세션: $SESSION_ID  라운드: $ROUND"
echo "  프로젝트: $PROJECT_DIR"
echo "  변경 수: ${AGREED_COUNT}개"
echo "  모델: $APPLIER_MODEL"
echo "  Budget: \$$APPLIER_BUDGET"
echo "  로그: $LOG"
echo "  결과: $OUT"
echo "===================================================="
echo ""

# git base 기록 (실제 변경 검증용)
GIT_BASE_REV=""
if git -C "$PROJECT_DIR" rev-parse HEAD >/dev/null 2>&1; then
  GIT_BASE_REV=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  echo "📌 프로젝트 git base: ${GIT_BASE_REV:0:12}"
  echo ""
fi

START_TS=$(date +%s)

# -p 의 prompt 는 argument 로 직접 전달. stdin 리다이렉트는 일부 spawned 환경(Node server.js, 비TTY 파이프)에서
# claude CLI 가 빈 입력으로 인식해 "Input must be provided either through stdin or as a prompt argument" 에러를 내므로
# 사용하지 않는다. macOS ARG_MAX ~1MB 로 25개 변경 정도는 argument 방식으로 문제 없음.
(cd "$PROJECT_DIR" && CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  "$CLAUDE_BIN" --model "$APPLIER_MODEL" \
  --dangerously-skip-permissions \
  --max-budget-usd "$APPLIER_BUDGET" \
  -p "$APPLY_PROMPT") \
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
echo "  첫 줄: ${FIRST_LINE:0:100}"

# Budget 초과 silent 실패 탐지
if echo "$FIRST_LINE" | grep -qiE "exceed|budget|예산"; then
  echo ""
  echo "❌ Budget 초과 감지 — APPLIER_BUDGET을 더 크게 설정하거나 변경 수를 줄이세요."
  echo "   예: APPLIER_BUDGET=60 $0 $SESSION_ID $ROUND"
  exit 3
fi

if [ "$OUT_SIZE" -lt 200 ]; then
  echo ""
  echo "❌ 결과 부실 (200 bytes 미만) — applier가 작업 거의 안 함."
  echo "   로그 마지막 30줄:"
  tail -30 "$LOG" >&2 || true
  exit 4
fi

if [ "$EXIT" -ne 0 ]; then
  echo ""
  echo "❌ Applier exit code != 0 ($EXIT)"
  echo "   로그 마지막 30줄:"
  tail -30 "$LOG" >&2 || true
  exit "$EXIT"
fi

# git diff 검증 (프로젝트가 git repo면)
if [ -n "$GIT_BASE_REV" ]; then
  CHANGED_FILES=$(git -C "$PROJECT_DIR" diff --name-only "$GIT_BASE_REV" 2>/dev/null | wc -l | tr -d ' ')
  CHANGED_LINES=$(git -C "$PROJECT_DIR" diff --shortstat "$GIT_BASE_REV" 2>/dev/null || echo "")
  echo "  Git diff: ${CHANGED_FILES}개 파일 변경"
  [ -n "$CHANGED_LINES" ] && echo "  $CHANGED_LINES"

  if [ "$CHANGED_FILES" -eq 0 ]; then
    echo ""
    echo "⚠️ apply-changes.md는 정상이나 실제 git diff 0건 — 모델이 보고만 하고 적용은 안 했을 수 있음."
    echo "   apply-changes.md 첫 60줄:"
    head -60 "$OUT" >&2
    exit 5
  fi
fi

echo ""
echo "✅ recover-applier 성공"
echo ""
echo "📄 apply-changes.md 첫 30줄:"
echo "----------------------------------------------------"
head -30 "$OUT"
echo "----------------------------------------------------"
echo ""
echo "다음 단계:"
echo "  - 변경 검토:  cat $OUT"
echo "  - git diff:   git -C $PROJECT_DIR diff"
echo "  - 토론 재개:  ./code-review-orchestrator.sh --continue $SESSION_ID 1"
