# PinSticky 프로젝트 진행 상황 요약

현재까지 해결된 문제와 구현된 핵심 기능들의 요약입니다. 다른 AI 에디터(Cursor 등)나 환경에서 코딩을 이어나갈 때 이 문서를 컨텍스트로 제공하시면 됩니다.

## 1. 다중 선택 및 일괄 처리 기능 (Batch Operations)
- **수동 선택:** 메모는 체크박스나 `CMD+Click`을 통해서만 수동으로 활성화(선택)됩니다.
- **다중 일괄 제어:** 여러 메모가 선택된 상태에서 하나의 메모에 특정 액션을 취하면, 선택된 다른 모든 메모들도 동시에 동일한 액션이 적용됩니다.
- **구현된 일괄 처리 목록:**
  - **이동 (Drag):** 창 하나를 드래그하면 선택된 모든 창이 딜레이 없이 동시에 이동합니다.
  - **크기 조절 (Resize):** 창 하나를 리사이즈하면 선택된 모든 창이 조작 중인 창의 크기에 맞춰 함께 리사이즈됩니다.
  - **속성 변경 및 스택:** 색상/테마 변경이나 스택 그룹화 등이 일괄 적용됩니다.
  - **최소화/최대화 (Collapse):** 작은 원(핀) 버튼을 눌러 메모를 접을 때 선택된 모든 메모가 동시에 최소화/최대화됩니다.

## 2. 치명적인 오류(Crash) 해결 및 방어 코드

### A. 무한 루프 (Infinite Layout Recursion) 방지
- 일괄 이동/리사이즈를 구현할 때, 코드로 창 크기나 위치를 바꿀 때마다 `setFrame` 이벤트가 다시 발생해 무한 루프에 빠지는 문제가 있었습니다.
- **해결 방안:** `StickerNoteWindow`와 `NoteWindowController`에 `isProgrammaticallyMoving`이라는 플래그를 추가했습니다. 코드나 애니메이션으로 창을 조작할 때는 이 플래그를 `true`로 두어 불필요한 마우스 드래그 연쇄 이벤트가 발생하지 않도록 차단했습니다.
- 이동 전용 이벤트인 `setFrameOrigin` 역시 오버라이드하여 윈도우 배경을 통한 드래그 시에도 일괄 이동이 정상 작동하게 했습니다.

### B. 프록시 객체로 인한 크래시 (EXC_BAD_ACCESS) 해결
- 메모를 최소화(Collapse)할 때 발생하는 크기 축소 애니메이션(`NSAnimationContext`) 중에 앱이 튕기는 오류가 발생했습니다.
- **원인:** macOS의 `NSWindowAnimator`가 애니메이션을 위해 동적으로 임시 프록시 객체(`_NSWindowAnimator_...`)를 생성하는데, 이 프록시 객체에서 Swift 클로저(예: `noteMouseDraggedHandler`)에 접근하려다 쓰레기 메모리를 참조하며 크래시가 났습니다. 게다가 이 프록시 객체는 자신의 클래스 이름을 원래 클래스인 척 속이는 성질이 있었습니다.
- **해결 방안 1:** 속임수에 당하지 않도록 겉보기 클래스 이름(`className`) 대신 Swift의 `String(describing: type(of: self))`를 사용해 프록시 객체를 정확히 탐지하고 이벤트 실행을 조기 종료(return)하도록 수정했습니다.
- **해결 방안 2:** `animator().setFrame`이 실행되는 모든 애니메이션 구간을 `isProgrammaticallyMoving = true`로 감쌌습니다.

### C. 비동기 상태 충돌 (Race Condition) 해결
- 여러 메모를 최소화할 때 또다시 크래시가 발생하는 문제가 있었습니다.
- **원인:** 상태(State)가 변경되어 이를 구독(`$note.sink`)하는 비동기 UI 업데이트 로직이 애니메이션 중간에 난입했습니다. 이로 인해 강제로 레이아웃이 덮어씌워지면서 진행 중이던 애니메이션의 방어막(`isProgrammaticallyMoving`)이 일찍 풀려버리고 마우스 이벤트가 오작동했습니다.
- **해결 방안:** `NoteWindowController.swift`의 `applyPresentationChangeIfNeeded` 함수 최상단에 `guard !isApplyingTransition`, `guard !window.isProgrammaticallyMoving` 방어 코드를 추가했습니다. 시스템 애니메이션이나 화면 전환이 진행 중일 때는 외부의 상태 동기화 신호를 무시하게 만들어 애니메이션이 온전히 끝날 수 있도록 보호했습니다.

## 3. Swift 6 Concurrency (동시성) 경고 해결
- `NSAnimationContext.runAnimationGroup`의 `completionHandler`에서 메인 스레드 전용 프로퍼티(`isProgrammaticallyMoving`)를 수정할 때 발생하던 `Sendable closure` 컴파일 경고를 수정했습니다.
- `Task { @MainActor in }`로 명시적으로 래핑하여 완전히 안전하게 코드가 실행되도록 개선했습니다.

## 요약 가이드 (AI 에디터용)
향후 코드를 수정하거나 기능을 추가할 때, **창 크기/위치 변경(`setFrame`, `setFrameOrigin`)과 애니메이션(`NSAnimationContext`)이 관여하는 부분은 반드시 `isProgrammaticallyMoving`이나 `isApplyingTransition` 플래그를 활용해 이벤트 루프 충돌과 프록시 접근을 막아야 한다는 점**을 주의해야 합니다.
