# Supabase collaboration account

## Configuration

The app bundles the local, Git-ignored file
`PIAAR Translator/Services/Supabase/SupabaseConfiguration.plist`.
Before building a fresh checkout, copy `SupabaseConfiguration.plist.example` in
that directory to `SupabaseConfiguration.plist`, then set ProjectURL and the
active `sb_publishable_...` PublishableKey. The example contains no credentials.
Never commit the populated configuration or inject sb_secret, service_role,
a database password, a JWT secret, or a user access/refresh token here. The
validator accepts only the modern publishable key format.

The Dashboard and Supabase connector were unavailable in this session. Neither
current API key activation nor email confirmation settings nor deployed RLS were
verified remotely. No server setting/schema was modified.

## Boundaries

AuthViewModel -> AuthRepository + CollaborationProfileRepository ->
SupabaseAccountRepository -> official Supabase Swift SDK 2.49.0.
Package.resolved also locks Xcode 15.4 / Swift 5.10 compatible transitive versions.
No custom token refresh or JWT parsing. SDK KeychainLocalStorage uses a separate
service `com.piaar.PIAAR-Translator.SupabaseAuth` and storage key
`piaar-supabase-session`; existing OpenAI Keychain identifiers remain untouched.
The SDK stores/restores its own session and performs refresh. Its local sign-out
clears this device's session; server revocation errors are surfaced, without
retaining a signed-in screen after local credentials have already been removed.

Signup passes metadata.display_name. The existing server trigger must insert
profiles and generate friend_code; the client never inserts a profile or
generates a collaboration code. A signup response without a session is the
normal confirmation-pending path. Confirm email in the browser then sign in with
email/password; no deep-link callback is needed for this phase. A signup response
alone does not prove server profile creation (and may intentionally conceal an
already-registered address).

Profile reads/updates require a valid SDK session, filter by its Auth UUID, and
only update display_name. RLS and server column permissions must enforce owner
access and friend_code immutability independently of client code. Verify those
with Dashboard/SQL privileges: client filtering alone is not security.

CloudKit profile/service remain in the project unchanged, but Full's profile is
Supabase-backed. There is no CloudKit <-> Supabase identity mapping or migration.
Full collaboration entries require login. Existing Mock features are retained
with an explicit Mock banner; their UUIDs, tasks and rooms remain memory-only and
are not sent to Supabase or reattributed to the authenticated person. Mini and
local Todo continue their existing behavior. Real friends/tasks/rooms are future
repository replacements, not part of this phase.

## Manual validation

1. Supply active publishable key and rebuild Debug.
2. Verify Auth email confirmation settings without disabling them.
3. Register one test account; inspect auth.users and trigger-created profiles.
4. If confirmation is enabled, verify pending UI, confirm email, then log in.
5. Verify profiles.id equals Auth UUID and displayed server friend_code.
6. Quit/relaunch and verify restored login and stable profile/code.
7. Rename and verify only own display_name changes; attempt unauthorized row and
   friend_code updates with a normal user JWT to validate server permissions.
8. Logout/login, including offline/revocation failure; local Todo/Translator stay.
9. Verify Mock banner and separate identities; real collaboration is not claimed.

Unit tests use fake repositories and temporary/in-memory Todo storage. Do not
run UI tests or automatically create real server accounts.
