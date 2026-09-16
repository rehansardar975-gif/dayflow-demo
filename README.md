# Dayflow

A daily planner and time tracker whose timer can't lose time.

**Live demo:** https://dayflow-demo.vercel.app — click "Log in as demo user"  
**Source code (starter kit):** https://dayflowkit.gumroad.com/l/dayflow  
**Design notes:** [docs/timer-design.md](docs/timer-design.md) · [Dev.to article](https://dev.to/rehansardar975gif/building-a-timer-that-survives-browser-crashes-nextjs-supabase-14e2)

![Day view with a running timer](https://dayflow-demo.vercel.app/marketing/02-day-view-timer-running.png)

## What it does

Plan your day → work on tasks → track actual time → compare planned vs actual → review your week.

- Daily timeline with planned / actual / remaining totals
- One-click timers, multiple sessions per task
- Move unfinished tasks to another day (tracked time comes along)
- Weekly review with a planned-vs-actual chart

## The timer

Elapsed time is derived from `started_at` / `ended_at` stored in Postgres — never from a browser counter.

- Refresh, tab switch, laptop sleep, browser close: still correct
- One running timer per user, enforced by a partial unique index
- Start / stop / complete are atomic SQL functions on the database clock
- If the app was closed mid-timer, it asks: stop at last activity, stop now, or keep running

![Recovery dialog](https://dayflow-demo.vercel.app/marketing/09-timer-recovery-dialog.png)

## Schema

The full Postgres schema — tables, indexes, triggers, Row Level Security policies and the timer functions — is in [`supabase/migrations/0001_init.sql`](supabase/migrations/0001_init.sql) (MIT, see `LICENSE-SCHEMA.md`).

![Weekly history](https://dayflow-demo.vercel.app/marketing/05-weekly-history.png)

## Stack

Next.js 15 (App Router, Server Actions) · React 19 · TypeScript · Tailwind CSS 4 · Supabase (Postgres, Auth, RLS)

## Get the source

The complete application (60 TypeScript files, README, license) is sold as a starter kit:
**https://dayflowkit.gumroad.com/l/dayflow** — unlimited projects, commercial use, free 1.x updates.

## FAQ

**Is this open source?** The schema and design notes are MIT. The app source is a paid kit.  
**Can I use the SQL in my own project?** Yes, MIT.  
**Does the demo reset?** Nightly.
