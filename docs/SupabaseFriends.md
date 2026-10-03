# Supabase mutual friendships

## Confirmed server contract

The developer supplied the contract after directly querying the actual database.
This implementation did not change schema/RLS or create accounts/requests.

- `friend_requests`: id, sender_id, receiver_id, status, created_at, updated_at,
  responded_at. Status is pending/accepted/rejected; sender differs from receiver.
- `friend_requests_one_pending_pair`: unique unordered LEAST/GREATEST pair where
  status=pending. This prevents same-direction and opposite-direction races.
- Request SELECT is participants only. INSERT sender must be auth.uid(), receiver
  must differ. Receiver-only UPDATE is not used by the client.
- `friendships`: id, user_a_id, user_b_id, created_at, ended_at. UUID text lexical
  ordering is enforced server-side; active ordered pair is unique when ended_at=NULL.
- Friendship SELECT is participants only; no direct client INSERT/UPDATE.
- Profiles SELECT is available to authenticated users. The app selects only id,
  display_name, friend_code, is_active, created_at, updated_at. Email/Auth metadata
  never reach friend presentation.
- `accept_friend_request(p_request_id UUID) -> UUID`: locks and validates a receiver's
  pending request; atomically accepts it and creates/reuses an active friendship.
- `reject_friend_request(p_request_id UUID) -> VOID`: receiver rejects pending request.
- `remove_friend(p_friend_id UUID) -> VOID`: participant sets ended_at, no DELETE.

## Boundaries

ServerFriendsView -> ServerFriendsViewModel -> FriendshipRepository ->
SupabaseFriendRepository -> FriendTransport -> Supabase SDK.
The old FriendRepository/MockFriendRepository describe unilateral Mock contacts
used by existing room/task tests. They are intentionally not converted into real
friendships or injected into the production friend screen. Production receives one
account-scoped ServerFriendsViewModel through ApplicationSession/TodoWorkspaceStore.
SupabaseFriendRepository's transport initializer enables Unit Tests without an SDK
client or server. SDK construction remains in the existing composition root.

Friend and FriendRequest are Foundation-only values. FriendshipRecord is an adapter
row, never a View dependency. Request presentations join public profiles without
inventing snapshot columns. Active friend queries are participant-scoped and ended
rows excluded. Request queries are current-user direction + pending only. Results
are paginated with a safety limit; profile joins batch up to 200 IDs. One full
snapshot is published only after every query and profile join succeeds, preserving
all previously loaded lists if refresh fails.

## UX and concurrency

The main search field filters only existing friends by name/code. The + sheet
normalizes FriendCode, finds an active public profile, then requires a separate
send button. Self search/send is rejected. Existing active friendship, outgoing
pending, and incoming pending are distinguished; incoming offers acceptance instead
of inserting a reverse request. A 23505 insert error re-reads the exact pair and
reuses the real incoming/outgoing/active state. A conflict without a matching pair
and other errors still fail. Rejected/ended history does not block a new request.

Accept/reject/remove each call exactly the specified RPC, never a client sequence
of UPDATE plus INSERT. Only after server success is the local pending/friend row
removed, followed by snapshot refresh. The sidebar badge is pending incoming count.
Refresh runs on main-window opening, friend-page entry, app activation, and after
mutations; there is a manual button. No timer, polling, Realtime, or Push.

Logout/account switch invalidates and immediately clears all lists, search result,
sheet/input/error state before closing/replacing the old workspace. Late responses
are ignored. Session identity is checked before/after transport requests and before
writes. Explicit PostgREST JWT failures are translated at the SDK boundary to
Auth session loss, clearing the workspace; SQL unique/FK/RLS errors remain distinct.
Failed refresh keeps previous rows; failed mutations do not remove them.
An already sent request may commit despite a later disconnect/logout. Refresh is
the authority for reconciling that outcome; the server constraints protect pairs.

Subsequent phases have already connected Direct Task delivery from real friends
and Supabase Spaces. Revalidating this friendship contract does not remove those
features or add further Task/Space behavior. Task/Group/Recurrence/Migration code
and schema are unchanged by this review. No actual Migration, natural language
parsing, account creation, friend request, or other live write is performed for
verification. Existing Mock features remain in their legacy/test boundary; they
do not use or send to real friend IDs.

## Manual verification (no automated live writes)

1. Use existing accounts A/B in two app sessions/Macs. A searches B's friend code.
   Finding must not create a request. Send explicitly; A sees request waiting, not friend.
2. Activate/enter B's friend screen or refresh. Confirm name/code, pending badge,
   receiver-only accept/reject controls. Accept; B's pending row disappears and B
   sees A. Activate/refresh A; A sees B and no outgoing pending.
3. Re-search an existing friend; no request can be sent. Before acceptance, re-search
   in both directions: outgoing shows waiting; incoming offers acceptance.
4. Test nearly simultaneous opposite sends; one pending pair survives, both screens
   reflect the actual direction. Unit race recovery is fake-only; live confirmation
   remains manual.
5. Delete with confirmation from either participant. Refresh both apps: active lists
   are empty for that pair; the server row remains with ended_at. No Task/TaskEvent/
   Space records should be deleted by this action.
6. Reject a new pending request; no friendship appears. Re-request after rejection;
   a new pending row is permitted by the partial unique index.
7. Disconnect network and refresh; retain loaded lists with a small error. Restore
   network/refresh. Log out/switch account with the + sheet open: no old lists or
   confirmed search recipient may survive.
8. Verify the authorization boundary with an existing third account C (do not use
   service_role): A/B's request and friendship rows must not be readable by C;
   C cannot accept/reject/remove A/B's relations. Fake permission tests are not a
   substitute for testing deployed RLS/RPC grants with authenticated sessions.

No UI Tests. Validate all Unit Tests, Debug/Release builds, and git diff --check.
