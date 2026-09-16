# Building a timer that survives browser crashes (Next.js + Supabase)

Design notes for the timer in [Dayflow](https://dayflow-demo.vercel.app). Also published on [Dev.to](https://dev.to/rehansardar975gif/building-a-timer-that-survives-browser-crashes-nextjs-supabase-14e2).

Every time-tracking tutorial starts the same way:

```js
setInterval(() => setSeconds(s => s + 1), 1000);
```

And every one of them is wrong the moment the user closes the laptop lid.

## 1. Store timestamps, not counters

A timer session is a row (see [`supabase/migrations/0001_init.sql`](../supabase/migrations/0001_init.sql)):

```sql
create table time_sessions (
  id uuid primary key,
  user_id uuid not null,
  task_id uuid not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,          -- null = running
  duration_seconds integer,      -- set by trigger when ended_at is set
  last_heartbeat_at timestamptz not null default now()
);
```

Elapsed time on the client is `Date.now() − started_at` (corrected by the server-clock offset the page was rendered with). A 1-second `setInterval` only triggers a re-render. Nothing accumulates, so a throttled background tab or a 3-hour sleep changes nothing.

## 2. Enforce "one running timer" in the database

```sql
create unique index one_active_timer_per_user
  on time_sessions (user_id) where ended_at is null;
```

Two tabs, a double-click, or a retried request physically cannot create two running timers.

## 3. Make start/stop atomic and use the database clock

`start_timer()`, `stop_timer()` and `set_task_status()` are `security invoker` plpgsql functions: `auth.uid()` and Row Level Security still apply inside, but the multi-step logic (close old session → insert new → flip task status) is one transaction on `now()`. The client never sends a timestamp when starting; the browser clock is untrusted.

## 4. Handle "the browser was closed while running"

If someone starts a timer at 14:00, closes the laptop at 14:05, and reopens it at 17:00 — were they working for three hours? You can't know. So ask.

While a timer runs, the tab posts a heartbeat every 60 seconds (and via `navigator.sendBeacon` on `pagehide`). It only updates `last_heartbeat_at`. On the next page load, if the last heartbeat is more than 5 minutes old, the app shows:

> Your timer is still running. *Client Work* has been running for 3h. The app was last open at 14:05.
> **[Stop at 14:05] [Stop now] [Keep running]**

"Stop at 14:05" calls `stop_timer(session_id, last_heartbeat_at)`; the SQL clamps the value to `[started_at, now()]`. A plain refresh never triggers this because the heartbeat is fresh.

## 5. Completing a task stops its timer — in the same transaction

`set_task_status()` closes any running session for the task before flipping the status, so a "completed task with a running timer" state is impossible.

## 6. RLS gotcha

A foreign key does not go through RLS. The insert policy on `time_sessions` therefore also checks that the referenced task belongs to `auth.uid()` — otherwise a user could attach a session to someone else's task by guessing a UUID.

---

The full application (planner, timer, weekly review, auth) is available as a starter kit: https://dayflowkit.gumroad.com/l/dayflow
