# PIAAR Work 협업 아키텍처 제안

상태: 설계 초안, 2026-10-01. 구현 및 제품 정책 승인 전이다.
현재 Production 코드, Todo.store, schema, entitlement, Xcode Target, AGENTS.md를 변경하지 않는다.

관련 문서: [CloudKit 모델](CLOUDKIT_DATA_MODEL.md), [V4 migration](V4_MIGRATION_PLAN.md).

## 결론과 구현 전 조건

개인 Todo는 기존 SwiftData/Repository 경계를 유지하고, 협업은 별도 Repository와 CloudKit adapter, 로컬 캐시로 분리한다.
Public에는 최소 사용자 검색 정보, Private에는 개인 데이터 및 공유 원본, Shared에는 다른 소유자가 공유한 데이터의 접근 경로를 둔다.
협업 관리 UI는 향후 Full에서만 추가하고 Mini의 형태와 입력/완료 흐름은 유지한다.

다음은 현재 요구와 플랫폼 사이의 실제 차이다. 해결했다고 가정하고 구현해서는 안 된다.

| 제품 요구 | CloudKit 제약 | 설계 선택 / 미결 사항 |
|---|---|---|
| 친구 코드로 즉시 친구 추가 | 내 Private 연락처 등록은 가능 | 친구 추가와 CloudKit 공유 참여를 분리 |
| 업무 전달/방 초대에 수락 없음 | CKShare는 상대 계정의 기술적 acceptance 이후 보임 | 업무 수락/거절 상태는 만들지 않되 첫 공유 연결 절차는 필요. 연결 완료 뒤 반복 전달은 별도 수락 없이 표시 |
| receiver는 완료만 변경 | CKShare readWrite는 공유 범위의 내용 수정/삭제도 허용 | UI/정상 클라이언트 규칙으로는 가능, 서버 보안 보장은 불가능. 엄격한 권한이면 신뢰 서버 경로 필요 |
| 친구 코드만으로 앱 안에서 초대 도착 | CKShare URL 전달 경로가 필요; 다른 사람 Private DB에 임의 기록 불가 | 최초 OS 공유 URL 전달 또는 별도 초대 전달 서비스 결정. Public에 업무/초대 내용을 노출하는 우회는 금지 |
| 즉시 상태 반영/알림 | 오프라인, 동기화 지연, 공유 acceptance가 존재 | 정상 온라인 연결에서 빠른 반영을 목표로 하되 실시간/알림 도착 보장 표현 금지 |
| 신뢰할 수 있는 영구 history | readWrite 참가자는 history도 수정 가능; 원본 소유 계정에 의존 | 앱 수준 보존 기록. 변조 방지 감사 및 소유자 탈퇴 후 보존이 필수면 신뢰 서버 필요 |

**권장 의사결정:** 서버에서 강제하는 receiver 제한이 필수라면 CloudKit-only 협업을 출시하지 않는다.
CloudKit 중심의 가벼운 1차 구현은 내부에서 신뢰하는 배포 앱의 UI 권한 제한을 명시적으로 수용한 경우에만 진행한다.
그 경우에도 수락 없는 최초 공유 연결과 자동 초대 전달은 별도 결정 대상이다.
신뢰 서버 대안은 업무 명령을 검증하고 상태/history를 기록하는 작은 계층이며 Dooray식 기능을 추가하는 의미는 아니다.
서버를 추가한다면 DB 권한과 계정 인증도 다시 설계해야 한다. readWrite CKShare를 그대로 둔 채 서버 API만 추가해서는 우회가 차단되지 않는다.

## 제품 범위

할 일 작성, 한 사람에게 전달, 완료/미완료, 행위 기록만 제공한다.
댓글/채팅/첨부/승인/결재/진행률/다중 담당자/업무 거절/업무 수락 상태는 없다.
전사 모든 업무방을 보는 관리자 기능도 없다.

## 현재 코드와의 경계

| 현재 위치 | 현재 책임 | 향후 협업 영향 |
|---|---|---|
| Models/TodoItem, TodoGroup, TodoRepeatSchedule | 개인 데이터 | 공유 업무 모델로 재사용하거나 room 소속을 주입하지 않음 |
| Services/Persistence/TodoPersistence | V1→V2→V3, 고정 경로, CloudKit .none | V4와 개인 Private sync는 각각 별도 단계 |
| SwiftDataTodoRepository | 개인 CRUD, 완료, 반복 생성 | SharedTask ID를 이 Repository에 전달하지 않음 |
| Features/Todo/TodoViewModel | 개인 snapshot/빠른 입력/Editor | 협업 ViewModel과 별도 유지 |
| TodoRowView | TodoViewModel.toggleCompletion 직접 호출 | 향후 화면 외형만 재사용 가능한 callback 경계 검토. 공유 업무를 TodoSnapshot인 척 변환해 local CRUD 호출하지 않음 |
| TodayTodoView / MiniTodoWindowController | 오늘 개인 목록, 빠른 입력, ⌃R 전환 | 향후 오늘 받은 업무 projection을 합성하되 관리 UI를 넣지 않음 |
| FullTodoView / WorkMainView | 날짜별 개인 Todo/Editor | 향후 Sidebar shell의 '내 할 일'에 기존 Full을 포함 |
| TodoCalendarService | 개인 EventKit 연동 | 공유 업무의 권한/CloudKit entitlement와 별개. 상대방 event ID 공유 금지 |
| Translator, GlobalHotKeyManager, Keychain | Production 번역/설정 | 변경 대상 아님 |

현재 TodoRepository.complete/uncomplete는 해당 기기의 개인 DB만 바꾼다. 이를 호출한다고 receiver/sender 공유 상태가 연결되지 않는다.
기존 개인 Todo의 hard delete는 현재 동작으로 남긴다. 새 협업 record만 archive/tombstone 정책을 적용한다.

## 향후 모듈 배치 — 제안이며 이번에 파일/Target을 추가하지 않음

```text
Features/Todo/                   기존 Mini/Full 및 개인 ViewModel
Features/Collaboration/
  CollaborationWorkspaceView    Full의 Sidebar shell
  InboxView / SentTasksView / RoomView / FriendsView
  CollaborationViewModel
Shared/WorkDomain/               플랫폼 독립 DTO, ID, 명령, 권한/날짜 정책
Services/Collaboration/          CollaborationRepository, TaskCommandService
Services/Sync/CloudKit/          Directory, Identity, Sharing, CKSyncEngine adapter
Services/Persistence/            기존 Todo + 별도 Collaboration cache
Platform/macOS/                  기존 창/단축키, 향후 share acceptance hook
Platform/iOS/                    향후 share lifecycle hook; 현재 생성 안 함
Shared/AppIntents/               이후 인증된 업무 command 호출 경계
```

CloudKit CKRecord/CKShare 객체를 View나 공유 도메인에 직접 노출하지 않는다.
DTO→CKRecord 매핑, CKRecord.ID의 zone/owner 보존, 오류/계정 상태는 adapter 책임이다.
동일한 데이터 캐시 객체를 두 앱 창이 함께 사용하며 새 창/새 Repository마다 별도 공유 원본을 만들지 않는다.

## Full / Mini projection

Full: 내 할 일, 받은 업무, 보낸 업무, 참여 업무방, 친구. 현재 단계는 UI를 만들지 않는다.
받은/보낸 업무는 동일 SharedTask cache를 receiver/sender로 필터링한 결과이며 별도 복사본이 아니다.
방 업무도 같은 cache에서 roomID로 필터링한다.
Mini는 오늘 개인 Todo + 오늘 내가 받은 active SharedTask만 합성한다. 방에서 만든 자기 업무도 오늘 내 담당이면 포함한다.
날짜 헤더, 그룹 색상, D-DAY, 행 완료 인터랙션은 기존 스타일을 유지하고 친구/방 관리/전달 설정은 넣지 않는다.
행 ID는 entity kind + account + Cloud locator를 포함해 개인 UUID와 공유 UUID 충돌을 방지한다.
개인 행은 개인 Repository, 공유 행은 Collaboration TaskCommand로 라우팅한다.

## 개인 Todo → 전달 정책

1. 개인 Todo를 읽어 제목/업무 날짜/마감일을 명시적으로 SharedTask에 복사한다. notes, 개인 그룹, 반복, Calendar ID는 자동 공유하지 않는다.
2. sender/receiver, 목적 공유 공간, commandID와 SharedTask UUID를 한 번 생성한다. retry는 동일 ID를 쓴다.
3. SharedTask 원본 저장 및 전송 확인 전에는 개인 Todo를 숨기거나 완료하지 않는다.
4. 연결된 공유 공간에 원본 저장이 확인되면 PersonalTaskLink를 active로 만든다. 그때 원본 개인 행을 활성 목록에서 숨기고 '보낸 업무'에서 공유 상태를 보여주는 안을 권장한다.
5. 원본 TodoItem은 삭제/자동 완료하지 않는다. 완료 상태는 SharedTask에만 기록한다. 개인 DB에는 추적 링크를 둔다.
6. sourceTodoID는 sender 추적용이다. 상대방이 원래 개인 Todo를 조회할 수 있는 CloudKit reference를 만들지 않는다.

개인 Todo와 공유 업무를 자동 양방향 완료 동기화하지 않는다. 이는 retry/충돌/이중 history를 줄인다.
공유 업무를 archive해도 원본을 자동 복원하지 않는다. 향후 '개인 목록으로 복원' 정책은 별도 결정한다.
링크가 pending/실패이면 원본은 계속 개인 목록에 보인다. 처음 공유 연결이 아직 안 된 상태를 '상대방에게 전달 완료'로 표시하지 않는다.
반복 개인 Todo를 전달해도 해당 날짜 인스턴스 1개만 전달하며 반복 템플릿을 공유하지 않는다.
두 명에게 전달하면 source가 같은 독립 SharedTask 2개와 링크 2개를 만든다. 중복 retry와 의도적인 재전달은 commandID로 구분한다.

## 권한과 내용 변경

권장 1차 정책은 **전달 시 핵심 내용 고정**이다. 제목/업무 날짜/마감일/receiver/room/RoomGroup은 전달 후 덮어쓰지 않는다.
잘못 전달한 업무는 sender가 archive 처리하고 새 업무를 전달한다. 이 경우 archive를 history action에 추가할 필요가 있다.
receiver는 complete/reopen만 가능하며 원래 개인 Editor를 열지 않는다. 그룹/반복/Calendar 변경도 못 한다.
sender는 자신의 업무 archive와 개인 표시 설정만 관리하고 완료 상태를 바꾸지 않는다.
룸 자기 업무는 sender==receiver이고 created만 기록한다. 공동 담당자 업무가 아니다.
UI 권한 제한과 CKShare 플랫폼 권한은 다르다. CloudKit-only에서는 이 규칙에 대한 악의적 클라이언트 우회 방지를 주장하지 않는다.
업무 중간에 내용 수정을 허용하려면 contentVersion/수정 history와 receiver 상태 충돌 정책을 별도 승인해야 한다.

## 업무방 정책

WorkRoom은 사람들의 공유 공간, RoomGroup은 방 안의 업무 분류이다.
모든 active/기술적으로 accepted 멤버가 방 업무를 읽는 안을 권장한다. 개별 업무 receiver는 한 명이다.
방 멤버 한 명에게 전달하거나 자신을 receiver로 지정해 자기 할 일을 만든다.
Private TodoGroup을 방으로 직접 옮기지 않는다. 방 데이터의 CloudKit owner는 creator이며 업무의 business sender와 다를 수 있다.
멤버 추가는 owner만 실제 CKShare participant 변경 가능. 그 외 사용자에게 초대 권한을 준다면 owner에게 처리 요청이 필요하다.
owner 관리가 어려운 위임/소유권 이전 기능은 1차 범위에서 제외한다. 소유자가 나갈 때는 방 archive/운영 정책을 먼저 결정한다.
논리 membership의 joinedAt은 실제 공유 접근이 확인된 시점으로 기록하고, 초대 중 상태는 별도 기술 상태로 관리한다.
멤버 제거 시 removedAt 저장 + 실제 share 권한 회수. history/task를 서버에서 삭제하지 않는다.
제거된 사람은 이후 방을 읽지 못한다. 장기 보존은 원본과 남은 멤버의 권한 안에서 이뤄지고, 제거된 사람에게 계속 열람을 보장하지 않는다.
친구 삭제는 Private 연락처만 archive하며 업무방/공유 업무에 cascade하지 않는다.

## 계정과 Offline

Apple ID/비밀번호 입력 화면은 없다. CKContainer.accountStatus와 플랫폼 share lifecycle을 사용한다.

| 상태 | 동작 |
|---|---|
| available | identity 바인딩 확인 후 sync 가능. 초기화 완료 전 '연결됨'으로 확정하지 않음 |
| noAccount | 개인 local-only 유지, 공유 신규 전송 중단 |
| restricted | 개인 기능 유지, 공유 기능 제한 안내 |
| couldNotDetermine | 재시도 가능 오류, 로그아웃으로 단정하지 않음 |
| temporarilyUnavailable | 계정 바인딩과 큐 유지, 재시도 |
| 계정 변경 | 이전 계정 cache/engine/outbox를 격리. 이전 자료를 새 계정으로 자동 업로드 금지 |

SharedTask는 account별 Collaboration.store cache + 영속 Outbox로 offline 읽기/완료 명령을 지원한다.
complete/reopen command는 toggle 대신 원하는 Bool을 기록한다. UI에 optimistic 결과를 보이되 서버 확정/실패를 분리한다.
Full에서 전송/동기화 오류를 확인하고, Mini에는 추가 관리 화면을 넣지 않는다.
수신 데이터/engine state/checkpoint의 영속 갱신은 같은 로컬 transaction 경계에서 다룬다.
개인 신규 Todo는 iCloud가 없어도 기존 Todo.store에서 생성할 수 있다.
첫 공유 연결과 최초 공유 전송은 온라인이 필요하다. 오프라인 '전달 예약'은 즉시 전달과 다르다.

## 알림과 기록

SharedTask 상태 + TaskHistory + DomainEvent를 같은 zone의 원자적 쓰기로 반영한다.
created/sent/completed/reopened를 기록하고 알림 이벤트는 sent→receiver, completed→sender만 생성한다.
reopened는 history만 생성한다. 같은 commandID/action으로 history/event ID를 결정해 retry 중복을 방지한다.
알림은 성공적인 원격 반영 이후에만 발생시키고 로컬 preview만으로 상대방에게 완료 알림을 보내지 않는다.
구독 push는 데이터 갱신 힌트이며, 앱이 내려받은 DomainEvent로 알림을 구성한다. 백그라운드 즉시 배달과 중복 없는 모든 기기 배달은 보장하지 않는다.
엄격한 외부 push 배달 SLA가 필요하면 별도 서버 전송이 필요하다. 이번 단계는 구현하지 않는다.
TaskHistory는 앱 동작 기준 append-only지만 CKShare readWrite 권한 하에서 변조 방지 감사 원장은 아니다.

## 구현 순서 / 중단 조건

1. 사람이 수락/권한/초대 전달/업무방 열람 및 보존 정책을 결정한다.
2. 기존 Todo 원본으로 migration fixture와 account-switch 실패 조건을 정의한다. UI Test는 만들지 않는다.
3. 플랫폼 독립 ID/DTO/권한/날짜/command/idempotency Unit Test를 준비한다.
4. 별도 Collaboration cache/Repository 경계를 구현한다. 개인 UI/DB는 유지한다.
5. 이후 승인된 단계에서만 iCloud container/entitlement/development schema를 구성하고 두 실제 계정으로 CKShare 제약을 검증한다.
6. directory + 일방향 친구 → 최초 공유 연결 → 1:1 업무/완료/history → Full 협업 UI 순서.
7. 별도 단계에서 room/RoomGroup/membership 회수 추가.
8. 개인 V4 migration과 Private sync는 협업 출시와 분리해 검증한다.
9. 이벤트 알림 → iPhone → App Intents/Live Activity 순으로 확장한다.

권한/초대 제약의 해결이 승인되지 않으면 5번 이후 협업 구현을 시작하지 않는다.
문서의 모든 모델은 제안이며 현재 AGENTS.md에 확정 Production 규칙으로 추가하지 않는다.

## 근거

- [Apple CKShare](https://developer.apple.com/documentation/cloudkit/ckshare): 소유자/참여자와 공유 접근/쓰기 범위.
- [Apple Shared Records](https://developer.apple.com/documentation/cloudkit/shared-records): share URL, metadata, acceptance 순서.
- [Apple CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9): Private/Shared 동기화, state 저장 및 시스템 스케줄.
- API 세부와 현재 파일 조사 위치는 CLOUDKIT_DATA_MODEL.md / V4_MIGRATION_PLAN.md에 기록한다.
