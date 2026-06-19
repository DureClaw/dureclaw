# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/7ed690a2-92e8-4fbd-a0c8-510f6ee3944e" alt="DureClaw Logo" width="100%" />

분산된 디바이스의 AI 에이전트들이 하나의 채널로 묶여 실시간 협력하는 오케스트레이션 인프라.
Claude Code를 오케스트레이터로, 각 머신의 AI 에이전트들을 워커로 연결해 멀티머신 팀을 구성한다.

> *[두레(dure)](https://en.wikipedia.org/wiki/Dure): 조선시대 농민들이 각자의 논에서 마을 전체가 함께 경작하던 협동 시스템.*
> *DureClaw는 그 정신을 AI 에이전트에 담는다 — 각자의 머신에서, 하나의 목표로, 하나의 크루.*

🌐 **한국어** | **[English](./README.en.md)** | **[中文](./README.zh.md)** | **[日本語](./README.ja.md)**

[![GitHub](https://img.shields.io/badge/DureClaw-dureclaw-black?logo=github)](https://github.com/DureClaw/dureclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![npm](https://img.shields.io/badge/npm-%40dureclaw%2Fmcp-red?logo=npm)](https://www.npmjs.com/package/@dureclaw/mcp)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-io.github.dureclaw%2Fmcp-purple?logo=anthropic)](https://registry.modelcontextprotocol.io)
[![Smithery](https://img.shields.io/badge/Smithery-dureclaw%2Fmcp-blue)](https://smithery.ai/server/@dureclaw/mcp)

---

## 핵심 기능

- **멀티머신 AI 팀** — Claude Code 오케스트레이터 + 각 머신의 AI 워커를 Phoenix WebSocket 버스로 묶어 실시간 협력.
- **브레인 노드 위임** — AI 인증(pi)을 마스터 한 곳에만 두고, 키 없는 서브 노드(Windows · RPi Zero 등)는 마스터에 AI 태스크를 위임(`remote-pi` 백엔드 / `/brain/exec`). 저사양·무인증 머신도 즉시 합류.
- **원격 운영 마커** — `[SHELL]`(명령) · `[WRITE]`/`[WRITE:b64]`(파일 생성) · `[SCREENSHOT]`(화면 캡처) · `[EVAL]`/`[GRADE]`(평가)로 원격 머신을 SSH 없이 진단·제어.
- **RSI 학습 루프 + 결정론적 스킬** — 5단계 학습 루프(관측 → 종합 → 목적화 → 지식화 → 학습·선택)로 마스터가 1회 판단한 정책을 엣지의 결정론적 스킬로 결정화. 반복 판단 비용을 제거(실측: 거리 판정 ~6 s → ~36 µs, **약 4만 배**).
- **물리 세계 접점** — GPIO·센서·시리얼 등 엣지 하드웨어를 버스에 연결(HC-SR04 거리 → 신호등, 가상 시리얼 포트 → 실시간 파형 시각화).

---

## 지원 환경 — DureClaw 패밀리

마스터(Claude)가 **두뇌**, 각 노드는 **서로 다른 손**입니다. 같은 버스(Phoenix Channel)·같은 keyless 위임으로 어떤 환경이든 fleet에 합류합니다.

**네이티브 노드 / Native nodes** — 버스 우선 설계, 한 줄 합류, keyless:

| Repo | 손의 종류 | 환경 |
|------|----------|------|
| **[edgeclaw](https://github.com/DureClaw/edgeclaw)** | OS·물리 — shell·sensor·GPIO·LED·부저·릴레이·신호탑·PA 음성 (승인=물리 결과) | 단일 정적 Go 바이너리(No-CGo). **Win·macOS·Linux·Pi Zero(armv6)·arm64·riscv64·loong64·mips64le**. physical-edge는 gpiochip 노출 모든 Linux(Pi·Jetson·산업 게이트웨이). [사전빌드 릴리즈 + 설치 원라이너](https://github.com/DureClaw/edgeclaw/releases/latest) |
| **[webclaw](https://github.com/DureClaw/webclaw)** | 브라우저 — fetch·DOM (CORS-free, 상시) | Chrome MV3 확장, 순수 JS |
| **[deskclaw](https://github.com/DureClaw/deskclaw)** | 데스크톱 GUI — 스크린샷·클릭·타이핑·키·앱실행 + **RPA record→replay**(LLM 1회 학습→무LLM 재생) | **Windows·macOS**, 순수 Go/No-CGo(OS 내장 도구). [사전빌드 릴리즈](https://github.com/DureClaw/deskclaw/releases/latest) |

**어댑터 / Adapters** — 기존 오픈소스 도구에 `dureclaw/` 브리지를 더해 합류:
[picoclaw](https://github.com/DureClaw/picoclaw)(Go) · [nanobot](https://github.com/DureClaw/nanobot)(Py) · [zeroclaw](https://github.com/DureClaw/zeroclaw)(Rust) · [nullclaw](https://github.com/DureClaw/nullclaw)(Zig).

**문서·데모 / Docs & demo** — [📄 기술 백서(한국어/English PDF)](https://github.com/DureClaw/whitepaper) · [🏭 dure-factory — 분산 엣지 × 제조 MES 데모](https://github.com/DureClaw/dure-factory-public). 전체 조직: **[github.com/DureClaw](https://github.com/DureClaw)**.

> **edge**claw(OS·물리) · **web**claw(브라우저) · **desk**claw(데스크톱 GUI) = 네이티브 노드 | pico·nano·zero·null = 기존 도구 어댑터. 모두 같은 버스, 같은 keyless 위임.

### 제조 현장 하드웨어 조합 / Manufacturing hardware kits

실제 제조공정에 바로 설치하는 권장 조합. 모두 **keyless**(엣지에 키 0, 마스터가 두뇌) · **한 줄 설치**. 제품은 *예시*이며 동등 사양 대체 가능.

| 역할 / Role | 권장 하드웨어 | 실행 노드 | 제품 링크 |
|---|---|---|---|
| 📏 거리·근접 센싱 | Raspberry Pi Zero 2 W + HC-SR04 초음파 | `edgeclaw · sensor` | [Pi Zero 2 W](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/) · [HC-SR04](https://www.adafruit.com/product/3942) |
| 🌡 금형·설비 온도 | Raspberry Pi 4·5 + MAX31855 + K형 열전대 | `edgeclaw · sensor` | [Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) · [MAX31855](https://www.adafruit.com/product/269) |
| 🚦 신호탑·안돈 (승인=물리) | Pi + 5V 릴레이 모듈 + 산업 신호탑(패트라이트) + 부저 | `edgeclaw · physical-edge` | [릴레이](https://www.adafruit.com/product/2935) · [PATLITE 신호탑](https://www.patlite.com/product/signal_towers.html) |
| 👁 비전 검사 | NVIDIA Jetson Orin Nano + USB 산업 카메라 | `edgeclaw + 마스터 비전` | [Jetson Orin Nano](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/) · [Arducam](https://www.arducam.com/) |
| 🔌 현장 게이트웨이·PLC | 산업용 팬리스 IPC(x86) + USB-RS485(Modbus RTU) | `edgeclaw · shell/serial` | [USB-RS485](https://www.waveshare.com/usb-to-rs485.htm) · [Advantech IPC](https://www.advantech.com/en/products/embedded-box-pcs) |
| 🖥 현장 PC GUI 자동화 | 기존 Windows 현장 PC (MES·ERP 화면) | `deskclaw · RPA` | 기존 PC 자산 (추가 HW 0) |
| 🔊 음성 안내(PA) | Raspberry Pi + USB 사운드카드 + 스피커 | `edgeclaw · audio` | 범용 USB 오디오 (WAV 내장) |

#### 통신 프로토콜 게이트웨이 — 기존 설비·PLC를 버스에

설비가 쓰는 산업 프로토콜을 게이트웨이로 표준화해 edgeclaw가 수집한다(edgeclaw는 게이트웨이 옆 또는 산업용 리눅스 GW 위에서 구동).

| 프로토콜 / 용도 | 대표 게이트웨이 | 링크 |
|---|---|---|
| 시리얼(RS-232/422/485) → Ethernet | Moxa NPort 5100 | [NPort 5100](https://www.moxa.com/en/products/industrial-edge-connectivity/serial-device-servers/general-device-servers/nport-5100-series) |
| Modbus RTU/ASCII ↔ Modbus TCP | Moxa MGate MB3180/3280/3480 | [MGate MB3000](https://www.moxa.com/en/products/industrial-edge-connectivity/protocol-gateways/modbus-tcp-gateways/mgate-mb3180-mb3280-mb3480-series) |
| Modbus ↔ PROFINET / EtherNet/IP | Moxa MGate 5103 | [MGate 5103](https://www.moxa.com/en/products/industrial-edge-connectivity/protocol-gateways/profinet-gateways/mgate-5103-series) |
| OPC-UA ↔ Modbus/EtherNet-IP/PROFINET | Advantech EKI-1242IEIMS | [EKI OPC-UA](https://www.advantech.com/en-us/products/opc-ua-gateways/sub_38205c82-9338-4a53-8569-23b3fe14328e) |
| MQTT / IIoT (Modbus·serial → MQTT) | Moxa ioThinx 4510 · Advantech ADAM-6000 | [ioThinx](https://www.moxa.com/en/products/industrial-edge-connectivity/controllers-and-ios/advanced-controllers-and-i-os/iothinx-4510-series) · [ADAM-6000](https://www.advantech.com/en-us/products/ethernet-i-o-modules-adam-6000/sub_a67f7853-013a-4b50-9b20-01798c56b090) |
| 멀티 필드버스(PROFIBUS·CC-Link·CANopen·EtherCAT) | HMS Anybus Communicator | [Anybus](https://www.hms-networks.com/anybus) |
| BACnet (빌딩/설비) | HMS Intesis | [Intesis BACnet](https://www.hms-networks.com/p/inbaceip1k20000-ethernet-ip-bacnet-ip-ms-tp-server-gateway) |
| 리눅스 엣지 GW (edgeclaw 직접 구동) | Advantech UNO-2271G V3 | [UNO-2271G](https://www.advantech.com/en-us/products/1-2mlj9a/uno-2271g-v3/mod_25219c02-4050-4154-bfce-fe18246c028b) |

> 참고: Moxa MGate **5119/5134는 OPC-UA가 아니라 IEC 61850/BACnet**용 → OPC-UA는 Advantech EKI 라인으로 표기. HMS/Intesis는 프로토콜 조합별 SKU가 많으니 실제 도입 시 양쪽 프로토콜에 맞는 정확한 SKU 선택.

#### Pi는 한 예시 — 저비용 보드도 동일 바이너리

edgeclaw는 단일 정적 Go 바이너리(**arm64·armv7·armv6·riscv64·amd64**)로 빌드 → 아래 보드는 **edgeclaw 릴리즈 바이너리를 그대로** 받아 설치(어댑터 [picoclaw](https://github.com/DureClaw/picoclaw)는 Sipeed 계열 포크). 한국산 **Hardkernel ODROID** 포함.

| 보드 / Board | 칩·아키텍처 | edgeclaw 바이너리 | 링크 |
|---|---|---|---|
| Raspberry Pi Zero 2 W / 4 / 5 | arm64 (Zero=armv6) | [`linux-arm64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-arm64) · [`armv6`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-armv6) | [raspberrypi.com](https://www.raspberrypi.com/products/) |
| 🇰🇷 Hardkernel ODROID-C4 / N2+ / M1S | arm64 (Amlogic/RK) | [`linux-arm64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-arm64) | [hardkernel.com](https://www.hardkernel.com/product-category/odroid-board/) |
| 🇰🇷 Hardkernel ODROID-H4 | x86_64 (Intel) | [`linux-amd64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-amd64) | [hardkernel.com](https://www.hardkernel.com/product-category/odroid-board/) |
| Sipeed Lichee Pi 4A | RISC-V (TH1520) | [`linux-riscv64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-riscv64) | [sipeed.com](https://sipeed.com/) |
| Sipeed Maix K230 _(K210은 MCU·리눅스 미지원)_ | RISC-V (C908) | [`linux-riscv64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-riscv64) | [wiki.sipeed](https://wiki.sipeed.com/) |
| Milk-V Duo / Mars | RISC-V (SG200x/JH7110) | [`linux-riscv64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-riscv64) | [milkv.io](https://milkv.io/) |
| Radxa Rock 시리즈 | arm64 (RK3588 등) | [`linux-arm64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-arm64) | [radxa.com](https://radxa.com/) |
| Orange Pi | arm64 (일부 RISC-V) | [`linux-arm64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-arm64) · [`riscv64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-riscv64) | [orangepi.org](http://www.orangepi.org/) |
| BeagleBone Black / AI | armv7 / arm64 | [`linux-armv7`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-armv7) · [`arm64`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-arm64) | [beagleboard.org](https://www.beagleboard.org/) |
| Luckfox Pico | ARM Cortex-A7 (armv7) | [`linux-armv7`](https://github.com/DureClaw/edgeclaw/releases/latest/download/edgeclaw-linux-armv7) | [luckfox.com](https://www.luckfox.com/) |

> 모든 칩·아키텍처는 edgeclaw가 **실제 빌드·릴리즈하는 타깃**(`make all` → `dist/edgeclaw-linux-{arm64,armv7,armv6,riscv64,amd64,…}`)이다.

#### 🇰🇷 국산 대안 / 한국 업체 — 글로벌 제품 대체

| 분류 | 국내 업체 | 대표 제품 | 링크 |
|---|---|---|---|
| 신호탑·타워램프 (PATLITE 대안) | 큐라이트 · 카콘 | LED 타워램프·표시등 (ST/QTC, IO-Link) | [Qlight](https://www.qlight.com/kr/) · [KACON](https://www.kacon.co.kr/) |
| 센서·온도조절기·계측 | 오토닉스 · 한영넥스 | PID 온도조절기·근접/광센서·패널미터 | [Autonics](https://www.autonics.com/kr) · [한영넥스](https://hanyoungnux.co.kr/) |
| 시리얼↔이더넷 (Moxa NPort 대안) | 솔내시스템 · 위즈넷 | 시리얼 디바이스 서버(CSE), WIZ750SR·W5500 | [Sollae](https://www.sollae.co.kr/ko/home/) · [WIZnet](https://www.wiznet.io/) |
| PLC·산업제어 | LS일렉트릭 · 컴파일 | XGT/XGB PLC, CUBLOC 임베디드 컨트롤러 | [LS ELECTRIC](https://www.ls-electric.com/ko) · [Comfile](https://www.comfile.co.kr/) |
| SBC·엣지 컴퓨터 | 하드커널 (Hardkernel) | ODROID (arm64 / x86) | [Hardkernel](https://www.hardkernel.com/product-category/odroid-board/) |
| 비전 카메라 | 위드로봇 (Withrobot) | oCam USB3.0 산업 카메라(UVC) | [Withrobot](https://withrobot.com/) |

#### 국내 총판 / 구매처

- **Moxa**: [여의시스템(대표총판)](https://www.yoisys.com/) · [위존](https://moxa.wezon.com/) · [목사스토어](https://www.moxastore.co.kr/)
- **Advantech**: [어드밴텍 한국](https://www.advantech.com/ko-kr) · [어드밴텍코리아](https://advantech.co.kr/)
- **HMS · Anybus · Red Lion**: [anybus.com](https://www.anybus.com/) (한국 영업 본사 채널 통합)
- **부품·게이트웨이 유통**: [디바이스마트(MGate 검색)](https://www.devicemart.co.kr/goods/search?searchKeyword=MGate) · [엘레파츠](https://www.eleparts.co.kr/) · [메카솔루션](https://www.mechasolution.com/) · [RS Korea](https://kr.rs-online.com/web/) · [Mouser Korea](https://kr.mouser.com/)

> 노드 설치: `curl -fsSL https://github.com/DureClaw/edgeclaw/releases/latest/download/install.sh | sh`

---

## 실제 동작 예시

> "두레클로로 네가 실행가능하지 않을 ?" — 한 마디로 리눅스 빌더에 태스크가 넘어간다.

![DureClaw 실제 동작 — 자연어 명령 → 리눅스 빌더 태스크 디스패치](./docs/screenshots/dureclaw-demo.png)

**흐름**:
1. 사용자가 자연어로 "두레클로로 실행해" 요청
2. Claude Code가 Work Key(`LN-20260501-001`)를 발급하고 리눅스 빌더에 태스크 전송
3. 각 단계(llmfit 설치 → 시스템 스택 확인)가 순차적으로 원격 머신에서 실행됨

---

## 설치

> 한 줄 요약: `(1) 마켓플레이스 추가 → (2) 플러그인 설치 → (3) /reload-plugins → (4) /dureteam-status` 까지만 해도 Claude Code 안에서 즉시 사용 가능합니다.

### Step 1 — 마켓플레이스 추가

Claude Code 프롬프트에 그대로 입력하세요.

```
/plugin marketplace add DureClaw/dureclaw
```

기대 출력:
```
Successfully added marketplace: dureclaw
```

---

### Step 2 — 플러그인 설치

```
/plugin install dureclaw@dureclaw
```

기대 출력:
```
✓ Installed dureclaw. Run /reload-plugins to apply.
```

> 수동 MCP 등록만 필요한 경우: `oah setup-mcp` 또는 `curl -fsSL https://dureclaw.baryon.ai/scripts/setup-mcp.sh | bash`

---

### Step 3 — 플러그인 리로드 (필수)

설치 후 **반드시 한 번** 실행해야 슬래시 커맨드·스킬·에이전트가 활성화됩니다.

```
/reload-plugins
```

기대 출력 (예시):
```
Reloaded: N plugins · M skills · K agents · ...
```

> 로드 에러가 1건 정도 표시될 수 있습니다. `/doctor`로 상세 내용을 확인하되, DureClaw 자체 사용에는 보통 영향이 없습니다.

---

### Step 4 — 첫 실행 명령 (여기서부터 바로 사용)

리로드가 끝나면 다음 셋 중 무엇이든 입력해 보세요. 모두 동일한 진입점입니다.

```
/dureteam-status                         ← 슬래시 커맨드
"두레팀 상태 알려줘"                   ← 한국어 자연어 (그냥 "팀"이 아닌 "두레팀")
"두레팀 알려줘" / "show DureClaw team"  ← 영문/혼합도 OK
```

처음에는 “팀 없음 / Phoenix 서버 미연결” 상태가 정상입니다. 로컬 한 대로 끝낼 거라면 여기까지로 충분합니다 — Claude Code 자체가 오케스트레이터이고, 곧바로 태스크를 처리합니다.

멀티머신으로 확장할 거면 Step 5로 진행하세요.

---

### Step 5 — Phoenix 서버 실행 (멀티머신 확장 시에만)

다른 머신과 협업하려면 메시지 버스 역할을 할 Phoenix 서버를 한 곳(보통 메인 데스크톱/서버)에 띄워야 합니다.

#### 5-A. 자동 실행 (가장 쉬움)

Claude Code 안에서:

```
/setup-team
```

또는 자연어:

```
"두레팀 설정해줘"   "두레팀에 워커 추가해줘"   "setup DureClaw team"
```

자동으로 진행되는 순서:
1. Phoenix 서버 상태 확인 → 없으면 설치 (**Elixir 불필요 — Docker 또는 사전빌드 바이너리 자동 선택**)
2. 서버 IP 감지 (Tailscale 우선)
3. 현재 온라인 에이전트 목록 출력
4. 원격 머신용 워커 설치 명령 자동 생성 (macOS / Linux / Windows)

#### 5-B. 수동으로 서버만 띄우기

```bash
bash <(curl -fsSL https://dureclaw.baryon.ai/server)
```

옵션:

```bash
# 포트 변경
PORT=8080 bash <(curl -fsSL https://dureclaw.baryon.ai/server)

# Docker 강제 (Elixir 없는 머신)
USE_DOCKER=1 bash <(curl -fsSL https://dureclaw.baryon.ai/server)

# docker compose
docker compose up
```

성공 시 출력:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 DureClaw Phoenix Server
 Port    : 4000
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Tailscale 연결됨: 100.x.x.x
✅ 설치 완료
```

> 서버 프로세스는 포그라운드(blocking) 로 실행됩니다. 백그라운드로 띄우려면 `nohup … &` 또는 `tmux/screen`을 사용하세요.

---

### Step 6 — 워커 에이전트 설치 (각 원격 머신)

Phoenix 서버가 떠 있으면, 다른 머신에서 워커를 연결합니다.

**가장 쉬운 방법** — Claude Code에 자연어로:

```
"두레팀에 워커 추가해줘"   "두레팀 tester 머신 연결"   "두레팀에 Mac Mini 추가해줘"
```

Claude가 서버 IP를 감지해 **바로 복사·실행 가능한 한 줄 명령**을 OS·아키텍처별로 알려줍니다. Tailscale이 없어도 설치까지 단계별로 안내합니다.

수동 설치 명령은 [분산 서브 에이전트 추가 — OS·아키텍처별 1줄 설치](#분산-서브-에이전트-추가--os아키텍처별-1줄-설치) 섹션 참고.

---

## 아키텍처

```
① Claude Code (오케스트레이터, 맥북)
     /plugin install dureclaw@dureclaw
   └─ MCP (oah-mcp) → Phoenix WebSocket

② Phoenix Server (메시지 버스)
     bash <(curl -fsSL .../setup-server.sh)   ← Docker 또는 사전빌드 바이너리
   ws://host:4000

③ oah-agent (워커, 각 머신)
     PHOENIX=ws://host:4000 ROLE=builder bash <(curl -fsSL .../setup-agent.sh)
   → WebSocket 연결 → task.assign 수신
   → AI 백엔드 실행 (claude / pi / gemini / ollama)
     · 인증 키가 없으면 → remote-pi 로 마스터 브레인에 위임
   → task.result 반환
```

### 브레인 노드 위임 (키 없는 노드도 합류)

AI CLI 인증(pi 등)은 **마스터 한 곳**에만 두고, 키가 없는 서브 노드는 AI 태스크를 마스터에 위임합니다. Windows·RPi Zero처럼 인증을 두기 어렵거나 로컬에서 모델을 못 돌리는 머신도 그대로 팀에 합류할 수 있습니다.

```
마스터 (BRAIN_SERVE=1)
   └─ /brain/exec  (Bun.serve :4111, Bearer BRAIN_TOKEN)  ← pi 인증 보유
        ▲
        │ remote-pi 백엔드로 AI 태스크 위임
서브 노드 (BRAIN_URL=http://master:4111, BRAIN_TOKEN=…)
   └─ 로컬엔 키/모델 없음 — SHELL·WRITE·SCREENSHOT 등은 로컬 실행, AI 판단은 마스터에 위임
```

- 마스터: `BRAIN_SERVE=1 BRAIN_TOKEN=<secret>` 로 데몬 기동 → `/brain/exec` 노출
- 서브: 워커 설치 시 `BRAIN_URL`·`BRAIN_TOKEN` 전달 → 백엔드 자동으로 `remote-pi` 선택(로컬 pi 설치 불필요)

---

## 패키지 구조

```
dureclaw/
├── .claude-plugin/             Claude Code 플러그인 메타데이터
│   ├── plugin.json
│   └── marketplace.json
│
├── commands/                   슬래시 커맨드 (/setup-team, /dureteam-status)
├── agents/                     에이전트 정의 (orchestrator 등)
├── skills/                     DureClaw 오케스트레이션 스킬 (dureclaw, dureclaw-run)
│
├── packages/
│   ├── phoenix-server/         Elixir/Phoenix 메시지 버스 (핵심)
│   ├── agent-daemon/           WebSocket 에이전트 데몬 (oah-agent)
│   ├── oah-mcp/                Claude Code MCP 서버 (@dureclaw/mcp)
│   └── ctl/                    oah-ctl 관리 CLI
│
└── scripts/
    ├── setup-server.sh         Phoenix 서버 설치
    ├── setup-agent.sh          워커 에이전트 설치 (oah 명령어)
    ├── setup-mcp.sh            Claude Code MCP 등록
    └── oah                     통합 CLI
```

---

## 사용법

플러그인 설치 후 Claude Code에서 바로 사용합니다:

```
# 팀 상태 확인
/dureteam-status

# 멀티머신 팀 확장 (Phoenix 서버 + 워커 에이전트 자동 설정)
/setup-team

# 에이전트에게 태스크 전송
mcp__oah__send_task(to: "builder@mac-mini", instructions: "[SHELL] make build")

# 온라인 에이전트 목록
mcp__oah__get_presence
```

### 사용 가능한 MCP 도구

`get_presence` · `send_task` · `receive_task` · `complete_task` · `read_state` · `write_state` · `read_mailbox` · `post_message`

> 전체 도구 명세 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

### 태스크 마커 — 원격 머신 진단·제어

`instructions` 첫머리의 마커로 원격 노드에서 SSH 없이 작업을 지시합니다.

| 마커 | 동작 | 예시 |
|------|------|------|
| `[SHELL]` | 셸 명령 실행 | `[SHELL] mix test` |
| `[WRITE] <path>` | 파일 생성(본문 = 내용) | `[WRITE] /tmp/run.sh\n#!/bin/bash …` |
| `[WRITE:b64] <path>` | base64 파일 배포(바이너리·따옴표 안전) | 스크립트/이미지 원격 배포 |
| `[SCREENSHOT]` | 화면 캡처 → `image`(base64) 반환 | `[SCREENSHOT]` |
| `[EVAL]` / `[GRADE]` | 산출물 평가·채점 (RSI 루프) | self-score / evaluator |
| (마커 없음) | AI 백엔드로 자유 프롬프트 실행 | `이 레포 버그 찾아줘` |

> 마스터에서 임의 노드로 파일 배포+실행: `scripts/oah_deploy.sh <node> <local> <remote> --run "<cmd>"`

### 분산 서브 에이전트 추가 — OS·아키텍처별 1줄 설치

> **`SERVER_IP`** = Phoenix 서버 IP (Tailscale IP 권장). `ROLE`은 `builder` / `tester` / `executor` 중 선택.

#### macOS · Linux — x64 / arm64 (M1·M2·M3·M4)

```bash
PHOENIX=ws://SERVER_IP:4000 ROLE=builder bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)
```

#### Linux — armv7l (Raspberry Pi 4 · 5 · 32bit OS)

```bash
PHOENIX=ws://SERVER_IP:4000 ROLE=executor bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)
```

> 자동으로 Node.js + `oah-agent.js` 번들을 선택합니다.

#### Linux — armv6l (Raspberry Pi Zero W)

```bash
PHOENIX=ws://SERVER_IP:4000 ROLE=executor bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)
```

> 자동으로 Python 에이전트(`agent.py`)를 선택합니다. Node.js 불필요.

#### Windows — PowerShell (x64)

```powershell
$env:PHOENIX="ws://SERVER_IP:4000"; $env:ROLE="builder"; iex (irm https://dureclaw.baryon.ai/agent.ps1)
```

#### Windows — CMD (x64)

```cmd
set PHOENIX=ws://SERVER_IP:4000&& set ROLE=builder&& curl -fsSL https://open-agent-harness.baryon.ai/agent.bat -o %TEMP%\oah.bat && call %TEMP%\oah.bat
```

#### 옵션: Work Key 지정 · Role 목록

```bash
# Work Key 수동 지정 (미지정 시 서버에서 최신 WK 자동 조회)
PHOENIX=ws://SERVER_IP:4000 ROLE=tester WK=LN-20260418-001 bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)

# 사용 가능한 ROLE
#   builder   — 코드 작성·빌드 (기본값)
#   tester    — 테스트 실행·검증
#   executor  — 경량 명령 실행 (RPi 등 저사양 최적)
#   analyst   — 코드 분석·리뷰
```

| OS | 아키텍처 | 자동 선택 에이전트 | AI 백엔드 |
|----|---------|-----------------|---------|
| macOS | arm64 (Apple Silicon) | 네이티브 바이너리 | claude-cli · pi · gemini |
| macOS | x64 (Intel) | 네이티브 바이너리 | claude-cli · pi |
| Linux | x64 · arm64 | 네이티브 바이너리 | claude-cli · pi · ollama |
| Linux | armv7l (RPi 4/5) | Node.js + oah-agent.js | claude-cli · 브레인 위임 |
| Linux | armv6l (RPi Zero W) | Python + agent.py | 브레인 위임(remote-pi) · 로컬 결정론 스킬 |
| Windows | x64 | PowerShell / CMD | claude-cli · pi |

### 구성도

```
Claude Code (오케스트레이터)
  │  MCP (oah-mcp)
  ▼
Phoenix Server              ws://host:4000
  │  Phoenix Channel
  ├──▶ oah-agent (맥미니)   builder@mac-mini
  ├──▶ oah-agent (GPU 서버) builder@gpu-server
  └──▶ oah-agent (라즈파이)  executor@raspi
          └─ AI 백엔드 실행 → task.result 반환
```

---

## REST API

주요 엔드포인트: `/api/health` · `/api/presence` · `/api/work-keys` · `/api/state/:wk` · `/api/task` · `/api/mailbox/:agent`

> 전체 API 명세 및 Phoenix Channel 프로토콜 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

---

---

## 스크린샷

### 플랫폼별 설치 & 연결

| 플랫폼 | 설치 출력 |
|--------|----------|
| macOS Apple Silicon | `✅ darwin-arm64 바이너리 다운로드 완료` → `→ 서버 시작 · ws://100.x.x.x:4000` |
| Linux x86_64 (GPU 서버) | `✅ linux-x86_64 에이전트 설치 완료` → `✅ claude-cli 감지됨` → `→ builder@gpu-server 연결 완료` |
| Raspberry Pi 4/5 | `✅ linux-arm64 에이전트 설치 완료` → `✅ pi 감지됨` → `→ executor@raspberrypi 연결 완료` |
| Raspberry Pi Zero W | `✅ Python 에이전트 모드 (armv6)` → `→ 브레인 위임(remote-pi)` → `→ executor@zero-w 연결 완료 (WiFi)` |
| Windows (PowerShell) | `✅ 워커 설치 완료` → `→ 브레인 위임(remote-pi)` → `→ builder@DESKTOP-WIN 연결 완료` |

### 에이전트 역할별

| Role | AI 백엔드 | 실행 예시 |
|------|----------|---------|
| `builder` | claude-cli / pi / codex | `[SHELL] make build` → 코드 작성·빌드 |
| `tester` | claude-cli / pi | `[SHELL] pytest tests/` → 테스트 실행·검증 |
| `analyst` | claude-cli / gemini | 코드 분석·리뷰·버그 탐지 |
| `executor` | 브레인 위임 / 결정론 스킬 | 경량 명령·센서 실행 · RPi Zero W 최적 |

### 실제 대화 — 자연어 → 원격 실행

**"두레클로로 네가 실행가능하지 않을 ?" 한 마디에 리눅스 빌더로 태스크 자동 전달**

![DureClaw 실제 동작 예시](./docs/screenshots/dureclaw-demo.png)

### 대시보드

> 실시간 에이전트 현황 및 태스크 모니터링: `http://서버IP:4000/`

**라이브 데모 — 탭 전환 시연 (GIF)**

![DureClaw 대시보드 데모](./docs/screenshots/dureclaw-dashboard-demo.gif)

**태스크 디스패치 & 멀티 에이전트 현황 (6개 디바이스 동시 연결)**

![DureClaw 대시보드 — 태스크 디스패치](./docs/screenshots/02-task-dispatch.png)

**에이전트 상세 — 각 머신의 capability 실시간 확인**

![DureClaw 대시보드 — 에이전트 상세](./docs/screenshots/03-agent-presence.png)

---

## 지원 환경

| 플랫폼 | 아키텍처 | 서버 | 워커 | 비고 |
|--------|----------|------|------|------|
| macOS (Apple Silicon) | arm64 | ✅ 사전빌드 | ✅ | M1/M2/M3/M4 |
| macOS (Intel) | x86_64 | ✅ 사전빌드 | ✅ | |
| Linux | x86_64 | ✅ 사전빌드 | ✅ | Ubuntu/Debian/CentOS |
| **Raspberry Pi 4/5** | **arm64** | ✅ 사전빌드 | ✅ | **executor 역할 최적** |
| **Raspberry Pi Zero W/2W** | **armv6/arm64** | ❌ | ✅ Python | **WiFi 내장 · IoT executor** |
| Windows 10/11 | x86_64 | 🐳 Docker | ✅ PowerShell | |
| Docker (모든 플랫폼) | any | ✅ | — | `ghcr.io/dureclaw/dureclaw` |

> **Raspberry Pi**: `PHOENIX=ws://서버IP:4000 ROLE=executor bash <(curl -fsSL https://dureclaw.baryon.ai/agent)` 한 줄로 연결.

---

## 선행 설치 조건

| | 필요한 것 | 설치 |
|--|----------|------|
| **필수** | [Claude Code CLI](https://claude.ai/download) | 오케스트레이터 |
| **멀티머신** | [Tailscale](https://tailscale.com/download) | 원격 머신 간 사설망 (무료, 100대) |

나머지(Phoenix 서버, oah-agent)는 **사전빌드 바이너리를 자동 다운로드**하므로 별도 설치가 필요 없습니다.

---

## 문서

| 문서 | 설명 |
|------|------|
| [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) | **개발 가이드** — 테스트, Phoenix Channel 프로토콜, PR 기여 방법 |
| [docs/PROTOCOL.md](./docs/PROTOCOL.md) | **프로토콜 명세** — 4계층 통신 프로토콜 공식 정의 (L1 네트워크 ~ L4 팀 프로토콜) |
| [docs/PRIVATE_NETWORK.md](./docs/PRIVATE_NETWORK.md) | **사설망 구성** — Tailscale로 원격 에이전트를 하나의 팀으로 연결하는 방법 |
| [docs/REMOTE_AGENT_OPS.md](./docs/REMOTE_AGENT_OPS.md) | **원격 에이전트 운영** — 원격지 에이전트를 실시간 진단·명령·복구하는 방법 |
| [docs/REPORT_edge-brain-traffic-light.md](./docs/REPORT_edge-brain-traffic-light.md) | **엣지-브레인 결정론 사례** — HC-SR04 신호등 + 마스터 1회 판단 → 엣지 결정론 스킬(약 4만 배 가속) |
| [docs/AGENTS.md](./docs/AGENTS.md) | 에이전트 역할 정의 |
| [docs/METHODOLOGY.md](./docs/METHODOLOGY.md) | 워크루프 방법론 |
| [docs/GAP_ANALYSIS.md](./docs/GAP_ANALYSIS.md) | 현재 상태 및 개선 방향 |
| [docs/INSTALL.md](./docs/INSTALL.md) | 설치 가이드 |
| [docs/ECOSYSTEM_ANALYSIS.md](./docs/ECOSYSTEM_ANALYSIS.md) | 에코시스템 분석 (ClawFit, 경쟁 도구 비교) |

---

## 활용사례

| 예제 | 설명 |
|------|------|
| [fix-agent](./examples/fix-agent/) | 여러 AI 에이전트가 협력해 레포지토리 버그를 자동 분석·수정·PR 생성 |

```
Claude Code → analyzer-agent (버그 탐지)
           → fixer-agent    (코드 수정)
           → tester-agent   (검증 + PR 생성)
```

---

### 실사례 — GPU 서버에 AI 모델 원격 설치·운용

> **상황**: 맥북으로 작업하는데, 다른 방에 RTX 4090 Linux 서버가 있다. SSH 없이 Claude Code 안에서 모델 설치부터 API 서빙까지 끝냈다.

#### 구성

```
MacBook (Claude Code + DureClaw 오케스트레이터)
  │  Tailscale VPN
  ▼
Linux GPU 서버 (RTX 4090 24GB)
  └─ oah-agent [builder 역할]
  └─ ollama 서비스
  └─ Open WebUI (포트 8080)
```

#### 실행 흐름

**1단계** — DureClaw로 에이전트 상태 확인

```
/dureteam-status
→ builder@gpu-server [builder] nvidia-gpu, ollama, docker, ...
```

**2단계** — SHELL 태스크로 모델 설치 원격 실행

```python
# Claude Code 안에서 DureClaw로 dispatch
POST /api/task {
  "task_id": "pull-gemma4-31b",
  "to": "builder@gpu-server",
  "instructions": "[SHELL] ollama pull gemma4:31b"
}

# 결과 조회
GET /api/task/pull-gemma4-31b
→ { "status": "done", "output": "success", "exit_code": 0 }
```

**3단계** — 어디서나 API 접근 (Tailscale)

```bash
# Tailscale VPN에 연결된 어느 기기에서나
curl http://gpu-server-tailscale-ip:11434/v1/chat/completions \
  -d '{"model":"gemma4:31b","messages":[{"role":"user","content":"안녕"}],"think":false}'
```

**4단계** — 웹 채팅 인터페이스 원격 설치

```python
# Open WebUI Docker 원격 실행
POST /api/task {
  "instructions": "[SHELL] docker run -d --name open-webui --network=host \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    ghcr.io/open-webui/open-webui:main"
}
# → http://gpu-server:8080 에서 멀티유저 채팅 UI 즉시 사용 가능
```

#### 결과

| 항목 | 내용 |
|------|------|
| 설치한 모델 | gemma4:31b (19.9 GB), 이전 17개 포함 총 18개 |
| 추론 속도 | ~19 tok/s (thinking 모드 끄면 체감 빠름) |
| 접근 방법 | Tailscale VPN → 어느 기기에서나 `http://gpu-server:11434` |
| 관리 UI | Open WebUI `http://gpu-server:8080` |
| SSH 사용 여부 | **없음** — 전부 DureClaw SHELL 태스크로 처리 |

> Tailscale을 쓰면 GPU 서버가 회사 내부망이든 집이든 상관없이 `ws://서버-tailscale-ip:4000` 한 줄로 연결됩니다.

#### 사용 모델 목록 (예시)

```bash
curl http://gpu-server:11434/api/tags | jq '.models[].name'
# gemma4:31b, qwen3:32b, deepseek-r1:32b, qwen3-coder:30b ...
```

용도별 추천:
| 용도 | 모델 | 속도 |
|------|------|------|
| 일반 대화 | `gemma4:31b` | ~19 tok/s |
| 빠른 응답 | `gemma3:27b` | ~49 tok/s |
| 코딩 | `qwen3-coder:30b` | ~22 tok/s |
| 추론/수학 | `deepseek-r1:32b` | ~20 tok/s |

---

## 왜 팀이 필요한가 — 이동성·권한·전용 소프트웨어의 한계를 조합으로 넘는다

현실의 컴퓨터는 각자 제약이 다르다.

| 제약 | 예시 | 단일 머신의 한계 |
|-----|------|----------------|
| **OS 전용 소프트웨어** | MS Office, Active X, iOS 빌드(Xcode) | Windows가 아니면 실행 불가 |
| **하드웨어 접근** | GPIO, 카메라, 센서 | RPi만 물리 세계에 연결됨 |
| **이동성** | 현장 점검, 야외 인터뷰 | 서버는 들고 나갈 수 없음 |
| **연산 자원** | GPU 추론, 대용량 빌드 | 노트북 배터리·발열 한계 |
| **네트워크 위치** | 로컬 WiFi, VPN, 공공망 | IP 차단·지역 제한 |
| **권한** | sudo, Admin, 사인 인증서 | 조직 정책으로 일부 머신만 허용 |

DureClaw는 이 제약들을 **팀의 역할 분담**으로 해결한다.

### 실제 팀 — 5가지 아키텍처, 1초 안에 협업

```
🌍 초이동형   executor@cmini01      Raspberry Pi Zero W (손바닥 크기)
               └─ GPIO · I2C · 카메라 · WiFi · 브레인 위임 + 로컬 결정론 스킬
               └─ 어디든 배포 가능, 배터리 구동, 물리 세계 접점

💼 이동형     tester@NUCBOXG3       Windows 11 NucBox (가방 속 미니PC)
               └─ MS Office 전체 · WSL · Claude · Active X 사이트 접근

🏡 반고정형   builder@hongswui-Macmini   macOS arm64 · Apple M4
               └─ Xcode · Swift · iOS 빌드 · Apple Silicon 네이티브

              builder@macmini-intel      macOS x86_64 · i3-8100B
               └─ Flutter · fastlane · Whisper OCR · 멀티클라우드 CLI
               └─ AWS SAM · Azure · Heroku · Terraform · Tesseract

🏠 고정형     builder@martin-B650M-K    Linux x86_64 · RTX 4090
               └─ Docker · Kubernetes · GPU 추론 · 24시간 연산 서버
```

**헬스체크 결과: 5/5 동시 응답 — 0.61초**

### 제약의 조합이 만드는 시나리오

**① 현장 점검 AI** — 이동성 × 연산 자원
```
cmini01 (현장, 주머니)  → 카메라로 장비 촬영
RTX 4090 서버 (원격)   → GPU로 이상 감지 AI 분석
Windows NucBox (현장)  → Excel 보고서 자동 생성·출력
```
> 단일 노트북으로는 현장 이동 + GPU 추론 + Office 자동화를 동시에 할 수 없다.

**② 멀티플랫폼 앱 빌드** — OS 전용 소프트웨어 × 병렬 실행
```
macmini-intel    → Flutter iOS/Android 빌드 (macOS만 가능)
hongswui-M4      → Swift/Xcode 아카이브  (Apple Silicon 네이티브)
martin-B650M-K   → Docker Linux 이미지 + k8s 배포
NUCBOXG3         → Windows 인스톨러 생성·테스트
cmini01          → ARMv6 임베디드 바이너리 검증
```
> 5개 플랫폼 동시 빌드. 순차 실행 대비 **5× 속도**.

**③ IoT 모니터링** — 하드웨어 접근 × 상시 연산
```
cmini01 (어디서나)  → I2C 온습도 · PIR 움직임 · 카메라 스냅샷 (GPIO)
RTX 4090 서버      → 이상 패턴 AI 감지
macmini-intel      → 주간 Excel 대시보드 자동 생성
```
> GPIO를 가진 머신은 cmini01뿐. 연산 서버는 현장에 나갈 수 없다.

**④ 현장 인터뷰 → AI 자동 정리** — 이동성 × 전용 소프트웨어
```
NUCBOXG3 (현장)    → 인터뷰 녹음 (Windows 마이크)
macmini-intel (귀가 후) → Whisper로 음성→텍스트 전사
martin-B650M-K     → Claude로 인사이트 추출
macmini-intel      → Word/Keynote 보고서 자동 생성
```
> 인터뷰 후 보고서 완성: 수 시간 → **15분 자동 처리**

**⑤ 엣지 결정론 — 마스터 1회 판단 → 엣지 결정론 스킬** (RSI 학습 루프)
```
cmini01 (RPi Zero W)  → HC-SR04 거리 측정 → 신호등 LED 제어
마스터 브레인         → 1회만 정책 보정 (red<12cm, yellow<35cm + 근거)
cmini01               → 이후 보정값을 로컬 결정론 스킬로 결정화하여 자율 동작
                      → 거리 신호는 버스로 마스터에 스트리밍(모니터링·이상 탐지)
```
> AI 판단을 매번 호출하지 않는다. 마스터가 **한 번** 판단한 정책을 엣지가 결정론적으로 실행 — 거리 판정 ~6 s → **~36 µs (약 4만 배)**. 5단계 학습 루프(관측 → 종합 → 목적화 → 지식화 → 학습·선택)로 채택 시 스킬이 자동 결정화된다.

### 오픈소스만으로 구현

| 구성 요소 | 라이선스 | 역할 |
|---------|:-------:|------|
| Phoenix (Elixir) | MIT | 실시간 WebSocket 채널 |
| Claude Code CLI | 무료 | AI 오케스트레이터 |
| pi (coding-agent) | MIT | 멀티모델 AI 에이전트 |
| 브레인 위임 (remote-pi) | MIT | 키 없는 엣지가 마스터에 AI 위임 |
| Raspberry Pi OS | GPL | IoT 엣지 OS |

비싼 SaaS 없이, 내 네트워크 안의 유휴 머신들을 연결하는 것만으로 —
**Raspberry Pi Zero W부터 RTX 4090 서버까지 — 하나의 AI 협업 팀이 된다.**

---

## Anthropic Managed Agents 호환성

DureClaw는 [Anthropic Managed Agents](https://docs.anthropic.com/en/docs/agents) 의 **분산 물리 머신 구현체**로 포지셔닝됩니다.

| Anthropic Managed Agents | DureClaw 대응 |
|--------------------------|--------------|
| Agent (model + tools + MCP) | `agent-daemon` process (`capabilities[]` + `preferred_model`) |
| Environment (container) | 각 물리 머신 (macOS / Linux / Windows / RPi) |
| Session (실행 인스턴스) | Work Key `LN-YYYYMMDD-XXX` |
| Events (user → agent) | `task.assign` / `task.progress` / `task.result` |
| SSE 스트리밍 | Phoenix Channel broadcast (WebSocket) |
| 서버사이드 이벤트 히스토리 | DETS (`harness_tasks.dets`) |
| Multi-agent (research preview) | Fan-out/Fan-in 패턴 (현재 구현됨) |

### 멀티 모델 라우팅 (`preferred_model`)

각 에이전트는 자신이 선호하는 AI 모델을 presence 메타데이터에 선언합니다:

```json
{
  "role": "builder",
  "capabilities": ["gemini", "docker", "nvidia-gpu"],
  "preferred_model": "gemini-2.5-pro"
}
```

오케스트레이터는 `task.assign` 시 `requires` 필드로 모델을 지정할 수 있습니다:

```json
{ "instructions": "...", "requires": ["gemini"], "role": "builder" }
```

**모델 우선순위 자동 감지** (`PREFERRED_MODEL` 환경변수로 override 가능):

| 감지 조건 | preferred_model |
|-----------|----------------|
| `PREFERRED_MODEL` env | 명시값 |
| `GEMINI_API_KEY` 또는 `gemini` CLI | `gemini-2.5-pro` |
| `ollama` CLI | `ollama:${OLLAMA_MODEL}` |
| `claude` CLI | `claude-sonnet-4-6` |
| `pi` CLI | `pi/auto` |
| 기본값 | `claude-haiku-4-5` |

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

자세한 내용은 [LICENSE](./LICENSE) 파일을 참조하세요.
