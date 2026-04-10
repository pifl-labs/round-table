# Round Table — CLAUDE.md

## 프로젝트 개요

Claude Code 멀티 에이전트 토론/코드리뷰 시스템.
여러 AI 에이전트(analyst, developer, critic 등)가 병렬로 토픽을 분석하고,
라운드별 토론 후 CEO 에이전트가 최종 결정을 내리는 의사결정·코드리뷰 도구.

## 핵심 파일

```
orchestrator.sh              # 토론 오케스트레이터 (메인)
code-review-orchestrator.sh  # 코드 리뷰 전용 오케스트레이터
task-orchestrator.sh         # 태스크 오케스트레이터
web/server.js                # 웹 UI 서버 (Node.js)
web/index.html               # 토론 UI
web/code-review.html         # 코드 리뷰 UI
sessions/                    # 세션 출력물 (무시됨 — .claudeignore)
logs/                        # 로그 (무시됨 — .claudeignore)
```

## 아키텍처

- **Shell + Claude CLI**: 오케스트레이터는 bash, 각 에이전트는 `claude -p` 서브프로세스
- **멀티 AI 지원**: Claude / Gemini CLI / Codex CLI / OpenAI API / Gemini API
- **세션 기반**: `sessions/<TIMESTAMP>/` 에 meta.json, agents.json, round-N/, final/ 저장
- **웹 UI**: Node.js 서버가 bash 오케스트레이터를 호출하고 SSE로 실시간 진행 스트리밍

## 개발 명령

```bash
# 웹 서버 실행
cd web && node server.js

# CLI 토론 실행
./orchestrator.sh "토픽" 2 "analyst,developer,critic" /path/to/project

# CLI 코드 리뷰
./code-review-orchestrator.sh generate SESSION_ID
./code-review-orchestrator.sh run SESSION_ID
```

## 컨텍스트 범위

코드 리뷰 시 `meta.json`의 `code_dir`(또는 `project_dir`)에 지정된 **대상 프로젝트만** 분석 대상.
round-table 자체 코드(orchestrator.sh 등)는 리뷰 대상이 아닌 이상 분석 불필요.
