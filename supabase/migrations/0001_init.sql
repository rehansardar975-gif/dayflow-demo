-- Dayflow: initial schema
-- Run this in the Supabase SQL editor (or via `supabase db push`).
--
-- Design notes
--  * tasks           one row per planned task, owned by a user
--  * time_sessions   one row per start/stop of the timer. A task can have many.
--                    Elapsed time is always derived from timestamps, never from a
--                    client-side counter.
--  * One active timer per user is enforced by a partial unique index.
--  * All start/stop logic lives in SQL functions so it is atomic and uses the
--    database clock (now()), not the browser clock.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.task_status as enum ('pending', 'in_progress', 'completed', 'cancelled');
create type public.task_priority as enum ('low', 'medium', 'high');

-- ---------------------------------------------------------------------------
-- tasks
-- ---------------------------------------------------------------------------
create table public.tasks (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  title             text not null check (char_length(btrim(title)) between 1 and 200),
  description       text check (description is null or char_length(description) <= 2000),
  scheduled_date    date not null,
  start_time        time without time zone,                       -- null = unscheduled for that day
  estimated_minutes integer check (estimated_minutes is null or (estimated_minutes > 0 and estimated_minutes <= 1440)),
  status            public.task_status not null default 'pending',
  priority          public.task_priority,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index tasks_user_date_idx on public.tasks (user_id, scheduled_date, start_time);

-- ---------------------------------------------------------------------------
-- time_sessions
-- ---------------------------------------------------------------------------
create table public.time_sessions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  task_id           uuid not null references public.tasks (id) on delete cascade,
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,                                  -- null = timer is running
  duration_seconds  integer,                                      -- maintained by trigger
  last_heartbeat_at timestamptz not null default now(),           -- last time a client confirmed the timer was "alive"
  created_at        timestamptz not null default now(),
  constraint time_sessions_end_after_start check (ended_at is null or ended_at >= started_at)
);

create index time_sessions_task_idx on public.time_sessions (task_id);
create index time_sessions_user_started_idx on public.time_sessions (user_id, started_at);

-- Only one running timer per user, guaranteed at the database level.
create unique index time_sessions_one_active_per_user
  on public.time_sessions (user_id)
  where ended_at is null;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create trigger tasks_set_updated_at
  before update on public.tasks
  for each row execute function public.set_updated_at();

create or replace function public.set_session_duration()
returns trigger language plpgsql as $$
begin
  if new.ended_at is not null then
    new.duration_seconds = greatest(0, round(extract(epoch from (new.ended_at - new.started_at))))::integer;
  else
    new.duration_seconds = null;
  end if;
  return new;
end $$;

create trigger time_sessions_set_duration
  before insert or update on public.time_sessions
  for each row execute function public.set_session_duration();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.tasks enable row level security;
alter table public.time_sessions enable row level security;

create policy "tasks: select own"  on public.tasks for select using (auth.uid() = user_id);
create policy "tasks: insert own"  on public.tasks for insert with check (auth.uid() = user_id);
create policy "tasks: update own"  on public.tasks for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "tasks: delete own"  on public.tasks for delete using (auth.uid() = user_id);

create policy "sessions: select own" on public.time_sessions for select using (auth.uid() = user_id);
create policy "sessions: insert own" on public.time_sessions for insert with check (
  auth.uid() = user_id
  and exists (select 1 from public.tasks t where t.id = task_id and t.user_id = auth.uid())
);
create policy "sessions: update own" on public.time_sessions for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "sessions: delete own" on public.time_sessions for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Timer functions (security invoker: RLS still applies inside)
-- ---------------------------------------------------------------------------

-- Start a timer on a task. If another timer is running:
--   p_stop_active = false -> raises 'active_timer_exists' (client asks the user)
--   p_stop_active = true  -> stops it first, then starts the new one
-- Starting the task that is already running is a no-op that returns the session.
create or replace function public.start_timer(p_task_id uuid, p_stop_active boolean default false)
returns public.time_sessions
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_task   public.tasks;
  v_active public.time_sessions;
  v_new    public.time_sessions;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_task from public.tasks where id = p_task_id and user_id = v_uid for update;
  if not found then
    raise exception 'task_not_found';
  end if;
  if v_task.status in ('completed', 'cancelled') then
    raise exception 'task_closed';
  end if;

  select * into v_active from public.time_sessions
    where user_id = v_uid and ended_at is null
    for update;

  if found then
    if v_active.task_id = p_task_id then
      return v_active;
    end if;
    if not p_stop_active then
      raise exception 'active_timer_exists';
    end if;
    update public.time_sessions set ended_at = now() where id = v_active.id;
  end if;

  insert into public.time_sessions (user_id, task_id)
    values (v_uid, p_task_id)
    returning * into v_new;

  update public.tasks set status = 'in_progress'
    where id = p_task_id and status = 'pending';

  return v_new;
end $$;

-- Stop a running timer. p_ended_at lets the client stop "at last activity"
-- (e.g. when the browser was closed); it is clamped to [started_at, now()].
create or replace function public.stop_timer(p_session_id uuid, p_ended_at timestamptz default null)
returns public.time_sessions
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_s   public.time_sessions;
  v_end timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_s from public.time_sessions
    where id = p_session_id and user_id = v_uid
    for update;
  if not found then
    raise exception 'session_not_found';
  end if;
  if v_s.ended_at is not null then
    return v_s;
  end if;

  v_end := coalesce(p_ended_at, now());
  if v_end < v_s.started_at then v_end := v_s.started_at; end if;
  if v_end > now() then v_end := now(); end if;

  update public.time_sessions set ended_at = v_end
    where id = p_session_id
    returning * into v_s;
  return v_s;
end $$;

-- Called periodically by an open tab while a timer runs.
create or replace function public.heartbeat_timer(p_session_id uuid)
returns void
language sql
security invoker
set search_path = public
as $$
  update public.time_sessions
     set last_heartbeat_at = now()
   where id = p_session_id
     and user_id = auth.uid()
     and ended_at is null;
$$;

-- Change a task's status. Completing or cancelling a task stops its running timer.
create or replace function public.set_task_status(p_task_id uuid, p_status public.task_status)
returns public.tasks
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_task public.tasks;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_task from public.tasks where id = p_task_id and user_id = v_uid for update;
  if not found then
    raise exception 'task_not_found';
  end if;

  if p_status in ('completed', 'cancelled') then
    update public.time_sessions set ended_at = now()
      where task_id = p_task_id and user_id = v_uid and ended_at is null;
  end if;

  update public.tasks set status = p_status
    where id = p_task_id
    returning * into v_task;
  return v_task;
end $$;

revoke execute on function public.start_timer(uuid, boolean)                    from anon, public;
revoke execute on function public.stop_timer(uuid, timestamptz)                 from anon, public;
revoke execute on function public.heartbeat_timer(uuid)                         from anon, public;
revoke execute on function public.set_task_status(uuid, public.task_status)     from anon, public;
grant  execute on function public.start_timer(uuid, boolean)                    to authenticated;
grant  execute on function public.stop_timer(uuid, timestamptz)                 to authenticated;
grant  execute on function public.heartbeat_timer(uuid)                         to authenticated;
grant  execute on function public.set_task_status(uuid, public.task_status)     to authenticated;
