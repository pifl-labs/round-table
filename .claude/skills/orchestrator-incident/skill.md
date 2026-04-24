---
name: orchestrator-incident
description: "round-table 오케스트레이터(code-review/debate/task) 실패·hang·오작동 인시던트 원샷 대응 오케스트레이터. log-forensics / git-drift-auditor / shell-auditor / runtime-env-analyst 4개 에이전트 병렬 분석 → patch-surgeon 최소 수술 → recovery-planner 복구 경로 설계. 트리거: 'applier 실패', 'voter 중단', 'orchestrator 뻗음', 'exit 1', '또 터졌다', '같은 에러 반복'."
---

# Orchestrator Incident — round-table 인시던트 원샷 대응

round-table 오케스트레이터(`code-review-orchestrator.sh`, `orchestrator.sh`, `task-orchestrator.sh`)가 실패·hang·오작동하면 **절대 혼자 파헤치지 말고** 이 스킬을 호출. 4명의 전문가가 병렬 분석해 원인·수정·복구를 원샷으로 제안.

## 적용 조건
- round-table 프로젝트 cwd
- 다음 증상 중 하나:
  - `logs/cr-*.log` 에 exit != 0
  - "같은 수정인데 또 터진다"
  - 웹 UI에서 특정 라운드/에이전트만 fail 표시
  - applier hang, budget exceeded, stream idle, partial response

## Phase 1: 증거 수집 (병렬 fan-out)

4개 에이전트를 **동시에** 호출 (한 메시지 안에서 여러 Agent 툴 호출):

| 에이전트 | 수집 대상 |
|---------|-----------|
| `orchestrator-log-forensics` | `logs/cr-<ID>-*.log`, 마지막 stderr, exit code, 타임라인 |
| `orchestrator-git-drift-auditor` | main vs worktree 브랜치 드리프트, fix 커밋 위치 |
| `orchestrator-shell-auditor` | 실패한 CLI 호출 라인과 성공 라인 대조, shell 패턴 |
| `orchestrator-runtime-env-analyst` | spawn/stdin/서브셸/timeout/ARG_MAX 환경 요인 |

**주의**: 각 에이전트 프롬프트에 세션 ID, 로그 경로, 관련 파일을 구체적으로 주입. 추측 금지.

## Phase 2: 진단 종합 + 패치 (순차)

1. 4개 리포트를 받아서 **원인 1문장** 정리
2. `orchestrator-patch-surgeon` 호출 — Phase 1 진단을 입력으로 주고 최소 수술 요청
3. 수술 완료 후 `bash -n` + grep 잔존 체크 자동 수행

## Phase 3: 복구 설계 (순차)

`orchestrator-recovery-planner` 호출 — 세션 상태 + 수술 결과 입력, 복구 루트 설계

출력:
- `./recover-applier.sh <ID> <round>` / `./recover-reviewer.sh <ID> <round>` / 완전 재시작 중 선택
- 워크트리 머지/삭제 권고
- **사용자 승인 후 실행**

## Phase 4: 검증 게이트

수술 후 다음 중 하나로 실제성 확인:
- `./recover-applier.sh` 실제 실행하여 exit 0 확인 (사용자 승인 시)
- 새 세션 소규모 테스트 (사용자 승인 시)
- 또는 재현 케이스가 있으면 `bash -x` 로 트레이스

## 에이전트 디스패치 예시

```
[Phase 1 - 병렬]
Agent(orchestrator-log-forensics):
  prompt: "세션 cr-20260424_153012 의 applier R1 실패 분석.
           로그 경로: /Users/pirate/pifl-labs/round-table/logs/cr-20260424_153012-applier.log
           최종 exit code, 직전 10라인, 관련 로그(generator/voter) 상관관계 보고."

Agent(orchestrator-git-drift-auditor):
  prompt: "round-table 프로젝트에서 applier 관련 fix 커밋 위치 추적.
           키워드: 'APPLIER', 'stdin', 'applier'
           main HEAD vs worktree 브랜치 드리프트 보고."

Agent(orchestrator-shell-auditor):
  prompt: "/Users/pirate/pifl-labs/round-table/code-review-orchestrator.sh
           에서 APPLIER 호출 블록과 성공하는 GENERATOR/VOTER 호출 블록을 대조.
           차이점 보고."

Agent(orchestrator-runtime-env-analyst):
  prompt: "/Users/pirate/pifl-labs/round-table/web/server.js 의 spawn 옵션 확인.
           stdin 상속이 orchestrator.sh 내부 claude CLI 까지 전파되는지 분석."

[Phase 2 - 순차]
(4개 리포트 수신 후)
Agent(orchestrator-patch-surgeon):
  prompt: "다음 진단 종합 입력:
           [log-forensics 결과 요약]
           [git-drift 결과 요약]
           [shell-audit 권고안]
           [runtime-env 환경 근거]

           최소 변경으로 수술. 퇴행 금지 목록:
           - run_with_timeout 1800
           - --model $APPLIER_MODEL
           - --max-budget-usd $APPLIER_BUDGET
           - APPLY_EXIT=$? 보존"

[Phase 3 - 순차]
Agent(orchestrator-recovery-planner):
  prompt: "세션 cr-20260424_153012 복구 경로 설계.
           수술 완료 상태.
           round-1/generator.md / voter.json 존재, apply-changes.md 없음.
           worktree claude/blissful-johnson-52bebe 처리 방침 포함."
```

## 격리 옵션

Phase 1 (읽기 전용): 격리 불필요.
Phase 2 (파일 편집): 메인 세션에서 순차 수행. 병렬 편집 없으므로 worktree 격리 불필요.
Phase 4 (실제 복구 실행): 사용자 승인 후 메인 세션에서 수행.

## 절대 금지
- 4개 에이전트 중 1~2개만 호출하고 "충분히 분석했다" 판단
- 로그 확인 없이 추측으로 patch-surgeon 호출
- 사용자 승인 없이 recover-*.sh 실행
- 워크트리 임의 삭제

## 출력 템플릿

```
# Incident Report — <세션 ID>

## 증거 (병렬 수집)
- 로그: [log-forensics 요약]
- 드리프트: [git-drift 요약]
- Shell: [shell-audit 차이점]
- 환경: [runtime-env 진단]

## 원인 (1문장)
<한 줄 요약>

## 수술 결과 (patch-surgeon)
- 파일: <path>:<lines>
- 변경 요약: ...
- 검증: bash -n OK, grep 잔존 0건, 보존 기능 N개 유지

## 복구 루트 (recovery-planner)
1. <명령 1>
2. <명령 2>
- [ ] 사용자 승인 필요

## 결정 요청
- [ ] 복구 명령 실행?
- [ ] 워크트리 정리?
- [ ] 커밋 메시지 작성 후 push?
```
