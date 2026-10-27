# Exerly Fitness

**A cross-platform fitness companion that helps you track workouts, nutrition, and sleep — with AI-powered coaching built in.**

[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Web-blue)](#)
[![Node](https://img.shields.io/badge/node-%3E%3D22%20%3C27-brightgreen)](https://nodejs.org)
[![License](https://img.shields.io/badge/license-proprietary-red)](LICENSE)

---

## What is Exerly?

Exerly is a fitness platform designed for people who want one place to manage their health. Instead of juggling separate apps for workouts, food, and sleep, Exerly combines everything into a single experience across iOS and web.

The iOS app is built natively in SwiftUI with deep Apple ecosystem integration — HealthKit syncing, barcode scanning for food logging, and a personalized onboarding flow that builds a custom plan based on your body, goals, and schedule. The web dashboard gives you a broader view of your data with admin tools and analytics.

An AI coaching assistant (powered by Google Gemini) can generate workout plans, nutrition advice, and progress analysis based on your logged data.

---

## Core Features

**Adaptive nutrition**

- Daily weigh-ins smoothed into a trend, so you judge progress on the line and not the noise
- Expenditure measured from what you actually ate and how the trend moved, rather than a BMR formula
- Weekly check-ins that move your calorie and macro targets to match the measurement
- Choose a goal rate in kg/week; the split follows from your diet type and protein strategy

**Food logging**

- Search across FatSecret and Open Food Facts, or scan a barcode with the camera
- Serving quantities, so 1.5 portions is one entry and not mental arithmetic
- A personal library that fills itself from what you log, with favourites and recents
- Recipes that divide into per-serving macros
- Log to any past day, in your own timezone

**Tracking**

- 30+ activity types with intensity and calorie estimation
- Sleep with bedtime/wake time and quality
- Water in millilitres
- JSON export of account details, daily logs, programs and personal foods

**Intelligence**

- Six-screen signup and setup with saved drafts, editable targets and a starting plan
- AI coach that answers fitness questions and builds workout plans, aware of your current targets

**Health Integration**

- Apple HealthKit: reads steps and active calories, writes workouts
- Progress photo tracking with compare mode (stored per-user on device)

**Admin**

- Admin panel on both iOS and web for user management and system monitoring
- Toggle admin privileges, view aggregate stats, manage AI error logs

---

## Architecture

```
Exerly-Fitness/
├── apps/
│   ├── api/
│   │   ├── data/       Storage adapter: one interface, PostgreSQL driver
│   │   ├── lib/        Dates, auth, validation, and the nutrition algorithms
│   │   ├── routes/     One module per resource
│   │   ├── db/         Numbered SQL migrations and the migration runner
│   │   ├── tests/      Unit tests plus integration tests against PostgreSQL
│   │   ├── app.js      Express assembly (no database, no listen)
│   │   └── index.js    Entry point: connect, listen, shut down cleanly
│   ├── web/        React dashboard (Vite + TypeScript + Tailwind)
│   └── ios/        Native iOS app (SwiftUI) and ExerlyCore, its logic package
├── docs/           Master plan and API reference
├── .do/            DigitalOcean deployment spec
└── package.json    Monorepo workspace root
```

The API runs on PostgreSQL. Routes talk to `data/` and never to a driver directly.
The schema lives in numbered SQL migrations under `apps/api/db/migrations`, which
the server applies before it listens. A SQLite driver remains only for the
isolated iOS simulator fixture.

The two pieces worth reading are `lib/nutrition.js`, which holds the trend
smoothing and expenditure estimation, and `data/schema.js`, which is the single
definition the driver and the initial migration agree on.

See [docs/MASTER_PLAN.md](docs/MASTER_PLAN.md) for the roadmap and the reasoning
behind the current design.

---

## Tech Stack

| Layer     | Technology                                              |
| --------- | ------------------------------------------------------- |
| iOS       | SwiftUI, HealthKit, AVFoundation, SwiftData             |
| Web       | React 19, TypeScript, Vite, Tailwind CSS, Framer Motion |
| API       | Node.js, Express 5, node-postgres, JWT, bcrypt          |
| Database  | PostgreSQL 16 (Supabase in prod, Docker self-hosted)    |
| AI        | Google Gemini 2.0 Flash                                 |
| Food Data | FatSecret API (primary), Open Food Facts (fallback)     |
| Hosting   | DigitalOcean App Platform (API), GitHub Pages (web)     |

---

## Getting Started

### Prerequisites

- Node.js 22 through 26, with Node 22 used in CI
- Xcode 16.4 supports the local compatibility simulator checks. App Store release checks require Xcode 26 or later and a platform 26 SDK.

### Install and run

```bash
git clone https://github.com/sidebandstudio/Exerly-Fitness.git
cd Exerly-Fitness
npm run install:all
npm run local
```

This starts the API on `localhost:3001` and the web dashboard on `localhost:3000`
using SQLite. No MongoDB, no API keys, nothing to sign up for.

Both servers bind to `0.0.0.0`, so a phone on the same wifi or another machine on
the tailnet can reach them; the web app resolves the API from whatever host it
was loaded from.

### iOS

Open `apps/ios/Exerly.xcodeproj` in Xcode, select your device or simulator, and run.

### Testing

```bash
npm test                    # API tests on a throwaway PostgreSQL cluster
npm run smoke:api           # boot the API on PostgreSQL and log a day
swift test --package-path apps/ios/ExerlyCore   # ExerlyCore logic
npm run test:web            # browser journeys with an isolated API and web server
npm run ios:test            # native unit and simulator UI tests
npm run test:cross-client   # iPhone -> browser -> iPhone on one isolated account
npm run ios:release-check   # verify the upload toolchain requirement
```

Integration tests boot the actual Express app against PostgreSQL, each test file in
its own schema, so they exercise routing, auth, validation, and storage together
rather than mocking any of it. `npm test` needs the PostgreSQL server binaries
(`initdb`, `pg_ctl`) on the machine; it starts a cluster on a Unix socket and
removes it afterwards.

Browser tests use installed Chrome by default. For Playwright Chromium, run
`npx playwright install chromium` and set `PLAYWRIGHT_CHANNEL=chromium`.
Native tests require Xcode and an installed iPhone simulator. The native and
cross-client scripts manage their own isolated fixture on port 39001; do not run
those two commands at the same time. Web-only tests use ports 39002 and 3301.
The cross-client script also uses port 3303 and saves evidence under `artifacts/`.

The [mobile production ledger](docs/MOBILE_PRODUCTION_STATUS.md) records completed
checks, screenshots, unfinished implementation and external release gates.

### Production

The API auto-deploys to DigitalOcean App Platform on every push to `main`, built
from `apps/api/Dockerfile`.
Environment variables (`DATABASE_URL`, `JWT_SECRET`, `ADMIN_EMAILS`,
`GEMINI_API_KEY`, and optionally the FatSecret pair) are configured in the DO
dashboard. See [apps/api/.env.example](apps/api/.env.example) for the full list.
The database is a Supabase project, and `DATABASE_URL` is its session pooler URL; see
[apps/api/db/README.md](apps/api/db/README.md#supabase).

### Self-hosting

```bash
JWT_SECRET=$(openssl rand -hex 32) POSTGRES_PASSWORD=$(openssl rand -hex 16) docker compose up -d
```

This runs PostgreSQL 16 and the API on port 8080; set `EXERLY_API_PORT` to change
it. Backups and migrations are described in [apps/api/db/README.md](apps/api/db/README.md).

---

## Scripts

| Command             | What it does                                       |
| ------------------- | -------------------------------------------------- |
| `npm run local`     | API + web in local mode (SQLite, no external deps) |
| `npm run dev`       | API + web in production mode (PostgreSQL)          |
| `npm run dev:api`   | API only                                           |
| `npm run dev:web`   | Web only                                           |
| `npm run build:web` | Production build of web dashboard                  |
| `npm run ios:build` | Build iOS via CLI                                  |
| `npm run lint`      | ESLint across api + web                            |
| `npm run format`    | Apply Prettier formatting                          |
| `npm run typecheck` | TypeScript type-check (web)                        |
| `npm test`          | API unit and integration tests (`node:test`)       |
| `npm run smoke:api` | Boot the API and run one full log-a-day loop       |

---

## Continuous Integration

Every push runs verification pipelines in GitHub Actions, and a local `pre-push`
git hook (husky) runs the fast checks before code leaves your machine.

### Workflows (`.github/workflows/`)

- **CI** (`ci.yml`) — on every push, path-filtered: API (lint · test · boot-smoke), Web (lint · typecheck · `vite build`), iOS SwiftLint (lint-only), and actionlint.
- **Security** (`security.yml`) — gitleaks secret scan, advisory `npm audit`, and `dependency-review` on PRs.
- **CodeQL** (`codeql.yml`) — JS/TS static analysis on PRs to `main` + weekly.
- **Deploy Web** (`deploy-web.yml`) — builds the dashboard to GitHub Pages on push to `main`.

The `pre-push` hook runs lint, format check, typecheck, and API tests; bypass in an emergency with `git push --no-verify`. To make CI **block** merges into `main`, enable required status checks in the repo's branch-protection settings.

---

## License

Copyright 2026 [Sideband](https://sideband.studio). All rights reserved.

This repository is publicly viewable for evaluation purposes. You may clone and run it locally to review functionality. Copying, distributing, modifying, or using this code in any other project without written permission is prohibited.

Contact: [hello@sideband.studio](mailto:hello@sideband.studio)
