# Supabase Task transition

## Source of truth and account scope

ApplicationSession is the composition root for Auth/Task/Group repositories.
Production windows receive one account-scoped TaskWorkspaceModel. Full, Mini,
received/sent pages, missed items and calendar indicators use that model.
Logged-out shortcuts open the login window without copying text. Successful login
opens Full. Logout or authentication refresh failure invalidates the previous
workspace, closes its windows and cancels the Translator popup's pending work.
Task refresh responses are ignored after invalidation.

SDK creation occurs only in the production composition root. TodoWorkspaceStore's
default account is an unconfigured dependency; Unit Tests inject protocol fakes
and never create a Supabase client. Legacy TodoRepository remains available as a
separate adapter, but production load() does not open it when server tasks exist.

## Confirmed database prerequisites

The developer confirmed notes TEXT NULL, deadline_date DATE and the partial unique index on
(created_by, source_local_todo_id) WHERE source_local_todo_id IS NOT NULL.
The developer also confirmed that completed status permits completed_at=NULL.
Missing Legacy completion timestamps remain NULL; open items always have NULL
completed_at. This implementation does not execute SQL or change the remote schema.

TaskDay encodes YYYY-MM-DD directly, using Gregorian civil dates in the user's
timezone. Date-only deadlines send null start_at/deadline_at. Explicit times send
absolute timestamps only. Server defaults/triggers own created_at/updated_at.
Editing a title/group preserves original absolute times after timezone changes.

## Migration and backup

No migration runs on login or preview. The user approves the current account
inside the migration sheet. Actual import is enabled only in Debug builds; Release permits preview but cannot invoke writes. SQLite's read-only backup API copies the original
Todo.store and WAL content to a temporary directory; SwiftData opens only the
copy. The original store, V1/V2/V3 schema and persistence path are unchanged.
A regression test compares the original store bytes before/after reading.

Server Task IDs and Group IDs are deterministic and scoped to the importing
account; source_local_todo_id retains the local Todo UUID. Existing imported
Tasks are reused without overwriting server edits. Insert errors reconcile with
the source ID / Task ID, supported by the server uniqueness constraint. Group
imports reuse their deterministic IDs. Partial failures remain retryable.

Supported TodoRepeatSchedule values and their instances can now migrate after
Debug-only approval. Missing or unknown standalone repeatRule values stay pending.
Notes go directly to tasks.notes; retries never overwrite server notes. The preview
shows ready rules, ready instances, pending records and duplicate rule/date entries.
Duplicate legacy dates reuse one server Task, without merging or overwriting titles,
notes or completion; all original versions remain in Todo.store.
Original local sort order controls insertion order; original creation/update
metadata remains in the backup rather than replacing authoritative server times.

New Tasks are Supabase-only, with no SwiftData dual-write. A failed write keeps
the quick-entry draft and retry UUID. There is no offline Task write queue.
Queries are date bounded and paginated; hitting a safety limit raises an explicit
error instead of presenting a silently truncated result. Loaded rows survive
network errors. Missed items query the last three days; calendar indicators query
the displayed month's grid rather than loading all user Tasks.

## Calendar

EventKit event IDs stay in an account-scoped device-local plist under
Application Support/com.piaar.PIAAR-Translator/TaskCalendarLinks. They are never
uploaded. Migration carries existing local IDs into this map after Task creation.
Date-only/start-only/end-only/both use the existing TodoCalendarTiming semantics.
A mapping read failure prevents overwriting the map or creating duplicate events.
Calendar failures after server saving are explicitly reported as partial failures.

## Append-only activity events

The verified event contract is id, task_id, actor_id,
actor_display_name_snapshot, event_type, metadata and server-default created_at.
TaskEventPayload uses these exact fields; the previous configurable column-name
fallback has been removed. Metadata defaults to {} without any Task snapshot.
There is no event update/delete API. The authenticated actor UUID is checked
before insertion; the name snapshot is captured before the user's Task request,
not fetched again at retry time. Self creation records created; a creation result
assigned to another user plans created + assigned (actual sending remains deferred).
Legacy imports do not fabricate created/assigned events for historical data.
Migration neither enqueues nor invalidates the normal activity retry queue;
normal creation/completion/reopen retries retain their existing behavior.
Completion/reopen each have a separate action UUID and captured name.

Task and Event requests are intentionally separate. A Task success is never
rolled back because an Event failed. TaskEventQueue persists requests atomically
under Application Support/com.piaar.PIAAR-Translator/PendingTaskEvents/<user>.json,
then attempts inserts. Retrying uses the same UUID and name; an existing matching
id/actor/task is reconciled through the Event primary key without updating it.
Pending events survive logout/restart and only the same account can load them.
Task objects are never written to that file; there is no SwiftData dual-write.
A damaged queue is not overwritten. A storage write error retains pending events
in memory and reports it, but cannot promise recovery after process exit until
storage is writable. There remains a nontransactional gap between a Task success
and durable enqueue (e.g. process termination); a server transaction/RPC would be
needed to guarantee every mutation has an audit event.

## Recurrence implementation

The user confirmed all five server prerequisites: recurrence_id, template flag,
FK with ON DELETE SET NULL, unique recurrence/date and unique template_task_id.
No DDL or actual user migration was executed by this implementation session.

Creation order is template Task (flag=true, recurrence_id=NULL), then rule with
its template_task_id, then occurrences (flag=false, recurrence_id=rule.id).
Templates never receive recurrence_id and are excluded from normal/overdue queries.
Stable account-scoped IDs group Legacy repeatScheduleID into one template and rule.
Retries reuse existing rows and never update server-edited template/rule/instance data.
The server uniqueness constraints are the final concurrency guard. Only PostgREST
23505 reconciles a competing occurrence/rule insert by its exact natural key.
Foreign-key, authorization and other errors propagate; unrelated unique violations
also propagate when there is no matching natural-key row. Archived occurrences
participate in reuse, preventing resurrection after a user removes an occurrence.

Sunday=1, Monday=2, Tuesday=4, Wednesday=8, Thursday=16, Friday=32, Saturday=64.
Legacy beginsOn maps to start_date; end_date is NULL. Legacy did not persist a
specific timezone, so approval preview discloses use of the current device timezone.
Deadline day offsets and optional clock times are copied; no invented midnight or
23:59 is added. Disabled legacy mask=0 maps to is_active=false, while historical
occurrences and their individual completion states still import. Malformed/missing
schedules remain explicit pending records rather than losing information.

Workspace refresh materializes only today in each rule's timezone, using current
server template content. It does not pre-generate a future range or backfill missed
days. Turning off recurrence updates only is_active=false; all existing Tasks remain.
No cron, Edge Function, Realtime or Push was added. Concurrent disable vs an already
in-flight insert cannot be atomic using client REST alone; a single in-flight occurrence
may finish, but subsequent refreshes stop. No existing instances are deleted.

Before actual Debug approval, manually verify task_recurrences SELECT/INSERT/UPDATE
RLS against template ownership, Task INSERT/SELECT RLS, the unique indexes and FK,
rule timezone/deadline preview, and real two-device creation with separate sessions.
Unit tests use injected memory repositories and never create a Supabase client.

## Deferred features

Production friends/rooms are explicitly shown as preparation placeholders; Mock
seed Tasks never feed production Task lists. Existing Mock adapters and tests are
retained independently. Space and Friend server repositories remain deferred.
CloudKit is not used for the new Task/Group source of truth. No UI Test is added
or run. Validate with all Unit Tests, Debug/Release builds and git diff --check.

## Final migration safeguards

Preview reads all source identities from the server before approval. Already imported
records are counted and reused even if the original value is no longer importable.
New-count excludes duplicate local recurrence/date pairs; the preview explicitly
warns that one server occurrence is reused and distinct original variants remain
in the backup. Failed preview clears the cached source/approval target.

Group identity is SHA-256-derived UUID from kind + authenticated user UUID + Legacy
group UUID, guarded by the existing groups primary key. Same-name groups are never
merged. Template/rule identity uses the same policy with repeatScheduleID. No
UserDefaults migration-complete flag is authoritative. Missing/ambiguous group or
repeat references remain pending instead of becoming ungrouped ordinary tasks.

The live Auth profile and SDK session owner are checked before approval execution
and between requests. Explicit PostgREST JWT failures PGRST301/302/303 also
stop import and return to login; SQL/RLS/FK/CHECK errors remain distinct. Session loss stops new requests; already committed server
rows remain recoverable through identities on retry. An already sent request may
finish before session loss is observed; client REST cannot roll back that request.
The current process suspends recurrence materialization during import, including
checks between materialization requests. Existing in-flight inserts on this or
another device cannot be atomically suspended by this client guard. Exact
recurrence/date reuse preserves the winning server row, never overwrites it with
Legacy content, and preserves the source backup. Keep other devices closed during
the first verification when preservation of every original occurrence is important.

Import publishes one aggregate result (tasks/groups/rules/failures/pending); it does
not animate per-row counts. Retry reuses existing rows and the frozen preview
calendar/timezone. Completion awaits a shared model refresh, updating Full, Mini,
missed items and calendar dots. Local Calendar links only fill absent mappings;
a newer local mapping is not replaced and no Apple Calendar event is created.
Debug structured diagnostics contain phases/counts/error codes, no title/notes/
credentials, with source UUIDs private. The user-facing UI has no raw error codes.

See [LegacyMigrationVerification.md](LegacyMigrationVerification.md) for the manual
Debug checklist. This session did not open the real source store through SwiftData,
press import, write server data, or modify any original persistence schema.

JWT code classification follows the [PostgREST error reference](https://docs.postgrest.org/en/stable/references/errors.html#group-3-jwt).
