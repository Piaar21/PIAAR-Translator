# CloudKit / V4 도메인 데이터 모델 제안

상태: 2026-10-01 설계 초안. 아래 이름은 제안이며 @Model/CKRecord/schema/capability를 생성하지 않았다.
권한/초대의 미결 조건은 [전체 아키텍처](COLLABORATION_ARCHITECTURE.md)를 따른다.

## 현재 SDK에서 확인한 범위

확인 환경: /Applications/Xcode.app, Xcode 15.4 (15F31d), macOS 14.5 SDK, 프로젝트 macOS 14.3+, Swift language mode 5.0.
전역 xcode-select는 CommandLineTools를 가리킨다. 확인에는 DEVELOPER_DIR를 지정했으며 전역 설정은 변경하지 않았다.

| 항목 | 설치 SDK 정의 / 사용 가능성 |
|---|---|
| SwiftData | Versions/A/Modules/SwiftData.swiftmodule/arm64e-apple-macos.swiftinterface: macOS 14 / iOS 17 |
| ModelConfiguration.CloudKitDatabase | 위 interface에 automatic, none, private(String)만 존재. shared/public configuration 없음 |
| CKSyncEngine | CloudKit.framework/Headers/CKSyncEngine.h: macOS 14 / iOS 17. 현재 target에서 가능 |
| CKSyncEngineRecordZoneChangeBatch | 해당 header에 atomicByZone/custom batch initializer 존재. 관련 task/history를 같이 묶는 설계 가능 |
| CKShare root hierarchy | CKShare.h: custom zone의 root record 기반 공유 및 acceptance 필요 명시 |
| zone-wide CKShare | CKShare.h: macOS 12 / iOS 15. 가능하나 이번 권장 root hierarchy와 혼합하지 않음 |
| 친구 identity lookup | CKUserIdentityLookupInfo.h: userRecordID initializer, macOS 10.12 / iOS 10 |
| record CAS / atomic | CKModifyRecordsOperation.h: ifServerRecordUnchanged, isAtomic. atomic은 같은 지원 zone 안에서만 적용 |
| 계정 상태 | CKContainer.h: available/noAccount/restricted/couldNotDetermine + temporarilyUnavailable(macOS 12/iOS 15) |

Headers 상대 경로 기준:
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.5.sdk/System/Library/Frameworks/`
CloudKit/SwiftData framework의 Versions/A 실제 파일도 확인했다.
API가 존재한다는 사실은 entitlement 없는 현재 앱에서 CloudKit 호출이 성공한다는 뜻이 아니다.
새 SDK에만 있는 타입이나 현재 SwiftData에 없는 shared configuration을 전제로 하지 않는다.

## Public / Private / Shared 역할

| 데이터 | 소유자에서의 원본 | 상대방에서의 접근 | 동기화 경계 |
|---|---|---|---|
| UserProfile / friendCode claim | Public default zone | 최소 공개 검색 | 직접 CKDatabase fetch/query. CKSyncEngine 적용하지 않음 |
| WorkIdentity / Friend / 개인 협업 설정 | 내 Private 전용 metadata zone | 접근 불가 | 직접 CloudKit + private CKSyncEngine |
| 개인 Todo/그룹/반복/PersonalTaskLink | 내 Private의 SwiftData 관리 영역(향후) | 접근 불가 | SwiftData Private sync 후보. 현재는 .none |
| DirectTaskSpace와 task/history/event | sender Private의 custom zone | receiver Shared의 동일 share | private/shared CKSyncEngine |
| WorkRoom/멤버/RoomGroup/task/history/event | room creator Private의 custom zone | accepted 멤버 Shared | private/shared CKSyncEngine |
| Collaboration cache / outbox / systemFields | 기기 로컬, account별 별도 store | 접근 불가 | SwiftData .none, 직접 CloudKit adapter 전용 |
| EventKit binding / device checkpoint | 기기 로컬 별도 integration store | 접근 불가 | 동기화하지 않음 |

Shared DB는 모든 직원이 쓰는 회사 공용 원본 DB가 아니다.
동일 논리 기록에 대해 owner는 Private, participant는 Shared endpoint를 사용한다.
캐시에 private/shared 양쪽 결과가 와도 `(container, zoneOwner, zoneName, recordName)`로 같은 record를 합친다.
CKRecord.ID를 recordName 하나로 저장하지 않는다. Shared zone ownerName은 내 계정으로 재작성하면 안 된다.

## Wire 표현과 인덱스

도메인 UUID는 CKRecord에서 lowercase UUID 문자열로 매핑한다. Bool은 NSNumber, 시각은 Date,
날짜는 YYYY-MM-DD + timeZoneID, enum은 versioned raw String, optional은 key 생략으로 표현한다.
CloudKit DTO에 SwiftData 모델 객체나 UUID 자체를 무조건 CKRecordValue로 넣는 구현은 하지 않는다.
알 수 없는 action/state/payload version은 삭제하거나 기본 완료값으로 덮어쓰지 않고 보존/재조회한다.
Public friendCode 조회는 deterministic record ID fetch를 우선한다. Query를 쓰는 field만 QUERYABLE 인덱스를 명시한다.
Private/Shared 목록은 engine으로 내려받은 로컬 cache의 sender/receiver/room/date 인덱스를 사용한다.

## 모델별 필드와 정책

### WorkUser / 공개 UserProfile

WorkUser는 도메인 사용자이며 Public CKRecord를 모든 사용자 상태의 authoritative 원본으로 삼지 않는다.

| 필드 | 형태 / 정책 |
|---|---|
| id | UUID, 내부 ID. friendCode와 분리 |
| displayName | 사용자 지정 사내 표시 이름 |
| friendCode | 정규화된 표시/검색 코드 |
| cloudIdentity | containerIdentifier + CloudKit userRecordID 매핑. 이메일/Apple ID가 아님 |
| createdAt / updatedAt | UTC timestamp; SDK record metadata와 구분 |
| isActive / deactivatedAt | logical 활성 상태. 기존 history의 foreign key를 삭제하지 않음 |

Public UserProfile의 사업 데이터는 internalUserID, friendCode, displayName, 검색 제외용 isActive 정도로 제한한다.
이메일/전화/Apple ID 이메일/Task 제목/방 목록/share URL/개인 설정을 넣지 않는다.
CloudKit userRecordID를 별도 검색 필드로 노출하지 않고, 참여자 lookup에는 조회 record의 플랫폼 creator metadata를 내부 adapter가 사용한다.
CloudKit 자체가 제공하는 creator metadata까지 앱이 숨긴다고 보장하지 않는다. 공개 directory가 완전 익명이라는 표현은 금지한다.
userRecordID는 container와 계정에 종속된 플랫폼 식별자이고 UUID/friendCode/이메일과 같지 않다.
공개 profile의 선언된 id만 신뢰하지 않고 creator identity와 내부 매핑을 함께 검증한다.
사내 직원임을 강제하는 조직 인증은 iCloud available만으로 성립하지 않는다. 배포/온보딩 신뢰 또는 별도 검증은 사람이 결정한다.

### Friend — 일방향 개인 연락처

`id`, `ownerUserID`, `targetUserID`, `targetCloudIdentity`, `displayNameSnapshot`, `friendCodeSnapshot`, `createdAt`, `updatedAt`, `removedAt?`.
Private 원본의 recordName은 owner/target 조합을 사용해 중복 추가를 idempotent하게 만든다.
삭제는 removedAt 처리하고 재추가는 같은 관계를 활성화한다. UUID를 새로 만들어 중복 관계를 쌓지 않는다.
친구 삭제는 SharedTask, WorkRoomMember, TaskHistory에 영향을 주지 않는다.
친구 등록 자체는 CKShare/상대 친구 등록/초대/승인이 아니며 상대방 Private DB를 쓰지 않는다.

### SharedTask — 하나의 업무 원본

| 필드 | 제안 |
|---|---|
| id | UUID. sender/receiver 화면 모두 동일 |
| title | 전달 시 확정된 핵심 제목 |
| senderUserID / receiverUserID | 각각 UUID 1개. assignees 배열 없음 |
| senderDisplayNameSnapshot / receiverDisplayNameSnapshot | 프로필 변경/비활성 후 과거 맥락 유지 |
| roomID? / roomGroupID? | Room UUID와 RoomGroup UUID. 개인 TodoGroup ID 아님 |
| sourceTodoID? | 도메인에서 sender 추적용; 권장 cloud payload에서는 생략하고 PersonalTaskLink에 저장 |
| date | 업무 기준 날짜. wire에는 YYYY-MM-DD와 timeZoneID 권장, 로컬 DTO는 Date projection 가능 |
| deadlineDay? / startDateTime? / deadlineDateTime? | 미정 유지. 값이 둘 다 있을 때만 시간 범위 검증 |
| isCompleted / completedAt? / completionActorUserID? | 완료 시 actor/시각, reopen 시 완료 시각/actor nil |
| createdAt / updatedAt | 클라이언트 의미 시각. 서버 record timestamp와 별개 |
| archivedAt? / archivedByUserID? | 삭제 대신 보존 |
| revision / lastCommandID | CAS/중복 처리와 상태 전이 추적 |

핵심 내용/receiver/room/group는 전달 이후 고정하는 안을 권장한다.
공유 반복 템플릿, 개인 notes, Calendar event ID는 첫 구현에서 보내지 않는다. deadline은 명시적으로 전달하는 값이다.
룸 자기 업무는 sender==receiver, 생성 이벤트만 있고 sent 이벤트는 없다.
개인 날짜는 기존 Date를 유지한다. 공유 업무 날짜는 sender/receiver 시차로 다른 날이 되지 않도록 business day/time zone를 명시한다.

### WorkRoom

`id`, `name`, `ownerUserID`, `creatorUserID`, `ownerDisplayNameSnapshot`, `createdAt`, `updatedAt`, `archivedAt?`.
room archive는 기록을 삭제하지 않으며 신규 업무 생성/전달만 막는다.
creator의 CloudKit 소유 계정이 원본 zone을 소유한다. 앱의 owner 필드를 바꾼다고 CKShare 소유권이 이전되지 않는다.
소유 계정 탈퇴/삭제 시 기록의 영구 보존은 CloudKit-only로 보장하지 않는다.

### WorkRoomMember

`id`, `roomID`, `userID`, `displayNameSnapshot`, `joinedAt?`, `removedAt?`.
`member:<roomUUID>:<userUUID>` 같은 deterministic recordName으로 중복 참여를 방지한다.
새 초대의 joinedAt은 아직 unknown일 수 있다. 실제 CKShare accepted와 접근 확인 후 채운다.
owner 여부는 WorkRoom.ownerUserID로 계산하고 별도 복잡한 역할 목록은 두지 않는다.
WorkRoomMember는 logical membership/history 맥락이고 CKShare.participants가 실제 데이터 접근 권한이다.
logical removedAt만으로는 접근 회수가 되지 않는다. owner가 share participant 제거를 확정해야 한다.
재가입은 같은 membership을 활성화하되 이전 제거 이벤트를 별도 room history/metadata에 보존할 수 있다.

### RoomGroup

`id`, `roomID`, `name`, `colorHex?`, `sortOrder`, `createdAt`, `updatedAt`, `archivedAt?`.

| 방식 | 장점 | 문제 |
|---|---|---|
| 개인 TodoGroup을 그대로 공유 | 초기 코드 재사용 | 개인 Todo 관계가 공유 경계에 섞임, 다른 store/zone 간 관계 불가, 그룹 삭제/이름 변경이 개인 데이터와 결합 |
| 별도 RoomGroup | ownership/분류/삭제 정책 명확, 개인정보 경계 유지 | 작은 DTO/매핑 추가 필요 |

별도 RoomGroup을 권장한다. SharedTask.roomGroupID는 같은 room의 active group만 참조한다.
향후 개인 그룹 전체 공유는 '개인 그룹→RoomGroup 가져오기/SharedTask 생성' 명시적 작업으로 확장한다.
당장은 구현하지 않고 원본 추적은 Private import mapping에 둘 수 있다. 그룹과 room을 하나의 객체로 합치지 않는다.

### TaskHistory

`id`, `taskID`, `actorUserID`, `actorDisplayNameSnapshot`, `action`, `timestamp`, `commandID`, `taskRevision`, `metadata?`.
action 최소값은 created/sent/completed/reopened. archive 정책 채택 시 archived도 필요하다.
동일 command에서 created와 sent는 다른 deterministic history IDs로 기록한다.
metadata는 제한된 key/value 또는 versioned payload로 두고 계정 credential/share URL/개인 notes를 넣지 않는다.
플랫폼 creatorUserRecordID, 생성 시각도 저장/검증할 수 있지만 기록을 임의로 바꿀 수 없는 서버 audit와 같지 않다.
서버 creationDate를 수신 후 serverCommittedAt으로 보관하고, 클라이언트 timestamp를 무조건 신뢰할 만한 서버 시각이라고 표시하지 않는다.
Friend/WorkUser/RoomMember를 지워도 cascade delete하지 않는다. 스냅샷 이름/actor ID로 과거를 표시한다.

### PersonalTaskLink — 개인 DB V4 후보

`id`, `sourceTodoID?`, `sharedTaskID?`, `targetRecordLocator?`, `accountKey?`, `state=pending|active|archived`, `createdAt`, `updatedAt`.
원격 task와 개인 source 관계만 기록한다. 개인/공유 상태 자체를 복사한 두 번째 업무가 아니다.
TodoItem schema는 그대로 두고 이 새 entity를 추가하는 V4 후보를 권장한다.
서로 다른 ModelContainer의 SwiftData relationship 대신 scalar ID/locator를 쓴다.
accountKey는 플랫폼 계정 매핑이고 공개 프로필에 노출하지 않는다.

### 지원 데이터 — 협업 cache에서만

| 모델 | 목적 / 필드 |
|---|---|
| DirectTaskSpace | id, senderUserID, receiverUserID, createdAt, archivedAt. owner=sender인 재사용 공유 root |
| WorkIdentity | Private의 고정 anchor. user UUID, friendCode reservation 상태, 계정 식별 바인딩 |
| CloudRecordLocator | container, DB 접근 scope, zoneOwner, zoneName, recordName. business UUID와 별도 |
| CloudRecordState | systemFields Data, change tag, 서버 metadata. 직접 CK 매핑에만 사용 |
| PendingTaskCommand | commandID, taskID, target completion Bool, actor/account/device, baseRevision, local sequence, retry/status |
| DomainEvent | eventID, taskID, kind sent/completed, actor/target IDs, committed revision, 발생 시각 |
| NotificationReceipt | eventID + account + device의 표시 처리 여부. history와 분리 |
| SyncCheckpoint | account/container/environment/database별 CKSyncEngine.State.Serialization |
| DeviceCalendarBinding | 개인 Todo/SharedTask ID + deviceID + EventKit eventID. 공유 원본에 넣지 않음 |

이 모든 모델을 기존 Todo.store의 @Model로 한꺼번에 넣지 않는다.
WorkUser/Friend 등은 도메인/CloudKit 레코드/로컬 cache에서 표현하고 해당 cache는 독립 VersionedSchema를 사용한다.

## 공유 root / record zone 권장안

### 1:1 전달

```text
sender Private custom zone: DirectSpace_<spaceID>
  DirectTaskSpace(root, sender/receiver 1쌍)
  CKShare(root=root, publicPermission=.none)
    receiver participant (accepted 뒤 접근)
  SharedTask A (parent=space root)
    TaskHistory, DomainEvent (parent=Task A)
  SharedTask B (parent=space root)
    TaskHistory, DomainEvent (parent=Task B)

receiver Shared -> 같은 zone/record IDs
```

sender→receiver 방향별 재사용 공간이다. 상대가 역방향으로 보낼 때는 별도 outbound 공간을 만들거나 이미 참여한 room을 쓴다.
Task마다 CKShare를 만들면 공유 연결/초대가 반복되므로 기본 권장안은 공간 root 재사용이다.
대안인 Task root share는 업무별 ACL 분리가 쉽지만 매번 기술적 참여/초대 관리가 필요하다.
space의 receiver와 다른 사람을 task에 지정하지 않는다. 재할당은 원본 변경 대신 새 공간/새 업무로 한다.

### 업무방

```text
creator Private custom zone: Room_<roomID>
  WorkRoom(root)
  CKShare(root=WorkRoom, publicPermission=.none)
  WorkRoomMember (parent=WorkRoom)
  RoomGroup (parent=WorkRoom)
  SharedTask (parent=WorkRoom, roomID=<roomID>, receiver=단일 멤버)
    TaskHistory / DomainEvent (parent=SharedTask)
```

custom field roomID/taskID만으로 CKShare 범위에 들어가지 않는다. CKRecord.parent hierarchy를 설정한다.
WorkRoomMember.userID는 Public의 UserProfile CKReference로 연결하지 않고 UUID로 저장한다.
CKReference는 다른 zone을 가리킬 수 없다. 개인 source와 공유 target도 locator/scalar로 연결한다.
같은 SharedTask를 Room share와 Direct share 양쪽에 넣을 수 없다. record는 share 한 개에만 참여한다.
room task를 보낸/받은 목록에 표시할 때는 cache projection으로 재사용하고 새 CKRecord를 만들지 않는다.
zone-wide share와 root hierarchy는 대안이며 같은 zone에 둘 다 섞는 설계는 채택하지 않는다.
공유 참가자 수/계정 quota/zone 수는 무제한이라고 가정하지 않는다. CKFetchShareParticipantsOperation 문서는 share 참가자 100명 제한을 명시한다.
사내 업무방 크기와 많은 1:1 공간을 만드는 실제 운영 quota는 구현 전 시험 계정에서 확인한다.

### 실제 ACL과 acceptance

private share + publicPermission=.none을 기본으로 한다. 링크를 아는 누구나 들어오는 공개 share는 사내 업무에 쓰지 않는다.
receiver가 상태를 쓰려면 readWrite가 필요하고 root 내 다른 내용 쓰기도 플랫폼상 가능하다.
Room share readWrite 멤버는 room의 타인 업무/history도 수정할 수 있다. 앱 UI만으로 서버 보안이 강화되는 것은 아니다.
CKShare readOnly + receiver가 별도의 개인 status record에 쓰는 방식은 sender가 그 데이터를 자동 읽을 수 없고
두 원본의 병합/접근 연결이 추가된다. 최소 설계의 receiver-only 보안 해결책으로 제시하지 않는다.
기술적 acceptance 상태는 pending/accepted/removed/unknown이며 업무 수락/거절 상태가 아니다.
처음에는 share URL을 상대 계정에 전달하고 metadata/acceptance를 처리해야 한다.
friendCode 조회→participant lookup은 가능하지만 상대 기기에 share URL을 전달하고 acceptance를 수행하는 것까지 해결해주지 않는다.
다른 사람 Private DB에 초대 Inbox를 쓰거나 Shared DB에 임의 zone을 생성한다고 가정하지 않는다.

## 친구 코드 — 예약과 조회

권장 표시: `#A3K8R21P`처럼 8자 랜덤 코드. 예시 #A3821을 반드시 5자로 제한하는 요구는 아직 없다고 해석한다.
32자 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` 사용, 앞뒤 공백/선행 # 제거 및 대문자 정규화.
공백 중간 삽입/허용하지 않는 문자는 오류. O/I/L 같은 별칭 입력은 처음에는 받지 않는다.
8자는 40bit 공간이다. 내부 ID는 UUID이며 코드는 비밀/권한 토큰이 아니다.

1. 온라인에서 내 Private WorkIdentity 고정 record를 CAS로 먼저 확정한다. 두 기기 최초 등록 시 서로 다른 UUID/profile을 만들지 않도록 anchor를 공유한다.
2. 선택 코드와 user UUID를 anchor의 예약 상태로 기록한다.
3. Public `UserProfile:<NORMALIZED_CODE>` record ID를 신규 생성한다. 코드 필드 query 후 저장하는 방식만으로 uniqueness를 보장하지 않는다.
4. 같은 record ID가 이미 있으면 내 creator identity/user UUID와 일치하는 재시도인지 확인한다. 타인 claim이면 새 코드를 만들어 anchor를 CAS 갱신하고 재시도한다.
5. Public 저장 성공 후 anchor를 ready로 갱신한다. 단계 사이 crash는 저장된 command/candidate로 회복한다.
6. 코드는 검색 가능한 예약 recordName이므로 직접 fetch가 기본. Public CKQuery를 쓴다면 friendCode의 QUERYABLE index를 구성하고 pagination/네트워크 오류를 처리한다.

Public role는 최소 공개 Read, Authenticated Create, Creator Write 기준으로 검토한다. 다른 사용자의 profile을 일반 Authenticated Write로 열지 않는다.
새 record ID 충돌을 서버의 create/CAS 실패로 처리한다. SDK unique annotation으로 해결되지 않는다.
계정 탈퇴/코드 변경 시 기존 코드는 inactive 예약으로 남겨 재사용하지 않는 안을 권장한다.
별도 Public claim/profile 두 record로 분리하면 등록의 원자성/고아 claim 정리가 늘어난다. 1차는 하나의 profile/claim record가 단순하다.
인증/권한은 코드 문자열이 아니라 실제 Cloud identity와 CKShare participant로 확인한다.

## 동기화와 쓰기 단위

Public directory는 fetch/query만 사용한다. 직접 협업 원본은 private engine / shared engine 각각 별도 state로 관리한다.
SwiftData private sync가 관리하는 개인 zone에는 직접 CKSyncEngine이 같은 Todo를 다시 쓰지 않는다.
WorkIdentity/Friend와 협업 소유 zone은 직접 private engine 경계에 두고 schema/recordName을 분리한다.
직접 private engine의 fetch/send scope는 앱이 관리하는 zone allowlist로 제한한다.
설치 SDK의 FetchChangesOptions/SendChangesScope zoneIDs 범위를 사용하고 SwiftData 관리 zone을 수동 import/export하지 않는다.
CKSyncEngine를 Private DB 전체에 무조건 적용하는 것은 개인 managed sync와 안전하게 공존하는 설계가 아니다.

상태 변경에는 task + history + 필요한 event를 같은 custom zone의 atomic batch로 저장한다.
CKSyncEngine의 custom RecordZoneChangeBatch에서 관련 command 레코드를 함께 포함하고 atomicByZone을 켠다.
CKModifyRecordsOperation을 직접 사용한다면 isAtomic 및 ifServerRecordUnchanged로 같은 원칙을 지킨다.
동일 task를 engine와 별도 직접 writer가 경쟁해 쓰는 이중 전송 경로는 만들지 않는다.
Private PersonalTaskLink와 Shared 원본은 DB/zone 경계가 달라 하나의 transaction으로 묶을 수 없다.
따라서 '원격 원본 저장→링크 활성화' checkpoint와 재시도로 복구한다. 링크 실패가 새 SharedTask 재생성으로 이어지면 안 된다.

## 완료/미완료, 충돌, history 정합성

완료 명령: desiredCompleted=true, completedAt=행위 시각, actor=receiver.
reopen 명령: desiredCompleted=false, completedAt/actor=nil.
기존 개인 Todo 완료는 계속 개인 Repository 책임이다.

receiver의 변경은 cache+outbox 로컬 transaction에서 optimistic하게 반영한다.
실제 원격 반영은 changeTag/기준 revision을 검증하고 성공 결과로 cache/systemFields를 갱신한다.
동일 command retry는 동일 TaskHistory/Event ID와 lastCommandID로 no-op/확인 처리한다.
동일 기기의 명령은 sequence 순서를 유지하고 오래된 완료 명령을 뒤늦게 최신 reopen 위에 재적용하지 않는다.
다른 기기에서 충돌하면 serverRecordChanged 결과를 읽고 서버 최신 상태를 우선 수신한다.
이미 원하는 상태면 새 transition/history를 만들지 않는다. 반대 상태이고 기준 revision이 오래됐으면 명령을 conflict로 종료하고 최신 화면에서 재입력할 수 있게 한다.
클라이언트 시계의 max(updatedAt)만으로 충돌을 해결하지 않는다. 내용은 초기 고정 정책이라 완료 명령이 제목/마감을 덮어쓰지 않는다.
permission failure/멤버 제거는 무한 retry하지 않고 미확정 UI 변경을 rollback한다.
History UUID가 유일해도 악의적 참가자가 기록을 지우는 것은 CKShare에서 차단되지 않는다.

## 알림 / 이벤트

DomainEvent는 권장안에서 task의 share hierarchy 안에 저장하므로 참여자 이외에는 노출되지 않는다.
필드: eventID(command/action에서 결정), taskID, kind, actorUserID, targetUserID, actorNameSnapshot,
필요한 title snapshot, occurredAt, taskRevision. 업무 내용이 들어가므로 Public에는 저장하지 않는다.
룸에서는 다른 참여자도 해당 이벤트를 읽을 수 있다는 권한 범위를 수용해야 한다.
sent는 receiver, completed는 sender 대상. reopened에는 알림 이벤트를 생성하지 않는다.
자기 업무 sender==receiver는 sent 알림을 만들지 않는다.
수신 후 eventID 기반 NotificationReceipt로 중복 표시를 줄인다. 두 기기 동시 표시 완전 방지/정확히 한 번 배달은 약속하지 않는다.
Shared DB에는 CKQuerySubscription을 전제로 하지 않고 database/zone 변경을 받는 경로를 사용한다.
foreground 재조회/engine catch-up으로 누락 push를 복구한다. 이번 단계에는 구독/알림/권한 요청을 생성하지 않는다.

## 향후 entitlement / lifecycle — 이번 단계 미적용

CloudKit을 쓸 때 정식 Developer Team/배포 프로파일, iCloud service와 container identifiers, 환경 설정을 별도 검증해야 한다.
Remote notification delivery/APNs 설정 및 background execution은 플랫폼별로 적용한다.
share URL lifecycle에는 CKSharingSupported와 macOS NSApplicationDelegate/iOS scene delegate 처리를 검토한다.
기존 EventKit 설명 문자열/권한은 CloudKit 인증 또는 공유 capability를 대신하지 않는다.
Bundle ID는 com.piaar.PIAAR-Translator를 그대로 두고 실제 iCloud container 이름은 사람이 승인한 뒤 생성한다.
이번에는 container identifier를 임의 확정하거나 app entitlement를 수정하지 않는다.

## Apple 문서

- [CKShare](https://developer.apple.com/documentation/cloudkit/ckshare)
- [Shared records / acceptance](https://developer.apple.com/documentation/cloudkit/shared-records)
- [User identity lookup](https://developer.apple.com/documentation/cloudkit/ckuseridentity/lookupinfo-swift.class)
- [fetch participant with user record ID](https://developer.apple.com/documentation/cloudkit/ckcontainer/fetchshareparticipant(withuserrecordid:completionhandler:))
- [CKRecord parent](https://developer.apple.com/documentation/cloudkit/ckrecord/parent)
- [Record zones / cross-zone reference restriction](https://developer.apple.com/documentation/cloudkit/ckrecordzone)
- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9)
- [Engine database configuration](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/database)
- [Atomic modifications](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/isatomic)
- [CAS save policy](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged)
- [Public roles and schema promotion](https://developer.apple.com/icloud/cloudkit/designing/)
- [macOS share acceptance](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:userdidacceptcloudkitsharewith:))
- [Account status](https://developer.apple.com/documentation/cloudkit/ckaccountstatus)
- [CloudKit subscriptions](https://developer.apple.com/library/archive/qa/qa1917/_index.html)
