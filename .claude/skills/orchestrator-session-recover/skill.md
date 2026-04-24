---
name: orchestrator-session-recover
description: "round-table 세션 복구 절차 매뉴얼. recover-applier.sh / recover-reviewer.sh 안전 실행, 사전 체크, 로그 위치, 실패 시 fallback. recovery-planner 에이전트가 참조. 트리거: 'recover-applier', 'recover-reviewer', '세션 복구', '라운드 재개'."
---

# Orchestrator Session Recover — 세션 복구 절차

round-table 세션 복구의 **재사용 가능한 절차 매뉴얼**. recovery-planner 에이전트가 참조, 사용자가 직접 호출해도 동작.

## 사전 체크리스트

복구 실행 전 다음 필수 확인:

1. **원인 수정 완료?**
   - `git log -1 --stat code-review-orchestrator.sh` 로 최근 수정 확인
   - 수정 없이 복구하면 동일 에러 재발

2. **세션 상태 확인**
   ```bash
   SID=20260424_153012
   RND=1
   SESSION_DIR=/Users/pirate/pifl-labs/round-table/sessions/$SID

   ls -la "$SESSION_DIR/round-$RND/"
   # 기대:
   #  generator.md  (R1 생성 결과)
   #  voter.json    (투표 결과)
   #  apply-changes.md  (없거나 비어있으면 applier 실패)
   ```

3. **meta.json 무결성**
   ```bash
   cat "$SESSION_DIR/meta.json" | python3 -m json.tool > /dev/null && echo "OK" || echo "CORRUPT"
   ```

4. **budget/rate limit 잔여**
   - 최근 claude 사용량 체크 (사용자에게 확인)

## recover-applier.sh 실행

```bash
cd /Users/pirate/pifl-labs/round-table
./recover-applier.sh <SESSION_ID> <ROUND_NUMBER>

# 예:
./recover-applier.sh 20260424_153012 1
```

**동작**: 기존 `voter.json` 의 합의 변경사항을 읽고 applier 만 재실행. generator/voter 재실행 없음 → budget 절약.

**성공 판정**:
- exit 0
- `sessions/$SID/round-$RND/apply-changes.md` 생성됨
- 파일 크기 > 200 bytes
- 첫 줄에 "budget exceeded" / "stream idle" 등 키워드 없음

## recover-reviewer.sh 실행

```bash
./recover-reviewer.sh <SESSION_ID> <ROUND_NUMBER>
```

reviewer/final 단계만 재실행. applier 까지는 완료된 상태에서 사용.

## Fallback: 완전 재시작

recover-*.sh 도 실패하거나 세션 자체가 손상됐을 때:

```bash
# 1. 옛 세션 보존 (삭제 말고 이름만 변경)
mv sessions/$SID sessions/$SID.failed

# 2. 새 세션 시작 — 웹 UI 또는 CLI
cd web && node server.js &
# 브라우저에서 새 세션 생성

# OR CLI:
./code-review-orchestrator.sh generate <NEW_SESSION_ID> /path/to/project
./code-review-orchestrator.sh run <NEW_SESSION_ID>
```

## 로그 확인 위치

```
logs/cr-<SID>-applier.log      # applier 시작/실패 스탬프 + stderr
logs/cr-<SID>-voter.log        # voter 로그
logs/cr-<SID>-generator.log    # generator 로그
logs/cr-<SID>-reviewer.log     # reviewer 로그
sessions/<SID>/round-<N>/apply-changes.md  # applier 실제 결과물
sessions/<SID>/meta.json       # 세션 메타
```

## 복구 실행 후 확인

```bash
# exit code
echo $?

# apply-changes.md 크기
wc -c sessions/$SID/round-$RND/apply-changes.md

# 에러 키워드 grep
grep -iE "exceed|budget|idle|partial|api error" sessions/$SID/round-$RND/apply-changes.md || echo "CLEAN"

# 최신 로그 tail
tail -30 logs/cr-$SID-applier.log
```

## 금지 사항
- 원인 수정 없이 복구 시도 (무한 실패 루프)
- 여러 라운드 동시 recover (경쟁 조건)
- 세션 디렉토리 `rm -rf` (실패 증거 유실)
- 사용자 승인 없이 자동 실행

## 호출 예시 (recovery-planner 내부)

```
사용자 승인 받았나?
├── NO → 복구 명령 출력만 하고 멈춤
└── YES → 순서대로 실행:
    1. 사전 체크리스트 통과
    2. ./recover-applier.sh $SID $RND
    3. exit code + 산출물 검증
    4. 실패 시 Fallback 제시
    5. 성공 시 다음 라운드 진행 여부 사용자에 문의
```
