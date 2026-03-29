# Agent Shell Test — 2026-03-30

## 테스트 명령
`[SHELL] pwd && ls` (Linux/Mac), `[SHELL] cd && dir /b` (Windows)

## 결과

| 에이전트 | OS | Work Key | cwd | 상태 |
|---|---|---|---|---|
| builder@hongswui-Macmini | darwin | WK-006 | /Users/hongsw | ✅ |
| builder@oah | darwin | WK-009 | /Users/hongmartin | ✅ |
| builder@cmini01 | linux (Pi armhf) | WK-009 | /home/cmini01 | ✅ |
| builder@martin-B650M-K | linux | WK-010 | /home/martin/dev/oah | ✅ |
| builder@Hongui-Macmini | darwin | WK-012 | /Users/hongmartin | ✅ |
| builder@NucBoxG3 | win32 | WK-012 | C:\Users\hongb\dev | ✅ |

## 참고
- NucBoxG3 (Windows): `pwd/ls` 명령 불가 → `cd/dir /b` 사용
- WK-002 orchestrator@Hongui-MacBookPro: ghost entry (프로세스 없음, Phoenix presence 잔류)
- 총 6/6 활성 에이전트 정상 응답

## 서버
- Phoenix 서버: oah.local:4000
- Mix release 빌드: oah-server-darwin-arm64.tar.gz (47MB, ERTS 포함)
