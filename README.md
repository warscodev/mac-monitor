# MonitorSwitch

맥미니 서브모니터(C27JG50)를 케이블을 뽑지 않고 소프트웨어로 끊었다 붙이는 개인용 메뉴바 앱.

서브모니터 전원 버튼은 **켜 둔 채로** 두고, 신호만 끊어서 모니터가 스스로 절전 모드에 들어가게 한다.

## 기능

| 동작 | 단축키 | 설명 |
|---|---|---|
| 메인만 쓰기 / 듀얼로 전환 | ⌃⌥⌘M | 서브모니터 연결 해제/복구. 해상도(HiDPI)·위치·주사율을 그대로 되돌림 |
| 지금 화면 끄기 | ⌃⌥⌘L | 두 모니터 신호를 바로 끊음 (`pmset displaysleepnow`). 마우스·키보드를 쓰면 다시 켜짐 |
| 모든 디스플레이 다시 켜기 | ⌃⌥⌘R | 비상 복구 |

- **해상도 – 모니터이름** 메뉴: HiDPI 모드 + 네이티브 해상도 선택. 고른 해상도는 모니터 재연결·잠자기 후에도 자동으로 되돌림
- 서브모니터는 처음 실행할 때 자동으로 지정됨 (메뉴 → 서브모니터 지정에서 변경)
- 앱을 종료하면 꺼둔 모니터를 다시 켬. 다음에 실행하면 마지막 모드를 이어감
- 켜진 모니터가 하나뿐이면 끄지 않음
- 메뉴 → "로그인 시 자동 실행"

## 빌드 / 설치

```bash
./build.sh            # build/MonitorSwitch.app
./build.sh install    # ~/Applications 에 설치하고 실행
```

Xcode 없이 Command Line Tools(swiftc)만 있으면 된다.

## 비상 복구 (메뉴바가 안 보일 때)

```bash
~/Applications/MonitorSwitch.app/Contents/MacOS/MonitorSwitch enable-all
```

재부팅하거나 케이블을 다시 꽂아도 복구된다.

## CLI (테스트용)

`MonitorSwitch list | modes | off | on | test | enable-all`

## 참고

- 비공개 API(`SLSConfigureDisplayEnabled`)를 쓰기 때문에 macOS 업데이트 후 동작하지 않을 수 있음. 이때 메뉴에 경고가 표시됨
- C27의 2048×1152@144 HiDPI 모드는 원래 BetterDisplay가 넣어 준 모드. BetterDisplay 없이 케이블 재연결/재부팅 후에도 남는지 확인 필요 (`MonitorSwitch modes`로 확인)
