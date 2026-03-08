# Mode B 예시: 병렬 REST API 서버 개발

## 핵심 포인트

단일 에이전트 방식:
```
builder → users.py → items.py → main.py → tests  (순차, 느림)
```

Mode B 방식:
```
agent1 → users.py ──┐
agent2 → items.py ──┤ (동시 진행)
                     ↓
agent3 → main.py + tests (NAS에서 둘 다 직접 읽어서 통합)
```

## 작업 분담

| 에이전트 | 역할 | 담당 파일 |
|---------|------|---------|
| agent1 (builder) | 사용자 API 모듈 | src/users.py |
| agent2 (builder2) | 아이템 API 모듈 | src/items.py |
| agent3 (integrator) | 통합 + 테스트 | src/main.py, tests/ |

## NAS Workspace
```
project2/
  src/
    users.py    ← agent1 작성
    items.py    ← agent2 작성 (동시)
    main.py     ← agent3 통합
  tests/
    test_api.py ← agent3 작성
  artifacts/
    report.md   ← 최종 결과
```
