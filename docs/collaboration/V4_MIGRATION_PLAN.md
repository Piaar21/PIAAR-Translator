# V3 호환성 / V4 migration / 개인 CloudKit 전환 계획

상태: 설계만. V4 타입, migration stage, capability, container, 실제 데이터 업로드를 이번에 생성하지 않는다.
현재 사용자 데이터/Swift 코드/AGENTS.md/Xcode 설정은 그대로 둔다.
관련 문서: [아키텍처](COLLABORATION_ARCHITECTURE.md), [데이터 모델](CLOUDKIT_DATA_MODEL.md).

## 현재 코드에서 확인된 사실

- Bundle ID: com.piaar.PIAAR-Translator. display name 변경과 독립적으로 유지한다.
- 저장 경로: ~/Library/Application Support/com.piaar.PIAAR-Translator/Todo/Todo.store.
- TodoPersistence.makeContainer는 Schema(versionedSchema: TodoSchemaV3.self)와 명시적 cloudKitDatabase: .none을 사용한다.
- V1/V2는 nested frozen models이고 V3는 현재 top-level TodoItem/TodoGroup/TodoRepeatSchedule을 참조한다.
- V1→V2, V2→V3는 lightweight stage이다. 기존 단계와 원본 checksum 의미를 유지해야 한다.
- SwiftData scalar는 기본값 또는 optional이다. @Attribute(.unique)는 없다.
- TodoItem.group과 TodoGroup.items는 optional이고 inverse가 명시되어 있으며 .nullify를 사용한다.
- TodoRepeatSchedule.groupID/repeatScheduleID는 scalar UUID라 CloudKit foreign key가 아니다.
- linkedCalendarEventID는 현재 개인 TodoItem에 저장된다. 기기별 EventKit mapping 모델은 아직 없다.
- materializeRepeats는 현재 기기의 date interval 내 schedule ID를 조회해 빠진 daily instance를 UUID()로 생성한다.
- 기존 entitlements는 빈 dict이다. iCloud capability/CloudKit container/APNs/share lifecycle은 현재 연결되어 있지 않다.

## 현재 구조와 협업 기능의 충돌 분석

| 주제 | 현재 상태 | 향후 필요한 경계 / 확인 |
|---|---|---|
| 개인 Repository | TodoItem ID만 처리 | SharedTask ID가 들어오지 않게 command routing 분리 |
| ModelContext | 개인 단일 store의 transaction | 다른 store 모델에 SwiftData relationship 직접 연결 금지 |
| sourceTodoID | 개인 UUID | trace/scalar 링크만, private record를 상대 share에 넣지 않음 |
| Calendar ID | 기기 로컬 EventKit 식별자 | 공유 record에 전송 금지. 개인 cloud sync에서도 기기 binding 경계 검증 |
| date / D-DAY | Calendar/Date 기반 | 공유 업무 business day/timeZone 계약 명시; 기존 개인 날짜 변환/초기화 금지 |
| 반복 | 한 기기에서 중복 생성 방지 | 두 기기의 동시 생성 중복은 현재 코드로 막지 못함 |
| 삭제 | 개인 Todo hard delete | 새 공유 record만 archive. 현재 개인 delete UX는 별도 승인 없이 바꾸지 않음 |
| 단축키/설정 | 기존 UserDefaults/Keychain | 동기화 목적으로 이름/값을 초기화하거나 기기 권한을 cloud에 복제하지 않음 |
| Mini/Full | 개인 목록/Editor | shared receiver에 개인 Editor를 연결하면 권한 위반. 별도 read/complete 경계 필요 |

## V4의 정의 — 제품 도메인과 DB 버전은 구분

'V4 협업 모델'은 WorkUser/Friend/SharedTask/WorkRoom/Member/RoomGroup/History를 포함하는 제품 도메인 제안이다.
이 모델들을 전부 기존 Todo.store의 TodoSchemaV4에 넣는다는 의미는 아니다.

권장 물리적 구성:

| 경계 | schema / 저장소 | 내용 |
|---|---|---|
| 개인 | 향후 TodoSchemaV4 / 기존 Todo.store | 기존 3 entity + PersonalTaskLink만 추가 |
| 협업 cache | 별도 CollaborationCacheSchemaV1 / account별 Collaboration.store | WorkUser, Friend, SharedTask, Room/Member/Group/History, outbox/checkpoint 등 |
| 기기 통합 | 별도 local-only integration metadata | device Calendar binding, 계정 bootstrap/checkpoint 등 |

개인 store의 3 model에 roomID/senderID/receiverID 배열을 붙이지 않는다.
V4는 PersonalTaskLink가 실제로 필요할 때만 만든다. 동일 모델을 versionIdentifier만 4로 바꾸는 빈 버전은 만들지 않는다.
이는 공유 record/개인 ModelContext를 분리하면서 개인 source를 보존하고 목록 중복을 줄이기 위한 최소 변경이다.
친구/협업 cache가 독립 VersionedSchema를 사용하는 것은 V4 migration과 별개의 과정이다.

### PersonalTaskLink의 persisted 후보

모든 scalar는 default 또는 optional로 정의하고 .unique는 쓰지 않는다.

| 필드 | 초기값 / 의미 |
|---|---|
| id: UUID | UUID() |
| sourceTodoID: UUID? | nil, 검증된 source ID |
| sharedTaskID: UUID? | nil, 원격 업무 business ID |
| targetRecordLocator: Data? | nil, versioned container/zoneOwner/zoneName/recordName 표현 |
| accountKey: String? | nil, 링크 소유 계정 |
| stateRaw: String | "pending". 허용 값 검증 필요 |
| commandID: UUID? | nil, 중복 전송 방지 |
| createdAt / updatedAt: Date | 생성 기본값 |

active 전이는 source/target/account/remote 저장 확인이 모두 있을 때만 가능하다.
source가 삭제되어도 SharedTask/history는 cascade 삭제하지 않는다. 원본 추적이 끊어진 상태를 허용한다.
V3의 모든 사용자에게 자동 링크를 생성하지 않는다. migration 후 새 entity는 비어 있다.

## V3 → V4 migration 순서

1. V3 fixture를 만드는 기존 코드와 모델 정의를 고정한다. 특히 현재 V3가 top-level current model을 참조하므로 V4 모델 수정 전에 frozen nested V3 모델을 마련해야 한다.
2. frozen V3 정의가 현재 V3와 동일 entity/schema checksum을 유지하는지 실제 V3 생성 fixture로 검증한다. 이름/타입/default/relationship/inverse/deleteRule을 그대로 보존한다.
3. V1/V2를 수정하지 않고 models list에 frozen V3와 new V4를 이어 붙인다. 기존 stages 유지.
4. V4는 기존 3 entity의 구조를 유지하고 default/optional의 PersonalTaskLink entity를 추가한다. lightweight 추가 후보이나 실행 결과로 판정한다.
5. migration 전 다른 ModelContainer/context를 종료하고 쓰기를 멈춘 상태에서 복구 가능한 백업을 만든다. WAL을 쓰는 DB의 본체만 live-copy하면 안 된다. sidecar/metadata를 함께 일관되게 보존한다.
6. **같은 Todo.store 경로**에서 migration을 수행한다. 실패 시 새 빈 DB 생성/삭제/자동 reset은 하지 않는다.
7. 모든 기존 ID/필드/관계/record 수를 비교하고 초기 링크 count=0을 확인한다.
8. migration 성공을 기록한 뒤 기존 개인 Repository를 연다. 협업 캐시는 별도 생성한다.

frozen model로 옮기는 실제 구현은 이 문서만 보고 checksum이 같다고 가정하지 않는다.
현재 V3의 top-level model을 먼저 바꾸고 나중에 V3를 고정하면 기존 버전을 훼손할 수 있다.
lightweight가 적합하지 않다면 custom stage의 근거를 마련하되 migration 실패를 삭제/재생성으로 해결하지 않는다.
V4 DB를 이전 V3 앱으로 직접 되돌리는 downgrade는 지원한다고 약속하지 않는다. 복구에는 검증된 백업/새 앱의 복구 경로가 필요하다.

## local-only → 개인 Private CloudKit 전환은 별도 단계

V4 도입이 CloudKit 활성화와 같은 날이어야 할 이유는 없다. V4 local-only를 먼저 검증하는 것이 안전하다.
개인 sync 후보는 SwiftData ModelConfiguration의 명시적 .private(승인된ContainerID)이며 .automatic 의존을 피한다.
existingTodo.store를 삭제/경로 교체하지 않고 managed sync enable을 검증하는 방향을 우선한다.
이 방식의 실제 metadata 초기화/기존 자료 export/relaunch 안정성은 현재 SDK의 복제 V3/V4 store에서 검증해야 한다.
다른 위치의 새 store에 사용자 자료를 옮기는 우회는 기본안이 아니며, 필요할 경우 명시적 별도 migration 설계/승인을 받는다.

### CloudKit schema compatibility

- scalar default/optional 유지.
- .unique 사용 금지. UUID/중복 검증은 Repository/domain 책임이다.
- 모든 SwiftData relationship optional, inverse 명시.
- .deny 관계 삭제 규칙은 적용하지 않음. 현재 .nullify는 호환 방향이다.
- 관계/관련 entity는 서로 다른 순서로 내려올 수 있으므로 임시 unresolved 상태를 허용한다. 늦게 온 데이터를 영구 orphan/삭제로 정규화하지 않는다.
- 여러 ModelConfiguration에 같은 entity를 중복 배치하거나 서로 다른 저장소로 자동 관계를 만들지 않는다.
- CloudKit production schema는 개발 schema와 별도로 promote해야 한다. record type/field 제거와 타입 변경 제약 때문에 additive/versioned payload 정책을 쓴다.
- SwiftData가 관리하는 CloudKit recordName/zone을 임의로 예상해 CKShare에 붙이지 않는다.
- SwiftData 자동 sync와 직접 CKSyncEngine이 같은 개인 Todo records를 동시에 관리하게 하지 않는다.

### enable 전에 반드시 해결할 두 문제

**반복 중복:** 두 기기에서 같은 schedule/day를 materialize하면 현재 UUID()가 각각 생성되어 중복 instance가 된다.
CloudKit에서 .unique로 막을 수 없다. `(scheduleID, business day, calendar/timeZone policy)`의 canonical occurrence key와 deterministic cloud identity 또는 검증된 reconciliation이 필요하다.
이미 존재하는 UUID를 새 ID로 일괄 치환하면 안 된다. 기존 notes/완료/deadline/Calendar 매핑을 잃지 않는 중복 처리 정책을 검증한다.
개인 여러 기기의 Calendar/time zone 정책까지 포함해 Unit Tests와 실제 두 기기 시험을 별도 설계한다.

**EventKit ID:** linkedCalendarEventID는 다른 기기에서 같은 event를 가리킨다는 보장이 없다.
V4 migration 시 기존 기기의 ID를 DeviceCalendarBinding에 보존하고 새 코드는 해당 기기 binding만 사용하도록 하는 안을 권장한다.
기존 persisted 필드를 @Transient로 바꿔 버리거나 nil로 초기화하지 않는다. 다른 기기에서 legacy ID를 사용해 일정을 업데이트하지 않는다.
자동 SwiftData sync는 필드별 whitelist를 제공하는 직접 serializer와 다르므로 legacy field가 올라오는 영향/구버전 호환을 검증해야 한다.
이 요구를 안전하게 충족하지 못하면 개인 auto-sync enable을 연기하고, 개인 데이터도 직접 CKSyncEngine projection으로 관리하는 대안을 별도로 비교한다.
Calendar 연동 실패가 업무 완료/CloudKit 저장 실패로 연결되지 않게 기존 EventKit 오류 경계를 유지한다.

## 최초 cloud bootstrap / 계정 전환

- 최초 활성화는 복구 가능 백업, 안정 UUID, 계정 바인딩, bootstrap checkpoint 확인 후 진행한다.
- 이미 같은 계정에서 cloud records가 있으면 import/upload 중복과 repeat occurrence를 먼저 비교한다. 무조건 local/all cloud 중 하나로 덮어쓰지 않는다.
- accountKey + container + development/production environment 별 engine/checkpoint/outbox를 분리한다.
- CloudKit Development에 실제 사용자 Todo를 실험 업로드하지 않는다. 복제 fixture와 별도 시험 계정을 사용한다.
- iCloud logout/일시 오류만으로 Todo.store를 삭제하지 않는다.
- 새 계정에 이전 계정의 개인 데이터/링크/room cache를 자동 export하지 않는다. 계정 변경 시 기존 store의 소유 context를 명확히 식별하고 sync를 중지한다.
- 기존 Todo.store를 보존하되 두 번째 계정용 store/context가 필요하면 별도 account 경로를 사용한다. 기본 legacy 경로를 이름 변경만으로 새 DB로 대체하지 않는다.
- 최초 계정 바인딩 이전에 로컬에 있던 Todo를 어느 계정의 개인 데이터로 올릴지는 명시적 사용자 선택 정책이 필요하다.
- room 접근 회수 시 제거된 계정의 cache 노출/미확정 명령을 막는다. 서버 task/history 원본은 유지하며 접근 회수와 서버 데이터 삭제를 혼동하지 않는다.

## 검증 계획 — 향후 구현 단계의 Unit Tests

현재는 코드/DB 변경이 없으므로 이 테스트를 만들거나 실행하지 않는다. UI Test는 생성/실행하지 않는다.

- V1→V4, V2→V4, V3→V4, 빈 DB, 기존 그룹/미분류/완료/반복/date-only/one-sided deadlines.
- 모든 UUID/날짜/본문/완료시각/color/sortOrder/Calendar ID/관계 보존, 링크 초기 count 0.
- migration 실패 시 DB 삭제/새 DB 생성 없음, backup 복구, 원본 경로 유지.
- sender/receiver가 같은 업무 ID/locator를 조회, 서로 다른 room/zone에서 UUID 충돌 없이 분리.
- received complete/reopen 명령만 허용, content editing 금지, idempotent retry, conflict/권한 회수 rollback.
- task/history/event 원자적 쓰기 실패와 링크 활성화 중단/crash recovery.
- offline outbox 재시작, 두 기기의 complete/reopen 충돌, 반복 instance 중복.
- friendCode 정규화/동시 등록 CAS/충돌 retry/anchor 복구/친구 삭제 무 cascade.
- removed member가 server 접근을 잃고 기존 history는 owner 원본에 남음.
- account logout/relogin/switch, 다른 계정 export 차단, time zone/DST.
- 기존 Translator/단축키/Keychain/로컬 Todo 회귀 테스트 유지.

실제 CKShare/권한/계정/CloudKit metadata는 Unit fake만으로 검증 완료라고 하지 않는다.
해당 구현 단계에는 승인된 시험 계정의 실제 장치 수동 검증을 추가한다.

## 향후 iPhone 경계

SwiftData/CKSyncEngine 공통 도입 시 iOS 17+가 자연스러운 후보이며 최종 deployment target은 사람이 결정한다.
업무 DTO, 날짜/권한/완료 command, Repository interface는 Foundation 중심으로 공유한다.
AppKit/Carbon/NSWindow/접근성/복사 기능은 macOS에 남긴다. iOS scene share acceptance 및 알림은 플랫폼 adapter로 분리한다.
App Intents/잠금화면 완료도 receiver 권한/계정/멤버 여부/동일 TaskCommand 경로를 거치게 한다.
Live Activity는 서버 원본이 아닌 UI projection이며 종료/갱신이 업무 삭제 또는 승인으로 취급되지 않는다.
이번에는 iOS Target, App Group, Widget, Live Activity, App Intents 기능을 생성하지 않는다.

## 사람이 결정해야 할 항목

1. receiver-only 제한은 신뢰 앱 UI 계약인가, 악의적 클라이언트까지 막는 서버 권한인가?
2. 최초 공유 연결의 기술적 acceptance를 허용하는가? 허용하지 않으면 공유 기반안은 요구를 충족하지 못한다.
3. 최초 share URL/초대를 어떻게 전달하는가? OS 공유 경로 또는 인증된 별도 서비스.
4. 내부 직원 식별/비활성화는 배포 신뢰로 충분한가, 검증된 사내 사용자 directory가 필요한가?
5. Room 전체 업무를 모든 active 멤버가 읽어도 되는가? 방별 소유자와 퇴사/계정 삭제 시 보존 책임은 누구인가?
6. sender의 전달 후 내용 고정 + archive/재전달 정책을 수용하는가?
7. source 개인 행은 원격 저장 확인 후 숨기는가, 계속 표시하는가? archive 뒤 원본 복원은 자동인가?
8. friendCode 8자 형식, business time zone, iOS 최소 버전.
9. Calendar의 기기별 binding과 repeat multi-device 정책이 검증될 때까지 개인 auto-sync를 연기할 것인가?
10. Developer Team/iCloud container 이름/배포 경로와 계정 전환 정책.

## Apple 근거

- [SwiftData 개인 동기화 및 schema 제약](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [명시적 Private configuration](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/private(_:))
- [CloudKit Public 역할 / production schema promotion](https://developer.apple.com/icloud/cloudkit/designing/)
- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9)
