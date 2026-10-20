# Exerly release readiness

Updated 2026-10-20. Internal TestFlight is authorized. External TestFlight and App
Review require Ali's decision after the build and review material are ready.

## Current build

This section records A13, the last build documented here; later internal builds
are listed in docs/ledger/claude.md.

Beginner milestone A13, version 1.0 build 2610072129, is available in
internal TestFlight. Apple reports VALID and IN_BETA_TESTING. The Ali-only
group contains one tester and exactly this build, with English notes verified
at 18:25 EDT on 2026-10-07. The phone needs Tailscale for devbox1 staging and
the existing internal account.

The diary offers Scan first, Search second and manual entry under More.
The eight-question setup explains and saves training experience, frequency,
measurements and nutrition preferences. Build my workout plan uses those
answers and available equipment to create a Core-generated proposal. Review
each day before saving, keep an existing program, and undo the new plan even
after an offline relaunch. U.S. units remain the default. A13 also includes
A12's multi-food meal builder and A11's nutrition-label recognition.

Core 308, API 261, all 197 active hosted tests and the device build pass.
The fixed full UI gate covers all 59 declared methods exactly once, with
50 passes and nine context-specific skips. Its manifest is
artifacts/nutrition/a13-verified-manifest.json in the release worktree.
Native Health authorization and the seeded label-photo test pass. Setup and
plan journeys also pass in default light/dark and largest text. Default
primary and empty screens were captured and reviewed in light and dark.
All selected A13 release captures were inspected. Public comparisons are
artifacts/design/contact-review/a13-barcode-reference.png and
a13-workout-reference.png in the primary tree.

The gallery is http://100.80.149.7:39215. Physical installation, camera capture,
Apple sign-in, Health authorization, VoiceOver and measured phone performance
remain unverified. Full feature parity is open. Gym inventory is in progress
for the next release and is not in A13.

Signed archive and exported IPA checks passed identity, entitlements, profile,
privacy manifest, icon, version, staging endpoint and absence of debug hooks.

- Release worktree: `/Users/aldo/Desktop/Exerly-Fitness-app-programs`.
- Archive: `apps/ios/build/release/2610072129/Exerly.xcarchive`.
- IPA: `apps/ios/build/release/2610072129/export/Exerly.ipa`.
- Archive/export/upload logs: `apps/ios/build/release/2610072129/{archive,export,upload}.log`.
- Build and delivery UUID: `cb866d14-31e9-44c2-91f6-94547943bf0c`.
- Fixed source tag: `ios/internal-2610072129`, commit `208ed075`.
- Bundle: `com.exerly.fitness`, Apple bundle resource `UJ5X8TJKNL`.
- Team: `9X79V37Q89`. Distribution certificate expires 2027-09-25.
- Exerly profile: `J5J395Y9AF`, HealthKit and Apple sign-in, same expiry.
- App Store Connect: Exerly, app ID `6819776832`.
- Internal group: `Exerly Internal · Ali`, `c5ae1d39-0fe4-4bee-af89-0374d9519afe`.
  Only Ali, no public link or automatic future builds.
- Availability evidence: `artifacts/nutrition/a13-internal-2610072129.json`.
- Exact test notes: `docs/release/a13-internal-notes.txt`.

A12 build 2610072011 was detached only after A13 became available. The source
tag is pushed. No other app's identifiers or profiles changed. Credentials
stay outside the repository.

## Repeatable commands

From the repository root:

```sh
python3 -m unittest discover -s apps/ios/scripts/tests
node --test apps/ios/scripts/tests/asc.test.mjs
node apps/ios/scripts/asc.mjs provision
bash apps/ios/scripts/release.sh --dry-run
bash apps/ios/scripts/release.sh --archive
bash apps/ios/scripts/release.sh --upload
node apps/ios/scripts/asc.mjs status
node apps/ios/scripts/asc.mjs internal BUILD_NUMBER
```

Use a new UTC timestamp for each archive. `BUILD` can override the default
`yymmddHHMM`. The script refuses to overwrite an archive. Internal builds default to staging
(http://100.80.149.7:39110). EXERLY_RELEASE_ENVIRONMENT=production chooses public
HTTPS only after its API supports the native session protocol. Staging validation
allows only the exact authorized address and explicit staging metadata. Signed modes use a
temporary keychain, restore the prior keychain list and remove only the profile
they installed. `--archive` produces a signed IPA without an upload. `--upload`
exports for internal testing only, checks that the app record exists, then uploads.
Run `internal BUILD_NUMBER` only after Apple reports the build as valid. It checks
that the existing tester is Ali and internal, and that the group has no public
link, no other members and no automatic access to future builds.

The [initial app record][apps] and Ali's membership in the internal group were
created through Apple's website. API checks verify the group and account-holder
email before assigning a build. Apple's [inviteType][invite] describes email
versus a public link; internal status comes from the group's isInternalGroup.
Manual profile selection is scoped to the app target so Swift package resource
bundles are not given an unsupported provisioning profile.

## App Store checklist

Audited item by item on 2026-10-20 (branch `claude/ready`). "Ali" marks what only
Ali can do; everything else is the builder's.

| Item                              | State                       | Acceptance and what's left                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Bundle registration               | Done                        | Only com.exerly.fitness and its watch and widget bundles; HealthKit and Apple sign-in enabled.                                                                                                                                                                                                                                                                                 |
| App Group                         | Ali                         | Register `group.com.exerly.fitness` in the developer portal (QUESTIONS_FOR_ALI.md, 2026-10-10). Widgets and complications wait on it; release builds sign without it.                                                                                                                                                                                                          |
| Distribution signing              | Done                        | Existing certificate reused; signed archive and export verified.                                                                                                                                                                                                                                                                                                               |
| App icon                          | Built                       | Established purple E/pulse mark, opaque 1024px.                                                                                                                                                                                                                                                                                                                                |
| App Store Connect record          | Done                        | Exerly, app ID 6819776832.                                                                                                                                                                                                                                                                                                                                                     |
| Internal group                    | Done                        | Exerly Internal · Ali; only Ali, no public link, explicit builds.                                                                                                                                                                                                                                                                                                              |
| Internal TestFlight upload        | Available internally        | Latest builds are listed in docs/ledger/claude.md. Internal builds point at devbox1 staging.                                                                                                                                                                                                                                                                                   |
| Feature parity                    | Open                        | Every PARITY.md row needs device evidence.                                                                                                                                                                                                                                                                                                                                     |
| Beyond                            | Open                        | Ship and measure B01-B12; no unproven superiority claims.                                                                                                                                                                                                                                                                                                                      |
| Native test suite                 | In progress                 | API, Core, hosted and UI suites pass per landing (counts in the ledger). Two consecutive clean full audits are still owed.                                                                                                                                                                                                                                                     |
| Light/dark and Dynamic Type       | Open                        | Inspect all major flows at largest text on small and large phones. Account deletion and password reset were checked on the iPhone SE on 2026-10-20.                                                                                                                                                                                                                            |
| VoiceOver/contrast/reduced motion | Open                        | Device audit, accessible form errors and charts, no clipped controls.                                                                                                                                                                                                                                                                                                          |
| Performance                       | Open                        | Cold-launch measurements and 60 fps scrolling traces on a physical phone.                                                                                                                                                                                                                                                                                                      |
| Offline and conflict behavior     | Partial                     | Queue tests pass; each new domain needs equivalent device journeys.                                                                                                                                                                                                                                                                                                            |
| Sign in with Apple                | Built; Ali                  | Native nonce/state/token flow and tests pass. Left: one physical authorization on Ali's phone.                                                                                                                                                                                                                                                                                 |
| Password recovery                 | Built; Ali                  | Mailed code, hashed, single-use, 15 minutes, no enumeration, rate limited; a reset ends every session and token. Left (Ali): choose an email provider and verify sideband.studio for sending (QUESTIONS_FOR_ALI.md, 2026-10-20).                                                                                                                                               |
| Account deletion                  | Built; Ali                  | Needs the password or a fresh Sign in with Apple, which the API verifies; offers an export first; lists what's removed and kept; ends every session and token. Left (Ali): the Sign in with Apple key in DigitalOcean for revocation, and a physical Apple deletion.                                                                                                           |
| Session security                  | Built                       | Short access tokens, rotating refresh credentials with reuse detection, server-side sign-out, revocation on password change and reset.                                                                                                                                                                                                                                         |
| Export/import                     | Partial                     | Full-fidelity export/import with user review and synthetic round-trip fixtures (imports slice).                                                                                                                                                                                                                                                                                |
| Production database               | Blocked on deployment (Ali) | Ali supplies Neon/DO secrets. The API deploys only from a merge to main.                                                                                                                                                                                                                                                                                                       |
| Privacy manifest                  | Built                       | Matches the 2026-10-20 audit (docs/release/privacy-review.md): name, email, user ID, health, fitness, other user content and other data (age, sex, time zone) linked; search history not linked; all app functionality; no tracking. UserDefaults CA92.1 and file timestamp C617.1. The watch app has its own manifest (UserDefaults CA92.1), checked by release_checks.py.    |
| Privacy labels                    | Draft; Ali                  | The label table in privacy-review.md matches the manifest. Left (Ali): enter it in App Store Connect and decide the open categories listed there.                                                                                                                                                                                                                              |
| Privacy policy                    | Draft; Ali                  | privacy-policy-draft.md describes current behavior. Left (Ali): legal review, retention and provider details, and a hosted URL on sideband.studio. The app links to it once the URL exists (Guideline 5.1.1(i)).                                                                                                                                                               |
| HealthKit purpose strings         | Built; physical check left  | The phone reads weight, body fat, steps and active energy and writes food (29 nutrient types), weigh-ins and workouts, each behind its own switch; the watch reads heart rate and active energy and saves workouts. The watch's save string mentions heart rate, which it doesn't write: fix in project.yml with the next project-file change. Physical authorization remains. |
| Camera and photo purpose strings  | Built                       | Camera covers barcodes, labels and progress photos. Photos use the system picker.                                                                                                                                                                                                                                                                                              |
| Transport security                | Open                        | Release Info.plist still allows HTTP to the devbox1 staging address and local networking, which internal builds need. A public build must drop them; that needs a separate production Info.plist or build setting (project-file change).                                                                                                                                       |
| Cloud inference consent           | Open; Ali                   | The native app sends nothing to an AI service. The legacy web coach sends name, age, sex, height, weight and targets to Google Gemini when a key is set, without opt-in. Ali decides: disable that route or add consent.                                                                                                                                                       |
| Encryption/export compliance      | Draft; Ali                  | Platform TLS and Keychain only; Info declares no non-exempt encryption. Ali reviews the legal declaration.                                                                                                                                                                                                                                                                     |
| Age rating                        | Open; Ali                   | Complete the questionnaire from shipped features; no medications or medical claims.                                                                                                                                                                                                                                                                                            |
| Name/subtitle/description         | Draft                       | Verify lengths, actual functionality and name availability in ASC.                                                                                                                                                                                                                                                                                                             |
| Keywords/category/copyright       | Draft                       | Health & Fitness, © Sideband, accurate search terms.                                                                                                                                                                                                                                                                                                                           |
| Screenshots                       | Open                        | Synthetic data only, final UI, all required device sizes.                                                                                                                                                                                                                                                                                                                      |
| Support URL                       | Draft; Ali                  | docs/release/support-draft.md covers sign-in, recovery, Health, export and deletion, with no internal details. Left (Ali): publish it on sideband.studio.                                                                                                                                                                                                                      |
| Review notes/test account         | Draft; Ali                  | Notes below. Left (Ali): a synthetic review account whose credentials stay outside the repo, entered in ASC.                                                                                                                                                                                                                                                                   |
| Crash diagnostics                 | Built                       | No MetricKit and no third-party SDK; crash reports come only from TestFlight and the App Store through Apple.                                                                                                                                                                                                                                                                  |
| Public contact                    | Done                        | hello@sideband.studio and https://sideband.studio in the app, API mail and provider User-Agents; no personal or university address in public material.                                                                                                                                                                                                                         |
| Two consecutive full audits       | Open                        | Zero completed clean audits.                                                                                                                                                                                                                                                                                                                                                   |
| External review / App Review      | Not authorized; Ali         | Prepare all material, then ask Ali.                                                                                                                                                                                                                                                                                                                                            |

### Draft App Review notes

> Exerly logs training and nutrition. Sign in with the review account in these
> notes, or create an account with email or Sign in with Apple. Apple Health is
> optional: Profile > Apple Health has a switch for each type it reads (weight,
> body fat, steps, active energy) or writes (food, weigh-ins, workouts). Logging
> works offline and syncs later. To delete the account: Profile > Account >
> Delete account. Exerly offers an export first, lists what is removed, and asks
> for the password (or Sign in with Apple) before deleting. Forgot password on
> the sign-in screen emails a one-time code. Exerly has no ads, tracking or
> third-party analytics.

## Draft metadata

- Preferred name: Exerly.
- Fallback name: Exerly Training & Nutrition.
- Subtitle: Training, food and evidence.
- Primary locale: English US.
- SKU: sideband-exerly-ios.
- Primary category: Health & Fitness.
- Copyright: © Sideband.
- Support/contact: hello@sideband.studio, https://sideband.studio.
- Candidate keywords: workout,training,nutrition,macros,food,weight,strength,sets,reps,progress.

Draft description for the finished product, not the current build:

> Log training and food in one place. Record sets, meals and body measurements,
> review your progress, and keep logging when you are offline. Exerly shows the
> records behind its calculations. Agent suggestions arrive as changes you can
> review, accept or undo. Export your data or connect your own agent through scoped
> access. AI is optional.

Replace this draft with the capabilities actually verified at submission. Do not
claim full parity, superior food coverage or sub-second launch until measured.

## Internal test notes for the program build

Enable Tailscale before signing in to staging. Use synthetic data. Build a small
program, review the next workout, finish it, and check the following planned day.
Try duplicate/archive/restore and review a program proposal before deciding.
Log a barcode food to Dinner, scroll the detail screen, then edit its amount
offline and relaunch. Profile > Sync backs up account records. Physical Apple
sign-in/linking and deletion reauthorization still need testing. Report crashes
through TestFlight. The A7 replacement nutrition diary is not in this build.

[apps]: https://developer.apple.com/documentation/appstoreconnectapi/apps
[invite]: https://developer.apple.com/documentation/appstoreconnectapi/betatester/attributes-data.dictionary

## Test account and release smoke

Credentials are kept outside the repository in ~/private_keys/exerly-testflight-account.json.
The account contains synthetic onboarding only. Set TEST_RUNNER_EXERLY_ACCOUNT_SMOKE_PATH
to that file for AccountInfrastructureTests/testInternalTestAccountCompletesNativeSignInAndBootstrap.
This tests the app target’s compiled endpoint, Keychain session persistence, login and
bootstrap; it caught the difference from the stale production API. Hosted Core Keychain
replacement/isolation/accessibility/removal also passes. Neither test prints credentials.

## Prepared support and privacy material

[Support instructions](release/support-draft.md), [privacy notice](release/privacy-policy-draft.md)
and the [data-flow/publication review](release/privacy-review.md) are drafted for
Ali and Logic to review. They describe the current native routes, separate
local Health/photo use from account sync, and identify the production retention
and provider decisions still needed. Nothing has been published or submitted.

The full design pass is shipped internally as2610071054. Keep physical-device
checks and the broader parity backlog open. Resume nutrition from the ledger.
