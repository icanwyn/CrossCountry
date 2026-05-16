# XC Chrono — Cross Country Timer

Multi-device, real-time cross-country meet timing. Roster intake, dual-operator timing (start-line + chute), and official XC scoring. Supabase + Vercel. No build step.

## Stack

- **Frontend**: One `index.html`, vanilla JS, hash-routed.
- **Backend**: Supabase Postgres + Realtime + SECURITY DEFINER RPCs. Director password protects writes.
- **Hosting**: Vercel static + one tiny serverless function (`/api/env`) to inject env vars at request time.

## Multi-device realtime sync

Every device that opens a meet code subscribes to a Supabase Realtime channel (`meet:CODE`). Any insert/update/delete on `taps`, `results`, `runners`, `teams`, or `meets` is pushed to all connected devices in <1s. A **LIVE / OFFLINE** indicator sits in the header.

## Auth model

- A **6-char meet code** is the share link (e.g. `K7P2RX`). Anyone with the code can **view** rosters and results.
- The director sets a **password** when creating the meet. Operators (coaches, timer, recorder) need it to write.
- The password unlocks a device once; an opaque session token is stored in `localStorage` and re-used. A **🔓 UNLOCKED** badge in the header shows status. Tap **Lock** to clear.
- All writes go through SECURITY DEFINER Postgres RPCs that verify the token. Direct table writes from anon are blocked.
- Tokens expire after 24h.

## Setup

### 1. Supabase
1. Create a project at https://supabase.com.
2. Open the SQL Editor and run `schema.sql` end-to-end.
3. Project Settings → API → copy **Project URL** and **anon public** key.

### 2. Vercel
1. Push the project to GitHub (or `vercel deploy` locally).
2. In the Vercel dashboard → Project → Settings → Environment Variables, add:
   - `SUPABASE_URL` → your project URL
   - `SUPABASE_ANON` → your anon key
3. Redeploy.

### 3. Local dev (optional)
```bash
cp env.example.js env.js
# edit env.js with your values
npx serve .
```

## Project layout

```
xc-timer/
├── index.html          # the whole app
├── api/
│   └── env.js          # serverless function — injects SUPABASE_URL + ANON
├── env.example.js      # local-dev fallback
├── schema.sql          # Postgres tables, RLS, RPCs, realtime publication
├── vercel.json         # rewrites for /m/:code clean URLs
└── README.md
```

## Day-of-meet flow

1. **Director** opens the app on their laptop, **Create Meet**, fills in name + password, gets the 6-char code. Both the **code** AND **password** get shared with coaches.
2. **Each coach** opens the app on their device, enters the code, taps **Coach**, gets prompted for the password (only first time on that device), types their school name, uploads CSV (`first,last,grade,gender`). Bibs auto-assigned: team 1 → `1001+`, team 2 → `2001+`, …
3. **Start-line phone**: tap **Timer**, **START RACE**, then **TAP FINISH** as each runner crosses.
4. **Chute phone/tablet**: tap **Recorder**, type bib for each runner in chute order, hit Enter. Live name preview confirms the bib.
5. Anyone (no password needed) taps **Results** — official NFHS scoring: top 5 score, 6 & 7 displace, 6th-runner tiebreaker.

## CSV format

```
first,last,grade,gender
Jamal,Reeves,11,M
Lina,Park,10,F
```

Extra columns are ignored. Grade and gender are optional but recommended for boys/girls splits later.

## Concurrency safety

Three atomic RPCs guard the race-prone operations:

- `add_tap(token, meet, time_ms)` — picks `max(place) + 1` and inserts in one statement, so two timer devices can't double-count.
- `add_result(token, meet, bib)` — same idea for the chute.
- `register_team(token, meet, team)` — assigns next `team_index` atomically, so two coaches uploading simultaneously get distinct bib blocks.

## Security notes

- Director password is stored as a `bcrypt` hash via `pgcrypto`. Verification happens server-side in `login_meet`.
- The `meets` table is not directly readable by anon — the app reads a `public_meets` view that strips `password_hash`.
- Anon can call write RPCs but each verifies a session token before doing anything.
- Tokens are opaque random bytes, not JWTs. They live in the `sessions` table and expire after 24h.

## Limitations / nice-to-haves

- **No boys/girls split scoring yet**. Easy add: filter `results` by gender before passing to `scoreMeet`.
- **One race per meet code**. For varsity/JV/different distances, create separate meet codes per race.
- **No CSV export of results**. Tell me if you want a "Download Results" button on the Results page.
- **Tap-undo at the timer**. Right now if the timer mis-taps, they have to reset the race or use the recorder to log a placeholder. A "void last tap" RPC is straightforward to add.
