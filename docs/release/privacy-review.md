# Privacy publication review

Prepared 2026-10-07 from the app source and API review through 71604c45, and audited
again on 2026-10-20 against every network call, stored datum and HealthKit type (branch
`claude/ready`, from 49c284b1). This is an audit draft, not a submitted App Store
declaration or legal approval.

Apple's [privacy details guidance](https://developer.apple.com/app-store/app-privacy-details/)
distinguishes data retained off device from processing confined to the device.
The declaration must cover the app and its service providers. The account
deletion flow must remain available in the app, as described in Apple's
[account deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion).

## Data map for the native app

| Data                                              | Current path                                                                                                       | Declaration                                                       |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Name and email                                    | Signup, profile, Sign in with Apple; account server. Email also receives password reset codes                      | Name, Email Address: linked; app functionality                    |
| Account and sign-in identifiers                   | Account ID, Apple subject, session and token records on the server; Keychain on device                             | User ID: linked; app functionality                                |
| Food, weight, measurements, sleep, water, targets | Account records and document sync. Includes weigh-ins and body fat imported from Apple Health                      | Health: linked; app functionality                                 |
| Workouts, sets, programs, activities, gyms        | Account records and document sync                                                                                  | Fitness: linked; app functionality                                |
| Notes, foods, recipes, proposals, custom metrics  | Account records and audit history. A recipe imported from a link keeps its source URL                              | Other User Content: linked; app functionality                     |
| Age, sex and time zone                            | Profile and target calculations; every request sends the device time zone (`X-Timezone`)                           | Other Data Types: linked; app functionality                       |
| Food search text and barcodes                     | Sent as typed (debounced) to the API, which asks Open Food Facts; server memory cache of 200 queries for 5 minutes | Search History: not linked; app functionality                     |
| Recipe links                                      | The server fetches the page once to read the recipe; nothing about the fetch is stored                             | Covered by Other User Content (the URL saved with the recipe)     |
| Steps and active energy from Apple Health         | Read and shown on device only                                                                                      | Not collected                                                     |
| Writes to Apple Health                            | Food (29 nutrient types), weigh-ins and body fat, and workouts, each behind its own switch                         | Not collected (stays in Health)                                   |
| Watch heart rate and active energy                | Read during a workout and shown on the watch; the workout is saved to Health                                       | Not collected                                                     |
| Progress photos                                   | Camera or system picker to JPEG files with Complete protection, per account; EXIF dropped; never uploaded          | Not collected                                                     |
| Nutrition label photos                            | Camera or picker to on-device Vision; image kept only in memory                                                    | Not collected                                                     |
| Spotlight, widgets, Live Activity                 | The person's own foods indexed on device; a calorie and workout snapshot in the App Group; workout on Lock Screen  | Not collected (on device)                                         |
| IP addresses and request diagnostics              | Rate limiting in memory; error logs hold method, path and the error; DigitalOcean log retention unverified         | Decide Other Diagnostic Data, not linked, once retention is known |
| TestFlight feedback and crash reports             | Apple's service; no MetricKit or crash SDK                                                                         | Not collected by Exerly                                           |
| Agent-selected data                               | Scoped personal access token or MCP, to the agent the person chooses                                               | User-directed sharing; document scopes and revocation             |

`apps/ios/Exerly/PrivacyInfo.xcprivacy` declares exactly the "Declaration" column:
no tracking, UserDefaults reason CA92.1, and file timestamp reason C617.1 (the
label-photo import reads its size from the copy in the app container). The watch
app is a separate bundle with its own manifest (UserDefaults CA92.1).

### App Store privacy label

| Section                | Category         | Data type                                | Purpose           |
| ---------------------- | ---------------- | ---------------------------------------- | ----------------- |
| Data used to track you | —                | None                                     | —                 |
| Data linked to you     | Contact Info     | Name, Email Address                      | App Functionality |
| Data linked to you     | Health & Fitness | Health, Fitness                          | App Functionality |
| Data linked to you     | User Content     | Other User Content                       | App Functionality |
| Data linked to you     | Identifiers      | User ID                                  | App Functionality |
| Data linked to you     | Other Data       | Other Data Types (age, sex, time zone)   | App Functionality |
| Data not linked to you | Search History   | Search History (food searches, barcodes) | App Functionality |

Add Diagnostics > Other Diagnostic Data (not linked) if production request logs
are retained. Use Product Personalization only if Ali decides suggestions count.

### Findings of the 2026-10-20 audit

Fixed on `claude/ready`:

- The manifest lacked search history, age/sex/time zone and the file timestamp
  reason; the watch app had no manifest. Both added; the release check now
  requires the watch manifest.
- RELEASE.md said the Health screen reads two types and writes none, and that
  crash reports came through MetricKit. Both corrected.
- The camera purpose string didn't mention progress photos. Corrected.
- Open Food Facts requests named the GitHub repository; they now name
  https://sideband.studio and hello@sideband.studio.
- support-draft.md, marked for publication, described the private staging
  server. Removed.
- Account deletion accepted a session alone; it now needs the password or a
  fresh Sign in with Apple, offers an export first and lists the consequences.

Left, with who owns them:

- The watch's save string mentions heart rate, which it doesn't write
  (`project.yml`): the next project-file change.
- Release builds allow HTTP to the staging address and local networking, which
  internal builds need. A public build needs a production Info.plist: the next
  project-file change.
- No privacy-policy link in the app yet: waits on a hosted URL (Ali).
- The legacy web Gemini coach sends profile and body data by default when a
  key is set: Ali decides to disable it or add consent.
- The legacy `POST /api/food/barcode-lookup` route is still compiled into the
  app but unreachable; it can be removed with the old diary code.

## Source checks

- HealthKitService has five switches: read weigh-ins (body mass, body fat;
  imported readings become synced weight entries), read activity (steps,
  active energy; display only), and write food, weigh-ins and workouts. The
  watch reads heart rate and active energy and saves workouts.
- Progress photos come from the camera or the system picker and are stored as
  per-account JPEG files with Complete protection.
- NutritionLabelCaptureView uses native photo selection and on-device Vision.
  NutritionLabelScanner discards cancelled and replaced results. Image bytes stay
  in memory and never enter Food, sync payloads or account exports. Saved reviewed
  nutrients become ordinary custom foods. A10 does not yet include this flow.
- Native searches look up generic foods in the server's bundled USDA table and
  call Open Food Facts for packaged products. Attribution remains visible. The
  USDA lookup itself makes no provider request, but the search endpoint still
  calls Open Food Facts for the same query.
- Account deletion removes owned rows and identities. Apple token revocation
  needs the separate configured Sign in with Apple key described in
  QUESTIONS_FOR_ALI.md. A passing simulated authorization test does not prove
  that production revocation is configured.
- Open Food Facts search keeps up to 200 queries and their results in server
  memory. Results can be reused for five minutes. Entries are not linked to
  accounts or stored in the database; replacement and restart remove them.
  Native barcode requests do not use the legacy product cache. Request budgets
  keep minute counts and drop them after a day. The separate
  legacy web barcode route caches products by barcode for seven days, and may
  serve a stale product up to 30 days old after a provider failure. It does not
  associate the cache with a person. FatSecret is limited to that legacy route
  when its keys are configured.
- API error logs contain the request method, path without its query string and
  error. Rate limiting holds IP addresses in memory during its window.
  DigitalOcean request logging and retention remain unverified.
- The legacy web Gemini coach sends messages and context to Google when its key
  is configured. Its ai_errors rows include email, user ID, IP address and user
  agent. Account deletion removes these rows; account export omits them. This
  route is unreachable from the current native shell. Disclose the separate web
  behavior or disable that route before publication, as tracked for Ali.
- User-configured webhooks send a sequence number and signature, not records.
  The receiver needs its own token to read changes. Account deletion removes
  webhook configuration and secrets; exports omit webhook secrets.
- Production still runs the legacy Mongo API. This review describes the new
  staging API; final hosting, database and backup declarations require cutover.
- No advertising, analytics or crash SDK is added by this release.

## Decisions required before publishing

Ali reviews the notice and legal declarations. Logic confirms the deployed data
flows and operational settings. Resolve these concrete items:

1. Production operator details, supported age range and privacy contact wording.
2. Production hosting providers, locations, database encryption, log retention,
   backup retention and deletion from backups. Do not invent retention periods.
3. Applicable rights, request verification and any legally required retention.
4. Sign in with Apple revocation key and physical authorization/deletion proof.
5. Final App Store categories for profile fields, food-provider requests and diagnostics,
   and whether recommendations require the product-personalization purpose.
6. Public HTTPS policy and support URLs under Sideband. The drafts are local;
   no website or App Store declaration has been changed.

The internal staging build is restricted to the private tailnet and synthetic
data. It does not establish production TLS, database or backup readiness.
