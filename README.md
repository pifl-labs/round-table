# Round Table 🏴‍☠️

**Claude Code 멀티 에이전트 토론 시스템**

여러 전문가 에이전트가 동시에 토픽을 분석하고, 라운드별 토론을 거쳐 CEO 에이전트가 최종 결정을 내리는 의사결정 도구입니다.

```
Round 1: 시장분석가 ──┐
         기술리드   ──┼──→ (병렬 분석)
         악마의변호인──┘

Round 2: 각 에이전트가 다른 에이전트 의견을 읽고 반박/수정

Round N: (반복)
         ↓
최종 종합: CEO가 모든 라운드를 검토 후 결정 내림
```

---

## 요구사항

- [Claude Code CLI](https://docs.anthropic.com/claude-code) 설치 및 인증
- Node.js 18+
- Bash (macOS / Linux)

---

## 설치

```bash
git clone https://github.com/your-org/round-table.git
cd round-table

# 환경변수 설정
cp .env.example .env
# .env 파일을 열어 CLAUDE_CODE_OAUTH_TOKEN 입력
```

토큰 확인:
```bash
claude auth status
# 또는 ~/.zshrc에 이미 CLAUDE_CODE_OAUTH_TOKEN이 있으면 자동 인식
```

---

## 사용법

### CLI (직접 실행)

```bash
./orchestrator.sh "토픽" [라운드수] [에이전트목록] [프로젝트경로]
```

**예시:**
```bash
# 기본 (3명, 2라운드, 현재 디렉토리)
./orchestrator.sh "AI 기능을 추가해야 하는가?"

# 4라운드, 4명 참여
./orchestrator.sh "pub.dev 패키지 공개 전략" 4 "analyst,developer,critic,financial"

# 특정 프로젝트 경로 지정
./orchestrator.sh "아키텍처 개선 방향" 3 "developer,critic,strategist" /path/to/project
```

### 웹 UI (모니터링 대시보드)

```bash
cd web
node server.js        # 기본 포트 3847
node server.js 8080   # 포트 지정
```

브라우저에서 `http://localhost:3847` 접속

---

## 에이전트 목록

| ID | 이름 | 역할 |
|----|------|------|
| `analyst` | 시장 분석가 | WebSearch로 시장 데이터·경쟁사 분석 |
| `developer` | 기술 리드 | 코드베이스 확인, 기술적 실현 가능성 평가 |
| `critic` | 악마의 변호인 | 반론·리스크·대안 제시 |
| `designer` | UX 디자이너 | 사용자 경험·플로우·모바일 UX 분석 |
| `financial` | 재무 분석가 | 비용·수익·ROI·손익분기점 산출 |
| `strategist` | 장기 전략가 | 포지셔닝·경쟁 우위·포트폴리오 영향 분석 |

---

## 환경변수

| 변수 | 필수 | 설명 |
|------|------|------|
| `CLAUDE_CODE_OAUTH_TOKEN` | ✅ | Claude Code 인증 토큰 |
| `CLAUDE_BIN` | ❌ | claude CLI 경로 (자동 탐지) |
| `PROJECT_DIR` | ❌ | 워크스페이스 루트 (기본: round-table 상위) |
| `PORT` | ❌ | 웹 UI 포트 (기본: 3847) |

---

## 디렉토리 구조

```
round-table/
├── orchestrator.sh       # 메인 오케스트레이터
├── .env.example          # 환경변수 템플릿
├── .gitignore
├── README.md
├── sessions/             # 토론 기록 (gitignore)
│   └── 20260324_093318/
│       ├── meta.json
│       ├── round-1/
│       │   ├── analyst.md
│       │   ├── developer.md
│       │   └── critic.md
│       ├── round-2/
│       │   └── ...
│       └── conclusion.md
├── logs/                 # 실시간 로그 (gitignore)
└── web/
    ├── server.js         # Node.js 서버
    ├── index.html        # 대시보드 UI
    └── package.json
```

---

## 토론 결과 구조

결론 파일(`sessions/*/conclusion.md`)은 항상 다음 형식으로 출력됩니다:

```markdown
### 최종 결정: [실행 / 조건부 실행 / 보류 / 기각]
### 핵심 근거
### 채택한 인사이트 (에이전트별 표)
### 실행 액션 플랜 (즉시 / 단기 / 중기)
### 리스크 완화 방안
### 의사결정 번복 조건
```

---

## 라이선스

MIT
