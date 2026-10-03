# Supabase Space / 업무방

## Server contract

The developer supplied the verified Space contract and completed archived-space
write guards before implementation. Codex did not alter SQL, RLS, or schema.

- spaces: creator INSERT/UPDATE, creator or active member SELECT; trimmed name 1–60.
- space_members: creator INSERT/UPDATE; removed_at is a soft removal.
  The partial active (space_id,user_id) unique index permits a new row on re-invite.
  Creator access does not depend on a membership row; the app never removes creator.
- groups: public.groups with space_id. Active members/creator can create.
  Owner or Space creator can modify/delete, while still having Space access.
  Task FK ON DELETE SET NULL preserves every Task when a group is deleted.
- tasks: public.tasks only. Active access required to insert; recipient must be
  Space creator or active member. Completion/edit requires assignee; the app further
  restricts content edits/deletion to self-created, self-assigned Tasks.
- Archive keeps all rows and blocks Member/Group/Task writes. Task history remains readable
  under the existing Task/Event participant/access policies.

No RoomTask, RoomGroup, SharedTask server model/table has been introduced.
Existing Mock WorkRoom files remain compiled for legacy/Unit Test boundaries, but
no Production sidebar, creation sheet, room route, or startup reads the Mock room world.

## Implementation

- Foundation Space/SpaceMember, SpaceRepository and SupabaseSpaceRepository.
- SpaceDirectoryModel owns server sidebar rows and one cached TaskWorkspaceModel per Space.
- Space creation uses a stable command UUID. Space succeeds first, then optional friend
  invitations. Partial success keeps the Space and retries only failed invitations.
- Invite writes re-read friendship and current profile. Existing active membership is
  reused after duplicate/ambiguous writes; re-invite creates a new membership UUID.
- Groups reuse GroupRepository and the existing group editor. Group command UUID is
  stable for retries; owner/creator controls are displayed according to the contract.
- TaskWorkspaceModel has an optional Space scope. The scoped view reuses Task rows,
  status sorter, optimistic completion, task editing and persistent Event Retry.
- Space displays all dates, grouped by Space groups plus ungrouped. New Tasks default
  to today. Full personal/received/sent and Mini retain their existing date policies.
- Group inline entry combines input and assignee picker. Default/after success is self.
  Removed users are absent from choices; creator is included without a membership row.
- Space mutations refresh the root server Task model, so assigned/received/sent/Mini,
  missed/calendar indicators and badges use the same Task IDs, without copies.
- Current profile names are for row labels. History uses recorded actor snapshots and
  assignment metadata, independent of later profile changes.
- Active Space list refreshes on Full entry/activation and after changes, without polling.
  A network error retains loaded data. Confirmed loss of Space access clears that scoped
  view. Logout invalidates directory, scoped Task models, members, groups and composers;
  stale asynchronous responses cannot publish to the new account.
- Space access is not required to complete an existing assigned Task outside the Space
  view after removal. The app follows Task UPDATE RLS, including its Archive guard.
- Archive removes the sidebar entry and disables mutation, including archived Space
  Tasks still visible in main/Mini. SDK checks and server RLS remain the final guards.

No actual remote Space was created by Codex. No migration, Realtime, Push, UI Test,
new credential, SwiftData write or schema change was performed.

## Manual validation (two accounts, plus a nonmember if available)

1. A creates solo Space, then creates one with B selected. B refreshes Full sidebar.
2. A checks creator is present without a membership row; invites another active friend.
3. B creates a group and a self Task. A can manage that group; unrelated group owner
   restrictions hold for B. Deleting the group keeps A/B Tasks with group_id NULL.
4. Group + opens input beside assignee. Enter creates for self/default or selected member;
   input clears and recipient returns to self. Verify focus and continuous entry manually.
5. Confirm other dates' Tasks are visible in Space, while Full/Mini use scheduled date.
6. A→B Space Task shows the same ID in B's Space, main, received, Mini and A's sent views.
7. Only B can complete/reopen A→B Task. Refresh A's view and inspect activity history.
8. Rename profiles and check old history actor snapshots remain unchanged.
9. A removes B: B's sidebar/scope clears on refresh; B cannot create new Space Tasks.
   Historical Task/Event rows remain; participant Task SELECT rights are separate from
   Space membership. Assignees can still complete/reopen existing non-archived Tasks
   from main/received, per supplied Task UPDATE RLS; this does not grant Space access.
10. Re-invite B: past removed membership stays, exactly one new active row appears.
11. End A/B friendship while both are members: membership remains and Space assignment
    works; new friendship-based invitations are blocked.
12. Archive as A: hidden sidebar, all writes blocked, existing rows/history preserved.
    Refresh main/Mini and confirm archived Tasks are read-only.
13. Try a nonmember session: no unrelated Space/Group/Task read or assignment.
14. Simulate invitation/network partial failure and retry: one Space and one active
    membership per user, successful invitations aren't repeated.
15. Switch account: no previous Space, members, group, input or Task history is displayed.

Unit Tests use account-scoped in-memory fakes and never construct a Supabase client.
Actual server/RLS and native UI behavior are manually verified by the developer.
