# Questions for Ali

These questions do not block local implementation.

- Create the Supabase project when ready and set the production `DATABASE_URL` in
  DigitalOcean. The PostgreSQL change will be tested locally first. Do not post
  credentials in this file or chat.
- Before public release, review the privacy policy, terms and App Store legal
  declarations. Drafts and the release checklist will be prepared here.
- External TestFlight and App Review require your decision after the build,
  screenshots and review notes are ready. Internal TestFlight is already authorized.

The current license and repository visibility remain unchanged.

## 2026-10-06 (logic agent): a Sign in with Apple key for token revocation

App Store Review Guideline 5.1.1(v) requires apps with Sign in with Apple to
revoke Apple's tokens when someone deletes their account. The API does this
already, but only once it has a Sign in with Apple private key. The App Store
Connect API key in `~/private_keys` is a different kind of key and can't be used.
Until then, deleting an Apple-linked account removes all data but skips
revocation.

When you're ready:

1. In Certificates, Identifiers & Profiles, under Keys, create a key with Sign in
   with Apple enabled for `com.exerly.fitness`, on team 9X79V37Q89.
2. In DigitalOcean, set these secrets: `APPLE_TEAM_ID`, `APPLE_KEY_ID`, and
   `APPLE_PRIVATE_KEY` (the `.p8` contents; `\n` escapes are fine).

Don't paste the key in this file or in chat.

## 2026-10-06: First App Store Connect record

Open. Exerly's bundle ID com.exerly.fitness is registered with HealthKit on team
9X79V37Q89. The existing distribution certificate was reused. Apple does not expose
app-record creation through its REST API, and the available browser is signed out.
Create the record at https://appstoreconnect.apple.com/apps with iOS, English US,
name Exerly, and SKU sideband-exerly-ios. If the name is taken, use Exerly Training
& Nutrition. Reply with the chosen name or app ID. No secrets are needed.

This blocks upload only. The app agent continues signed archives, simulator checks
and implementation. Internal TestFlight is already authorized; no extra release
approval is requested. Apple's restriction is documented at
https://developer.apple.com/documentation/appstoreconnectapi/apps.

## 2026-10-06: App Store Connect creation resolved

The app agent unlocked the authorized desktop session and created Exerly through
Apple's website. App ID 6819776832; iOS, English (US), com.exerly.fitness, SKU
sideband-exerly-ios. The earlier website-creation blocker is resolved. Internal
TestFlight preparation continues; no external review or App Review was submitted.

## 2026-10-06 (logic agent): a USDA FoodData Central API key, for food search

**Update 2026-10-07: no longer needed for generic foods.** Search now includes
5,431 generic foods from USDA's public-domain FNDDS table, bundled with the
API (design 023). A key would only add USDA's live search on top. You can
skip it.

Food search for M5d will use Open Food Facts (no key, ODbL with attribution),
which the server already uses, and USDA FoodData Central (public domain).
FoodData Central's search API needs a free api.data.gov key, and signing up is
a new account, so it's your call. Without one, search uses Open Food Facts only:
good for packaged foods, thinner for generic foods such as "chicken breast,
cooked".

If you want it:

1. Sign up at https://fdc.nal.usda.gov/api-key-signup with an address you
   choose. The key is free; its default limit is 1,000 requests an hour.
2. In DigitalOcean, set the secret `USDA_FDC_API_KEY`. For staging on devbox1,
   add a line `USDA_FDC_API_KEY=...` to `~/Services/exerly-staging/staging.env`,
   which redeploys keep, and tell me so I can restart it.

Don't paste the key in this file or in chat.

## 2026-10-06 (logic agent): MacroFactor's export headers, for the import

The MacroFactor import (M5e, PARITY I12) has to match MacroFactor's sheet and
column names exactly, and its help centre doesn't list them. Tests must use
synthetic data, so I need only the structure of a real export, never its
values.

If you're willing:

1. In MacroFactor, make a granular export with every option selected.
2. Save the file outside the repo, at `~/Private/macrofactor-export/` on
   devbox1, and tell me.

I'll read only sheet names, column headers and unit labels. From those I'll
write a synthetic export, with made-up numbers, as the test fixture. Your file
and its values never enter the repo, logs or chat, and you can delete it once
the fixture exists. Until then the importer waits; nothing else is blocked.

## 2026-10-06 (logic agent): production after the merge into main

Done at your request: integration was merged into `main` (`fc016093`). Each
push to `main` redeploys the API on DigitalOcean, but production still answers
with the old MongoDB API (version 1.0.0). So either the new deployment is
failing for want of `DATABASE_URL`, which keeps the old one serving, or it
didn't run.

Meanwhile Deploy Web has published the new web app, which signs in through
the new API's routes. The old API answers 404 to them, so **web sign-in
doesn't work** until the new API is live. The landing pages are fine.

When you're ready:

1. Create the Supabase database and set `DATABASE_URL` in DigitalOcean (also
   `JWT_SECRET`, if it isn't set). Then redeploy from `main`, or tell me and I'll
   push the next merge.
2. I'll check that `/api/health` reports version 2.0.0 with PostgreSQL.

If you'd rather put the old web app back until then, say so and I'll redeploy
it from the previous `main` commit.

## 2026-10-07 (logic agent): the legacy AI coach and the privacy notice

The web app's AI Coach (`apps/web/src/components/AICoach`) calls the API's
`/api/ai` routes. When `GEMINI_API_KEY` is set, they send the person's
messages and context to Google's Gemini. Their error log keeps the email,
user ID, IP address and user agent with each failure. The iPhone app doesn't
reach these routes. The draft privacy notice (in the app agent's
`docs/release`) says the main screens don't need a hosted model, which is
true for the phone but not for this web screen.

Choose one:

1. **Keep it.** The notice discloses Google as a processor for the web coach.
   It stays off unless `GEMINI_API_KEY` is set.
2. **Retire it.** I remove the routes and the error log, and the web coach
   goes.

Until you choose, nothing changes. Production doesn't run the new API yet.

## 2026-10-10 (Claude): one portal step for Home Screen widgets

The Today and Next workout widgets need an App Group so they can read what the
app writes. Apple's App Store Connect API can't create App Groups, so this one
step needs you in the developer portal (Account Holder or Admin), about a minute:

1. Certificates, Identifiers & Profiles → Identifiers → + → App Groups.
2. Description "Exerly", identifier `group.com.exerly.fitness` → Register.

That's all. I'll enable the capability on `com.exerly.fitness` and the widgets
extension, and regenerate the App Store profiles, through the API. Nothing is
blocked meanwhile: the workout Live Activity and Dynamic Island don't need it,
and the widgets ship once the group exists.

## 2026-10-12 (Claude): PR #56 needs your review to reach `main`

On 2026-10-11 you added `.github/CODEOWNERS` ("the maintainer reviews every
file") and a ruleset requiring a pull request for `main`. GitHub now marks my PRs
"review required", so `main` takes nothing from me without your approval, and
the brief's daily merge is no longer something I can do on my own.

Body tracking, diary depth and two bug fixes are in PR #56
(https://github.com/sidebandstudio/Exerly-Fitness/pull/56); its checks run
there. Merging deploys the API changes those features need, so the matching
TestFlight build waits for it. Which do you want from now on?

1. **You review and merge each PR.** I open one per landing and upload to
   TestFlight after you merge.
2. **Let me merge once checks pass.** Allow it in the ruleset (or add me as a
   bypass actor), and I'll merge my own PRs as the brief describes.

## 2026-10-20 (Claude): an email provider for password reset codes

Forgot password is built: the API mails a short code and the app asks for it.
The API has never sent email, so in production nothing goes out yet. Requests
answer normally and the server logs that no mail was sent. Sending needs an
account with a transactional email provider, which is your call (money and a
new account). I haven't signed up for anything.

What it needs from you: pick a provider (Postmark, Resend, or SMTP
from the mail host behind sideband.studio), verify `sideband.studio` as a
sending domain with its SPF/DKIM DNS records, and put the API key in
DigitalOcean. Mail comes from `Exerly <hello@sideband.studio>` unless you set
`MAIL_FROM`. Tell me which provider, and I'll add its transport to
`apps/api/lib/mail.js` with tests.
