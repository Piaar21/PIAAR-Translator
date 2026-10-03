# Legacy Migration: manual Debug verification

This checklist is for the developer/user. Codex does not approve or run import.
Unit Tests use protocol fakes, never SupabaseClient or the real user's Todo.store.
No UI Tests are created or run.

## Before opening Preview

1. Quit old copies of PIAAR Work and other Macs during the first migration check.
2. Keep the original `~/Library/Application Support/com.piaar.PIAAR-Translator/Todo/Todo.store`
   and its associated files in place. Do not delete/reset/rename/move them. An optional
   separate backup must retain the original files. No schema migration is applied to
   the original; SQLite READONLY backup takes a consistent snapshot including WAL.
3. Run the current Debug build and sign in to the intended Supabase account.
4. Server prerequisites confirmed by the developer: notes; deadline_date/start_at/
   deadline_at; unique (created_by,source_local_todo_id) where source is nonnull;
   recurrence_id FK; template flag; unique (recurrence_id,scheduled_date) where
   recurrence is nonnull; unique template_task_id; completed with NULL completed_at.
5. Actual RLS behavior has not been integration-tested by Codex. Verify the intended
   account can SELECT/INSERT personal groups/tasks and its template-owned rules.
   Do not disable RLS or add privileged client credentials to make import work.

## Preview and approval

1. Open Full → 내 할 일 → 가져오기 검토 (also available from the ellipsis menu).
2. Compare the source total, groups, repeated tasks and tasks with memos.
3. If 100 source items have 70 already imported and no pending/duplicate records,
   expect 30 new, 70 already imported. Review pending and duplicate-date notices.
4. Duplicate rule/date rows share one server occurrence. Distinct original variants
   remain in the source; their titles/notes/status are not merged. Inspect such
   source records before approval if the variants matter.
5. Check the displayed timezone. A Legacy rule has no stored original timezone;
   this preview uses the current device calendar/timezone and freezes it for retry.
6. Confirm counts reflect the intended account. Preview/cancel must create no server
   groups/tasks/rules or events. Logout/account switch invalidates the preview.
7. Only you check approval and click 가져오기. Release cannot perform import.

## After importing

1. Review aggregate Task/Group/Rule counts and pending/failure messages. A pending
   invalid rule/group stays in the original; no silent flattening into an ordinary task.
2. Select relevant dates in Full. Confirm separate same-name groups, colors/order,
   group-less items, notes, deadline-only/start-only/end-only/both formats, status,
   NULL unknown completion timestamps and recorded known completion timestamps.
3. Mini lists only today's tasks assigned to this user. Templates never appear.
4. Check past open tasks produce calendar dots and recent-three-day missed items.
5. Confirm one template per Legacy repeatScheduleID, template flag=true and
   recurrence_id=NULL; one rule with the correct Sunday-first bits/start/timezone;
   actual date rows have template flag=false and recurrence_id=rule.id.
6. Check no fabricated created/assigned history for imports. Ordinary new tasks and
   completion/reopen still use the normal event queue; failed events retain stable IDs.
7. No new Apple Calendar event should be created merely by importing. Existing local
   mappings stay on this Mac and are not uploaded; newer local links survive retry.
8. Verify the original Todo.store is still in the original location. New tasks remain
   Supabase-only; no Legacy SwiftData writes occur.

## Retry and other Mac

1. For a partial result, use 다시 시도; successful records must be reused. Closing and
   reopening the Debug app must also reuse them, not rely on a local completion flag.
2. Edit an imported Task on the server/app; import again. Title/notes/deadlines/status
   and assigned user must retain the server values. Group/template/rule edits also stay.
3. If the session expires mid-import, later requests stop. Rows already committed
   survive; sign in again and review before retry. An in-flight request may finish.
4. After initial verification, sign in on another Mac: the same server rows should
   appear. That Mac's separate legacy store must not automatically import.
5. Test normal two-device same-date recurrence generation separately: both clients
   reuse the exact occurrence under the server unique index. Other errors must still
   fail; deactivating a rule preserves all old occurrences and completion states.

## Diagnostics and remaining integration limits

Console subsystem `com.piaar.PIAAR-Translator`, category `LegacyMigration` reports
Debug-only phases/counts/error codes. Do not post credentials or source content.
The app shows plain aggregate messages only. Network/RLS failures remain retryable,
not reported as successful import. This client workflow is not a server transaction:
a Task may commit just before a lost response/session, and another device may create
today's occurrence before Legacy import. Reuse never overwrites that server winner;
the original variant remains backed up. No schema workaround/RPC has been added.
