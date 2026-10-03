# CloudKit WorkUser — Development only

Container: the existing `CloudKitConfiguration.containerIdentifier` constant.
No server records or schema were created by automated tests or this implementation session.
First save happens only after the user supplies a name and clicks 시작하기 in the Debug app.
Do not deploy schema to Production in this stage. Distribution/Production activation is a separate step;
CloudKit environment is controlled by the app's signed entitlements, not a CKContainer API parameter.

## Boundaries

WorkUser/ProfileViewModel/WorkUserRepository contain no CK types. The CloudKit adapter owns account
identity, record IDs, change tags and retry delay. Mock collaboration retains its original profile,
IDs and code. A real profile never becomes a Mock collaboration sender.

## Records created by the first successful manual save

Private default zone, type **WorkUser**, recordName `work-user-<SHA256(container user recordName)>`.
A stable record per iCloud account; app UUID is independent of Apple identity.

| Field | CloudKit type |
| --- | --- |
| workUserID | String (UUID) |
| displayName | String |
| friendCode | String (8 uppercase alphanumeric) |
| createdAt, updatedAt | Date/Time |
| isActive | Int64 (Boolean represented by NSNumber) |
| publicationPending | Int64 |
| friendCodeEstablished | Int64 |

Public default zone, type **PublicWorkUser**, recordName `friend-<friendCode>`.
Only these custom fields are written:

| Field | CloudKit type |
| --- | --- |
| workUserID | String (same UUID as private original) |
| friendCode | String |
| displayName | String |
| isActive | Int64 |

CloudKit adds standard system metadata; no email, Apple identity or device data is written
into the Public custom fields. Public profiles can be read by other permitted users by code.
Require `_icloud` Create, `_world` Read, and `_creator` Write for PublicWorkUser. Never grant
arbitrary users Write; only the creator may modify a reserved code. Check Development security
roles in Console after the first manual save; the app does not modify Console permissions.

No custom query/search indexes are needed: both lookups use deterministic record IDs.
Any CloudKit default indexes are service-managed; no index was configured by this work.

## Uniqueness and recovery

All saves use `ifServerRecordUnchanged`. A missing record is created with no server change tag;
an ID conflict is re-read and its WorkUser UUID checked. A lookup/query alone never reserves a code.
New-code collision attempts are bounded (8). Already established codes are never regenerated.

Private original is saved first with publicationPending=true, then Public is published, then
Private is finalized. Private creation failure never creates Public. Public/finalization failure
retains the private UUID and pending state. A subsequent load reconciles with that canonical original.
A lost response or concurrent creation therefore reuses the same record, not another app UUID.

Rename writes Private pending first, then Public, then finalizes. A failed rename leaves the
private original intact; next load restores Public to that name. Even a finalized profile is
checked against Public on load to repair a stale concurrent publication. Cross-database writes
are not atomic: temporary mismatches can exist until reconciliation. No record is blindly deleted.

Retry-after pauses subsequent calls in the gateway; no immediate background retry engine exists.
Account changes invalidate only the real Profile screen and each gateway write rechecks identity.
Personal Todo, Mini, Translator and Mock collaboration do not wait for this repository.

## Manual verification

1. Run the Development-signed Debug app. Open 내 프로필; a missing user should show onboarding.
2. Supply your actual desired name. Click 시작하기 once.
3. Confirm private and public records/fields, UUID linkage, and security roles in Development Console.
4. Quit and restart; verify the same UUID/code and no extra WorkUser/PublicWorkUser records.
5. Rename; confirm both records have the new name and the same code/UUID.
6. Offline/error: no infinite spinner; existing local Todo/Translator/Mock features work.
7. Do not create real friends/tasks/rooms, enable synchronization, or deploy Production schema yet.
