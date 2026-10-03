# Direct Task delivery

## Confirmed server contract

The developer confirmed the production policies before this implementation:

- INSERT requires `created_by = auth.uid()`.
- For `space_id IS NULL`, assignee must be self or an active friendship peer.
- `private.is_active_friend(user, other)` checks friendships with `ended_at IS NULL`.
- UPDATE permits the assignee. SELECT permits creator/assignee (and eligible space users).
- Task events require the authenticated actor and task participant/access permissions.

No server policy, schema, RPC, or credentials were changed by this implementation.
The supplied contract is the source of this review; Codex did not run live policy probes.
The receiver-only UPDATE policy is a row-level restriction, not a column-level
immutability guarantee. This app restricts received Tasks to complete/reopen and
sent Tasks to read-only at the ViewModel and repository boundaries.

## Application boundaries

- A delivery creates a new row in `public.tasks`. No SharedTask copy/model/store is used.
- Personal quick entry remains self-assigned through the original `createTask` path.
- Direct delivery has no space, group, recurrence, source-local identity, or Calendar link.
- Personal Task delivery copies title, notes and actual deadline fields into a new open Task.
  The original and its completion/group/recurrence/Calendar identity remain untouched.
- A recurrence instance can be copied once; a template or recurrence rule cannot be delivered.
- Both sender/receiver read the same Task. Queries do not require a continuing friendship.
- Friend relationship is read again at submit and in the SDK write boundary. INSERT RLS
  handles a friendship ending after these reads.
- Task UUID is stable within one sheet command, including retry after network ambiguity.
  Reuse checks the exact sender/receiver/UUID, not a matching title. No upsert/overwrite.
  Busy submission and the delivered flag block overlapping/repeated clicks.
- After an ambiguous success, retry reuses the committed row even if the friendship ended
  or the receiver edited/completed it. A cancelled sheet is a cancelled command; a new
  sheet starts a new deliberate delivery.
- Successful delivery refreshes server lists and shows `전달됨` without navigating away
  from friends. Received badge counts all open received Tasks, independent of selected date.
- Full/received/sent views retain their existing selected-date navigation; Mini shows today.
  Use date navigation to view tasks scheduled on other dates.
- Full and Mini reuse Task rows/sorter/completion optimism. Sent rows cannot be completed.
- Names for rows come from profiles, including historical peers no longer in the friend list.
  History instead uses actor snapshots and assignment receiver-name metadata captured at send.
- Delivery enqueues deterministic created/assigned Event UUIDs into the existing per-user
  persistent Event Retry queue. An Event failure never rolls back the saved Task.
  Completion/reopen events continue through the existing completion path.
- Logout/user switch invalidates composer, task lists, names, events and history access.
- No polling, Realtime, Push, Space UI, SwiftData dual-write, or actual Legacy Migration.

## Manual two-account verification

1. With A and B as active friends, send from A's friend menu with title only and with date-only deadline.
2. Check exactly one Task is created and that A remains on friends with `전달됨`.
3. B opens/refreshes Full, received, and Mini today. The same row shows `← A` in each.
4. B completes/reopens the Task. Check immediate sorting and persistence after refresh.
5. A opens/refreshes sent and Mini sent tab. Check `→ B`, current completion, and no editing/completion action.
6. Open sent Task `활동 기록`: created, assigned, completed, reopened; past actor names remain after profile rename.
7. Deliver an existing personal Task/recurrence instance. Original remains unchanged;
   only title/notes/deadline fields are copied, no group/recurrence/Calendar mapping.
8. End friendship with the sheet open. New delivery must fail; old rows remain readable,
   and B can still complete them. No subsequent new delivery is allowed.
9. Simulate a timeout then retry in the same sheet. Confirm one Task UUID/row, including
   when receiver completed it before sender retry. Check Event Retry independently.
10. Logout and sign in another user; no former user's sheet, names, lists or history remain.
11. Validate non-friend INSERT and third-party Task/Event reads are denied using separate
    authenticated sessions. Never use service_role to validate application permissions.

Real account delivery and RLS probes are performed manually by the developer.
Unit Tests use fake repositories; no real server, user DB or UI tests are invoked.
