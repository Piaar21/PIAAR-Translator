# Quick Add and deferred Tasks

Production uses a Foundation-only deterministic QuickAddParser. No AI call or
clipboard monitoring is involved. Full, Mini and Space inline entry share it.
Dates are civil TaskDay values, explicit scheduled_at is an instant, and
start_at/deadline_at/deadline_date retain their original deadline meaning.
Monday begins an explicit calendar week. Bare weekdays include today. Bare 3시
is not guessed; unknown/invalid/unsupported recurrence text remains in the title.
Recognized token ranges never overlap. Estimated duration is 1–1440 minutes;
priority is normal/important. Preview always reserves one line.

Full Enter keeps input focus. Mini Enter closes only after successful saving;
Command+Enter retains it. Space inline Enter closes the control after success;
Command+Enter keeps the input and resets the recipient to self. Native marked
text Enter is never intercepted as submission.

scheduled_date NULL is Someday. It is loaded separately and excluded from date
queries, today's Mini, deferred Tasks and Calendar red dots. The Full menu opens
Someday; its self Tasks use the existing editor to choose a date.
The previous recent-three-day UI is replaced by one deferred section covering
all overdue assigned open Tasks. Overdue age is Calendar arithmetic, not persisted.
Received Tasks can show age but allow only completion/reopen. Sent Tasks aren't
cleanup candidates. Recurrence templates/instances cannot reschedule or archive.
Archived Space Tasks remain read-only.

## Confirmed RPC contract supplied by developer

reschedule_task returns public.tasks. Parameters:
p_task_id, p_command_id, p_expected_scheduled_date, p_expected_scheduled_at,
p_expected_day_period, p_target_scheduled_date, p_target_scheduled_at,
p_target_day_period. The six schedule fields explicitly encode NULL where needed.
archive_task returns public.tasks, with p_task_id and p_command_id.
Both use SECURITY INVOKER and atomically write their events using server profile
snapshots. The client does not enqueue those Events or write defer_count or
last_deferred_at. Retry preserves command UUID; a changed cleanup target gets a
new command. Schedule conflict refreshes server state without automatic overwrite.

The ordinary editor also uses reschedule_task for schedule changes. Its expected
schedule comes from the opened Task, not a later fetch. Content UPDATE excludes
all three schedule fields. A simultaneous content change and reschedule remain
separate operations: if the content save fails after schedule success, the editor
stays open with an error and retry reuses the schedule command.

Legacy import is not executed. Missing new fields decode as nil/normal/0 without
inventing historical values. Todo.store, schema, RLS, friends, Space structure,
Translator and shortcuts are unchanged. Unit Tests inject in-memory fakes.

## Manual checks

- Type the full example and confirm title/date/15:00/30 minutes/important without
  creating a deadline or D-DAY. Try unknown text, bare 3시 and unsupported repetition.
- Confirm no preview height movement and correct Korean IME composition.
- Verify Full Enter, Mini Enter/Command+Enter/Escape and Space inline Enter/
  Command+Enter with real native focus and recipient reset.
- Review an old self Task, choose today/tomorrow/date/Someday, and verify server
  count/history. Reopen Someday from Full and schedule it again.
- Confirm received/recurring/archived-Space tasks cannot be organized.
- Simulate a network timeout and retry; one command/Event and count increment.
- Change schedule on a second Mac while Editor is open: conflict must display
  latest state, without automatically retrying or overwriting it.
- Verify archive hides the Task while preserving its server row and History.
- Verify logout clears input, Someday, deferred lists and pending actions.

No automated live write, actual migration or UI Test was performed.
