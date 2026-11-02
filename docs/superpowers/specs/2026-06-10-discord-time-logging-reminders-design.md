# Discord Time-Logging Reminders — Design

**Date:** 2026-06-10
**Status:** Approved, ready for implementation plan

## Problem

Some team members forget to log their hours. We want Clar to check specific
watched users each weekday and, if a user logged too little over the last few
working days, post a reminder into a Discord **group DM** ("Go Go power
rangers!"), @-mentioning that person.

## Delivery mechanism (verified working)

Group DMs cannot receive Discord webhooks or bot messages — only a **user
account token** can post to them. A throwaway account (`clarhelper`,
id `1488606033470427209`) was created and added to the group. Confirmed live:

- `GET /users/@me` → 200, user token (not a bot).
- `GET /channels/1159158381194522684` → 200, type 3 (group DM), name
  "Go Go power rangers!", 4 recipients.
- `POST /channels/{id}/messages` → 200, message delivered.

API base: `https://discord.com/api/v10`. Auth header is the raw user token
(NO `Bot ` prefix). Send a `User-Agent` header.

**Security:** the token is a secret granting full access to the `clarhelper`
account. Store it in **Rails encrypted credentials**, never plaintext env. The
token used during testing is considered burned and must be reset before launch;
the fresh token goes into credentials. ToS note: automating a user account is a
Discord ToS gray area; volume here is ≤ a few messages/day into one private
group, accepted by the user.

### Credentials (Rails encrypted credentials)

```yaml
discord:
  user_token: "<clarhelper account token>"
  group_channel_id: "1159158381194522684"
```

Accessed via `Rails.application.credentials.dig(:discord, :user_token)` and
`:group_channel_id`. If either is blank, the feature no-ops (logs and returns).

## Components

### 1. `DiscordGroupClient` (service) — `app/services/discord_group_client.rb`

Thin wrapper over the Discord HTTP API.

- `initialize(token: ..., channel_id: ...)` defaulting to credentials values.
- `post(content)` → `POST /channels/{channel_id}/messages` with the auth +
  user-agent headers and `{ content: }` JSON. Returns true on 2xx; on non-2xx or
  network error, logs `Rails.logger.error` and returns false (never raises into
  the caller). Uses **`Net::HTTP`** with open/read timeouts and a rescue of
  `Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED`,
  mirroring the existing `JiraClient` convention (the app has no HTTP gem).
- `configured?` → true when both token and channel_id present.

### 2. `DiscordReminderRecipient` (model) — table `discord_reminder_recipients`

Who to watch, per workspace.

Columns:
- `workspace_id` (FK, not null)
- `user_id` (FK to users, not null) — the Clar user whose hours are checked
- `discord_user_id` (string, not null) — the numeric snowflake, rendered as
  `<@discord_user_id>` to ping
- `min_daily_hours` (decimal, not null, default 4.0)
- `active` (boolean, not null, default true)
- timestamps
- unique index on `[workspace_id, user_id]`

Validations: `discord_user_id` present and matches `/\A\d+\z/`;
`min_daily_hours` > 0; `user_id` unique per workspace.

Associations: `belongs_to :workspace`, `belongs_to :user`.

### 3. Admin UI — section on Workspace Settings

Extend `WorkspaceSettingsController` + `workspace_settings/show.html.erb` (admin
only, already `require_admin!`). Add a **"Discord reminders"** section:

- Lists current recipients: user name, Discord ID, threshold, active toggle,
  remove.
- A form to add a recipient: select a workspace user, enter Discord ID, set
  threshold (default 4.0).
- CRUD handled by a dedicated `DiscordReminderRecipientsController`
  (`require_admin!`, workspace-scoped): `create`, `update`, `destroy`, each
  redirecting back to `workspace_settings_path`. Route nested or flat under the
  workspace; flat `resources :discord_reminder_recipients, only: [:create,
  :update, :destroy]` is sufficient.

### 4. The check — `DiscordReminderJob` — `app/jobs/discord_reminder_job.rb`

Recurring (Solid Queue), weekday mornings.

Logic (per workspace that has active recipients):
1. Return early unless `DiscordGroupClient` is `configured?`.
2. Compute the **last 3 working days** (Mon–Fri) ending yesterday (do not count
   today, which is still in progress). Helper: walk back from `Date.yesterday`
   collecting non-weekend days until 3 collected.
3. For each active recipient:
   - Determine that user's **eligible** days = the 3 working days minus any day
     covered by an **approved** `HolidayRequest` for that user
     (`status: approved`, `start_date <= day <= end_date`).
   - If no eligible days remain (e.g. on holiday the whole window), skip.
   - For each eligible day, sum the user's `time_entries.completed`
     `duration_seconds` for that calendar day (workspace-scoped).
   - Flag the user if **any** eligible day is below `min_daily_hours * 3600`
     seconds.
4. Collect flagged recipients. For each, enqueue a `DiscordReminderMessageJob`
   spaced 2 minutes apart: `DiscordReminderMessageJob.set(wait: index *
   2.minutes).perform_later(recipient_id)`.
5. If none flagged, do nothing (no message).

Defensive: the job no-ops on weekends (guards in case the schedule fires oddly).

### 5. `DiscordReminderMessageJob` — `app/jobs/discord_reminder_message_job.rb`

One per flagged recipient (staggered by the parent job).

- Loads the recipient (skip if gone/inactive).
- Builds content:
  `<@{discord_user_id}> you logged under {min_daily_hours}h on one or more of
  the last 3 working days — please log your time 🙏`
- Calls `DiscordGroupClient.new.post(content)`.

Splitting the actual POST into its own job gives the **2-minute spacing via the
queue** (real wall-clock delay, not `sleep`), per-message retry isolation, and
one failure not blocking the others.

### Scheduling — `config/recurring.yml` (production)

```yaml
  discord_time_logging_reminders:
    class: DiscordReminderJob
    schedule: "0 9 * * 1-5"   # 09:00, Mon–Fri
```

## Testing (Minitest)

- **`DiscordReminderRecipient`:** validations (discord_user_id format,
  min_daily_hours > 0, uniqueness per workspace).
- **`DiscordGroupClient`:** with HTTP stubbed, `post` builds the right URL, auth
  header (raw token, no `Bot `), and JSON body; returns true on 200, false on
  500/network error without raising; `configured?` reflects credential presence.
- **`DiscordReminderJob`:**
  - user below threshold on an eligible working day → a `DiscordReminderMessageJob`
    is enqueued for them (assert_enqueued_with), with staggered `wait`.
  - user at/above threshold on all eligible days → not enqueued.
  - a below-threshold day that is an approved holiday → excluded; if all window
    days are holiday, user skipped.
  - weekend days are not counted in the window.
  - no recipients flagged → no message jobs enqueued.
  - unconfigured credentials → job returns without enqueuing.
- **`DiscordReminderMessageJob`:** builds the `<@id>` content with the threshold
  and calls `DiscordGroupClient#post` once (client stubbed).
- **`DiscordReminderRecipientsController`:** admin can create/update/destroy;
  employee blocked (redirect to root).

## Out of scope

- Posting to anything other than the one configured group DM.
- Multiple Discord destinations / per-recipient channels.
- Reminders for non-watched users.
- Deploy/Jira-event notifications (separate idea, not built).
