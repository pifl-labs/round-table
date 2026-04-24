#!/usr/bin/env python3
"""Round-table Code Review — Python Voter (LLM-free)

에이전트 md 파일을 직접 파싱하여 votes.json을 생성한다.
LLM voter의 응답 잘림/예산 초과/파싱 실패 문제를 원천 차단한다.

사용법:
    python3 .python_voter.py SESSION_DIR ROUND_NUM

출력: stdout에 votes.json 내용 (JSON)
"""
import json
import re
import sys
from pathlib import Path


_TOKEN_STOP = {
    '이슈', '개선', '수정', '제안', '라운드', '코드', '검토',
    'issue', 'change', 'fix', 'round', 'code', 'suggestion', 'review',
    '문제', '필요', '적용', '추가', '변경', '제거', '삭제',
}


def title_tokens(t: str) -> set:
    """제목에서 핵심 토큰을 추출. 불용어/메타 토큰은 제거."""
    toks = set(re.findall(
        r'[A-Za-z][A-Za-z0-9_\.]{2,}|[0-9]{3,}|[\uAC00-\uD7A3]{2,}',
        (t or '').lower(),
    ))
    return toks - _TOKEN_STOP


def jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def title_match(t1_toks: set, t2_toks: set) -> bool:
    """이슈 제목 유사도 매칭.
    - 공통 토큰 최소 2개 필수 (단일 파일명 공통으로는 매칭 금지)
    - 영문 identifier + 한글 개념어 각 1개씩 공통 → 일치
    - 또는 Jaccard ≥ 0.4 → 일치
    """
    if not t1_toks or not t2_toks:
        return False
    common = t1_toks & t2_toks
    if len(common) < 2:
        return False
    has_ident = any(re.match(r'[A-Za-z]', c) and len(c) >= 4 for c in common)
    has_korean = any(re.match(r'[\uAC00-\uD7A3]', c) for c in common)
    if has_ident and has_korean:
        return True
    if jaccard(t1_toks, t2_toks) >= 0.4:
        return True
    return False


def parse_severity(s: str) -> str:
    s = (s or '').lower()
    for level in ('critical', 'high', 'medium', 'low'):
        if level in s:
            return level
    return 'medium'


def extract_agent_name(md_text: str, fallback: str) -> str:
    m = re.search(r'^##\s+(.+?)\s+코드\s*분석', md_text, re.MULTILINE)
    return m.group(1).strip() if m else fallback


_SECTION_HEADER_PAT = re.compile(r'^###\s+(.+?)\s*$', re.MULTILINE)


def split_sections(md_text: str) -> dict:
    """### 헤더 기준으로 섹션 분할. {header: body} 반환."""
    headers = [(m.start(), m.group(1).strip()) for m in _SECTION_HEADER_PAT.finditer(md_text)]
    sections = {}
    for i, (start, name) in enumerate(headers):
        end = headers[i + 1][0] if i + 1 < len(headers) else len(md_text)
        # 헤더 라인 이후부터 body
        line_end = md_text.find('\n', start)
        body_start = line_end + 1 if line_end != -1 else start
        sections[name] = md_text[body_start:end]
    return sections


# 이슈 마커 인식 — 세 가지 양식 모두 지원:
#   (A) **[이슈-N]** 제목             (괄호 뒤 ** + 제목)
#   (B) **[이슈-N] 제목**             (전체 볼드)
#   (C) **[이슈-N 신규: 라벨] 제목**  (괄호 내 추가 텍스트)
_ISSUE_MARKER_A = re.compile(
    r'\*\*\[(?:이슈|개선)-?(\d+)[^\]]*\]\*\*\s*([^\n]+)',
)
_ISSUE_MARKER_B = re.compile(
    r'\*\*\[(?:이슈|개선)-?(\d+)[^\]]*\]\s+([^\n*]+?)\*\*',
)


def _find_issue_starts(section_body: str) -> list:
    """섹션 안에서 (start_pos, title) 튜플 목록을 반환."""
    starts = []
    for pat in (_ISSUE_MARKER_A, _ISSUE_MARKER_B):
        for m in pat.finditer(section_body):
            starts.append((m.start(), m.end(), m.group(2).strip()))
    # 같은 위치 중복 제거, 시작 위치 기준 정렬
    seen = set()
    dedup = []
    for s, e, t in sorted(starts, key=lambda x: x[0]):
        if s in seen:
            continue
        seen.add(s)
        dedup.append((s, e, t))
    return dedup


def extract_issues(md_text: str) -> list:
    """발견된 이슈 / 개선 제안 섹션에서 이슈 블록을 파싱."""
    sections = split_sections(md_text)
    issue_sections = []
    for name, body in sections.items():
        if any(kw in name for kw in ('발견된 이슈', '개선 제안', '신규 이슈', '이슈')):
            if '다른 에이전트' in name or '제안 검토' in name or '이전 라운드' in name or '추적' in name:
                continue
            issue_sections.append(body)

    issues = []
    for body in issue_sections:
        starts = _find_issue_starts(body)
        for i, (s, e, title) in enumerate(starts):
            end = starts[i + 1][0] if i + 1 < len(starts) else len(body)
            block = body[e:end].strip()
            file_m  = re.search(r'위치[:\s]*([^\n]+)', block)
            sev_m   = re.search(r'심각도[:\s]*([^\n]+)', block)
            cause_m = re.search(r'근본\s*원인[:\s]*([^\n]+)', block)
            issues.append({
                "title":        title[:240],
                "file":         (file_m.group(1).strip() if file_m else '')[:240],
                "severity":     parse_severity(sev_m.group(1) if sev_m else 'medium'),
                "why_critical": (cause_m.group(1).strip() if cause_m else title)[:300],
                "body":         block[:1200],
            })
    return issues


_SUGGEST_STANCE_PAT = re.compile(
    r'\*\*\[([^\]\n]+)\]\*\*\s*:?\s*(✅|⚠️|❌)([^\n]*)',
)


def extract_suggestion_reviews(md_text: str) -> list:
    """`다른 에이전트 제안 검토` 섹션에서 `**[제안]**: ✅/⚠️/❌` 추출."""
    sections = split_sections(md_text)
    target = None
    for name, body in sections.items():
        if '다른 에이전트' in name or '제안 검토' in name:
            target = body
            break
    if target is None:
        return []
    results = []
    for m in _SUGGEST_STANCE_PAT.finditer(target):
        title, mark, rest = m.groups()
        stance = {'✅': 'agree', '⚠️': 'agree', '❌': 'oppose'}.get(mark, 'abstain')
        results.append({
            "title":  title.strip()[:240],
            "stance": stance,
            "reason": rest.strip()[:200],
        })
    return results


def extract_quality(md_text: str):
    m = re.search(r'품질\s*점수[:\s]*(\d+(?:\.\d+)?)\s*/\s*10', md_text)
    return float(m.group(1)) if m else None


def main():
    if len(sys.argv) < 3:
        print("usage: python_voter.py SESSION_DIR ROUND_NUM", file=sys.stderr)
        sys.exit(2)

    session_dir = Path(sys.argv[1])
    round_num   = int(sys.argv[2])
    round_dir   = session_dir / f"round-{round_num}"

    if not round_dir.is_dir():
        print(f"round dir not found: {round_dir}", file=sys.stderr)
        sys.exit(3)

    # --- 에이전트 md 파일 수집 ---
    SKIP_FILES = {
        'apply-changes.md', 'code-reviewer.md', 'voter-result.md',
        'votes.md', 'conclusion.md', 'peer-review.md',
    }
    agent_files = []
    for f in sorted(round_dir.iterdir()):
        if not f.name.endswith('.md'):
            continue
        if f.name in SKIP_FILES:
            continue
        if '-' in f.stem:  # competitive_analyst-scan.md 등 서브파일 제외
            continue
        agent_files.append(f)

    if not agent_files:
        print(json.dumps({
            "agreed_changes": [],
            "rejected_changes": [],
            "overall_quality_score": 5.0,
            "summary": "에이전트 md 파일 없음",
            "voter": "python",
            "voter_failed": True,
        }, ensure_ascii=False, indent=2))
        return

    # --- 파싱 ---
    agents_data = []
    for af in agent_files:
        text = af.read_text(errors='ignore')
        agents_data.append({
            "agent_id":    af.stem,
            "name":        extract_agent_name(text, af.stem),
            "issues":      extract_issues(text),
            "suggestions": extract_suggestion_reviews(text),
            "quality":     extract_quality(text),
        })

    agent_count = len(agents_data)

    # --- 모든 이슈 수집 ---
    raw_issues = []
    for a in agents_data:
        for iss in a["issues"]:
            raw_issues.append({
                **iss,
                "proposer":    a["name"],
                "proposer_id": a["agent_id"],
            })

    # --- 이슈 그룹화 (title_match 기준) ---
    groups = []
    for ri in raw_issues:
        toks = title_tokens(ri["title"] + " " + ri.get("file", ""))
        file_key = ri.get("file", "").split(':')[0].strip()
        merged = False
        for g in groups:
            if file_key and g.get("file_key") and file_key == g["file_key"]:
                if title_match(g["tokens"], toks):
                    g["reps"].append(ri)
                    g["tokens"] |= toks
                    merged = True
                    break
            if title_match(g["tokens"], toks):
                g["reps"].append(ri)
                g["tokens"] |= toks
                merged = True
                break
        if not merged:
            groups.append({
                "reps":     [ri],
                "tokens":   toks,
                "file_key": file_key,
            })

    # --- 각 그룹에 대한 투표 집계 ---
    sev_order = {"critical": 4, "high": 3, "medium": 2, "low": 1}
    CRITICAL_SEVERITY = {"critical", "high"}
    agreed_changes = []
    rejected_changes = []
    pending_solo_changes = []  # 1인 제기 critical/high — 동료 검토 대기

    for idx, g in enumerate(groups, 1):
        reps = g["reps"]
        first = reps[0]
        title = first["title"]
        file_ = first.get("file", "")
        best_rep = max(reps, key=lambda r: sev_order.get(r.get("severity", "medium"), 2))
        best_sev = best_rep.get("severity", "medium")

        proposers = []
        seen_props = set()
        for r in reps:
            if r["proposer"] not in seen_props:
                proposers.append(r["proposer"])
                seen_props.add(r["proposer"])

        why_critical = first.get("why_critical", title)
        description = first.get("body", "")[:600]

        votes = []
        agree_cnt = oppose_cnt = abstain_cnt = 0
        for a in agents_data:
            stance, reason = None, ""
            if a["name"] in seen_props:
                stance = "agree"
                reason = "본인이 제기한 이슈"
            else:
                # 다른 에이전트 제안 검토에서 해당 이슈에 대한 입장 확인
                for s in a["suggestions"]:
                    s_toks = title_tokens(s["title"])
                    if title_match(s_toks, g["tokens"]):
                        stance = s["stance"]
                        reason = (s["reason"] or f"제안 검토 ({stance})")[:200]
                        break
            if stance is None:
                stance = "abstain"
                reason = "언급 없음"
            votes.append({"agent": a["name"], "stance": stance, "reason": reason})
            if stance == "agree":
                agree_cnt += 1
            elif stance == "oppose":
                oppose_cnt += 1
            else:
                abstain_cnt += 1

        participating = agree_cnt + oppose_cnt
        item = {
            "id":                 f"change-{idx}",
            "title":              title,
            "file":               file_,
            "description":        description,
            "reason":             why_critical,
            "severity":           best_sev,
            "why_critical":       why_critical,
            "proposer":           proposers[0] if proposers else "",
            "supporters":         proposers,
            "votes":              agree_cnt,
            "opposing_votes":     oppose_cnt,
            "abstain_votes":      abstain_cnt,
            "participating_votes": participating,
            "agent_votes":        votes,
        }
        # 채택 기준 (다수결):
        # - participating ≥ 2 AND agree > oppose → agreed
        # - participating == 1 AND severity critical/high → pending (동료 검토 대기)
        # - 그 외 → rejected
        if participating >= 2 and agree_cnt > oppose_cnt:
            agreed_changes.append(item)
        elif participating == 1 and best_sev in CRITICAL_SEVERITY:
            item["pending_reason"] = "1인 제기 critical/high — 동료 검토 필요"
            pending_solo_changes.append(item)
        else:
            rejected_changes.append(item)

    # --- 품질 점수 평균 ---
    qualities = [a["quality"] for a in agents_data if a["quality"] is not None]
    overall = round(sum(qualities) / len(qualities), 1) if qualities else 5.0

    prev_q = None
    prev_path = session_dir / f"round-{round_num - 1}" / "votes.json"
    if prev_path.exists():
        try:
            prev_q = float(json.load(open(prev_path)).get("overall_quality_score") or 0)
        except Exception:
            prev_q = None

    score_change = round(overall - (prev_q if prev_q is not None else overall), 1)

    # --- 심각도/참여도 정렬 ---
    def _sort_key(x):
        return (
            -sev_order.get(x["severity"], 2),
            -x["participating_votes"],
            -x["votes"],
        )

    agreed_changes.sort(key=_sort_key)
    pending_solo_changes.sort(key=_sort_key)
    rejected_changes.sort(key=_sort_key)

    # --- 출력 ---
    out = {
        "total_agents":         agent_count,
        "agreed_changes":       agreed_changes,
        "pending_solo_changes": pending_solo_changes,
        "rejected_changes":     rejected_changes,
        "overall_quality_score": overall,
        "prev_quality_score":   prev_q if prev_q is not None else overall,
        "score_change":         score_change,
        "release_ready":        overall >= 9.0,
        "summary": (
            f"Python voter: 채택 {len(agreed_changes)}건, "
            f"솔로 대기 {len(pending_solo_changes)}건, "
            f"기각 {len(rejected_changes)}건, "
            f"품질 {overall}/10 (변화 {score_change:+.1f})"
        ),
        "voter":         "python",
        "voter_version": 2,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
