# fix-agent — DureClaw 자동 버그 수정 예제

DureClaw를 활용해 여러 AI 에이전트가 협력하여 레포지토리의 버그를 자동으로
분석·수정·검증하는 파이프라인 예제입니다.

---

## 개요

```
Claude Code (오케스트레이터)
  │
  ├─► analyzer-agent    버그 탐지 + 원인 분석
  ├─► fixer-agent       코드 수정 구현
  └─► tester-agent      수정 결과 검증 + PR 생성
```

**적합한 상황**:
- CI/CD에서 테스트 실패한 PR 자동 수정
- 알려진 패턴의 버그 일괄 수정 (deprecated API, 보안 취약점 등)
- 원격 머신에서 빌드·테스트 병렬 실행

---

## 사용법

### 1단계: DureClaw 설치

```bash
# Claude Code CLI에서
/plugin marketplace add DureClaw/dureclaw
/plugin install dureclaw@dureclaw
```

### 2단계: fix-agent 실행

Claude Code CLI에서 자연어로:

```
이 레포의 테스트 실패한 파일들을 자동으로 찾아서 수정해줘.
```

또는 Work Key를 지정해서:

```
WK=LN-20260406-001 으로 fix-agent 팀 구성해서 버그 수정 시작해줘
```

---

## 에이전트 구성

### analyzer-agent

**역할**: 코드 정적 분석 + 버그 패턴 탐지

```yaml
# .claude/agents/analyzer.md
---
name: analyzer
role: analyzer
model: opus
---
주어진 레포지토리를 분석하여 다음을 찾아냅니다:
1. 테스트 실패 원인 (스택 트레이스 분석)
2. Lint/타입 에러
3. Deprecated API 사용
4. 보안 취약점 패턴

출력: JSON 형식의 버그 목록 (파일, 라인, 설명, 수정 제안)
```

### fixer-agent

**역할**: 분석 결과를 받아 실제 코드 수정 구현

```yaml
# .claude/agents/fixer.md
---
name: fixer
role: builder
model: opus
---
analyzer-agent의 버그 목록을 받아:
1. 각 버그에 대한 최소 변경 수정 구현
2. 수정 전후 diff 생성
3. 관련 테스트 업데이트 (필요시)

원칙: 수정 범위를 최소화, 사이드 이펙트 없이 수정
```

### tester-agent

**역할**: 수정 결과 검증 + PR 생성

```yaml
# .claude/agents/tester.md
---
name: tester
role: tester
model: sonnet
---
fixer-agent의 수정 결과를 받아:
1. 수정된 파일에 대한 테스트 실행
2. 전체 테스트 스위트 회귀 테스트
3. 성공 시 PR 자동 생성 (gh pr create)
4. 실패 시 fixer-agent에게 재수정 요청
```

---

## 오케스트레이터 워크플로

Claude Code가 다음 순서로 실행합니다:

```
1. TeamCreate
   ├── Work Key 생성
   ├── analyzer, fixer, tester 에이전트 등록
   └── 목표 설정: "레포 버그 자동 수정"

2. TaskCreate → analyzer
   ├── 입력: 레포 경로, 테스트 실패 로그
   └── 출력: bugs.json (버그 목록)

3. TaskCreate → fixer  (analyzer 완료 후)
   ├── 입력: bugs.json
   └── 출력: fixes/ (수정된 파일들)

4. TaskCreate → tester  (fixer 완료 후)
   ├── 입력: fixes/
   ├── 테스트 실행
   └── 성공 → PR 생성 / 실패 → fixer 재실행 (최대 3회)
```

---

## 실제 실행 예시

### 단일 머신 (로컬)

```bash
# Claude Code에서
"packages/agent-daemon/src 에서 TypeScript 타입 에러 찾아서 모두 수정해줘"
```

DureClaw가 자동으로:
1. `bun run typecheck` 실행 → 에러 목록 수집
2. 각 에러 파일 분석 → 수정 구현
3. 재검증 → 에러 0개 확인
4. 커밋 메시지 생성

### 멀티머신 (원격 GPU 서버 활용)

```bash
# 원격 서버에서 heavy test 병렬 실행
PHOENIX=ws://my-server:4000 ROLE=tester bash <(curl -fsSL .../setup-agent.sh)

# Claude Code에서
"원격 tester 에이전트 사용해서 전체 테스트 병렬로 돌려줘"
```

---

## GitHub Actions 통합

PR에서 테스트가 실패하면 자동으로 fix-agent 실행:

```yaml
# .github/workflows/auto-fix.yml
name: Auto Fix
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  auto-fix:
    runs-on: ubuntu-latest
    if: failure()
    steps:
      - uses: actions/checkout@v4
      - name: Start DureClaw Server
        run: |
          USE_DOCKER=1 bash <(curl -fsSL \
            https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-server.sh) &
          sleep 5

      - name: Run fix-agent
        run: |
          claude --print "테스트 실패 원인 분석하고 자동 수정 후 커밋해줘" \
            --allowedTools "Bash,Read,Write,Edit"
```

---

## 참고

- [DureClaw 메인 문서](../../README.md)
- [TeamCreate / TaskCreate API](../../docs/PROTOCOL.md)
- [원격 에이전트 운영](../../docs/REMOTE_AGENT_OPS.md)
