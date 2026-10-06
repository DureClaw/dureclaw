// Node.js 번들 진입점(pages.yml → oah-agent.js). index.ts 의 `#!/usr/bin/env bun` 셰뱅이 있으면 Bun 번들러가
// 대상을 Bun 으로 보고 ws(Bun 내장) 를 번들에서 빼 버려 Node 에서 시작하자마자 죽는다.
import "./index.ts";
