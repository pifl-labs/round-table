#!/usr/bin/env python3
"""Claude 출력에서 JSON 추출 — code-review-orchestrator.sh 내부 헬퍼"""
import sys, re, json

text = sys.stdin.read()

# 1) ```json ... ``` 블록 우선
for pattern in [
    r'```json\s*(\{.*?\})\s*```',
    r'```\s*(\{.*?\})\s*```',
]:
    for m in re.finditer(pattern, text, re.DOTALL):
        try:
            d = json.loads(m.group(1))
            print(json.dumps(d, ensure_ascii=False))
            sys.exit(0)
        except Exception:
            continue

# 2) 가장 바깥쪽 중괄호 쌍 찾기
depth = 0
start = -1
for i, c in enumerate(text):
    if c == '{':
        if depth == 0:
            start = i
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0 and start != -1:
            candidate = text[start:i+1]
            try:
                d = json.loads(candidate)
                print(json.dumps(d, ensure_ascii=False))
                sys.exit(0)
            except Exception:
                start = -1

print('{}')
