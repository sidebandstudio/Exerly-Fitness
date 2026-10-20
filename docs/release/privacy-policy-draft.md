# Exerly privacy notice

Draft for Ali's review, 2026-10-07, updated 2026-10-20. Not published. Resolve the decisions in
[privacy review](privacy-review.md) before using this as a public policy.

Exerly is a training and nutrition app from Sideband. Contact
hello@sideband.studio with questions about your data.

## Your account and records

Exerly stores the information you provide to run your account: your name, email,
sign-in method and profile preferences, including age, sex and time zone for
your targets. If you use Sign in with Apple, Apple may provide a private relay
email address. Passwords are stored as hashes. If you forget your password,
Exerly emails a one-time code to your account's address; only a keyed hash of
the code is kept, and it stops working after 15 minutes.

Your food logs, body measurements, activity, sleep, workouts, programs, goals,
notes and agent proposals can sync to your Exerly account. Saved copies let
you use supported logging features offline. Exerly uses these records to show
your history, calculate training and nutrition information, and carry out
changes you request. Some records include an edit or decision history.

## Apple Health and photos

Apple Health access is optional, and each kind has its own switch in Profile,
Apple Health:

- Reading weigh-ins and body fat adds your scale's readings to your Exerly
  weight log, which syncs to your account like a weigh-in you type.
- Reading steps and active Calories shows today's activity. Those readings stay
  on your device.
- Saving food, weigh-ins and workouts writes them to Apple Health, and updates
  or removes them when you edit or delete them in Exerly.

On Apple Watch, Exerly reads heart rate and active Calories during a workout to
show them on the watch, and saves the workout to Apple Health. They aren't sent
to your Exerly account. Exerly never uses Health data for advertising. Manage
Apple's permissions in the Health app.

Progress photos you take with the camera or choose in Exerly are stored in the
app on your device, without their location data. Exerly does not upload them.
Device backups and copies you share are controlled by your device settings and
the services you choose. Account exports do not include these photos.

Nutrition label photos are read on your device. The image remains in memory
while you review the draft and is discarded when you close it. Exerly does not
upload or export the label photo. Food names, serving weights and nutrient values
you choose to save become ordinary custom foods and can sync to your account.
Camera access is requested only when you choose to take a photo.

## Food search and connected agents

Food searches use a USDA food table held by Exerly and request packaged foods
from Open Food Facts. Barcode lookups also use Open Food Facts. That provider
receives the search text or barcode, not your Exerly food diary. A USDA result
does not mean the same search was kept from Open Food Facts.

Exerly keeps up to 200 Open Food Facts search texts and their results in server
memory, reusing them for five minutes. They are not linked to an account or
written to the database. New searches can replace them, and restarting the
service clears them. Request limits separately count requests without saving
search text. The provider's own retention policies apply. Avoid including
personal information in a food search.

When you import a recipe from a link, Exerly's server fetches that page once to
read the recipe. The link is saved with the recipe; the page is not kept.

Exerly adds the foods and recipes you saved to your iPhone's own search
(Spotlight) and shows your day and workout in widgets and on the Lock Screen.
These stay on your device and are removed when you sign out.

Connecting an agent is optional. An agent can access only the permissions you
grant to its token. Proposed changes wait for your review; direct write access
requires a separate choice. Revoke a token in Profile, Connected agents. The
agent or service you connect may retain information it already received under
its own policies. Revoking access prevents future access with that token.

Manual logging works without an AI service. This native build does not require
sending your logs to a hosted model to use its main screens.

The separate legacy web coach, when enabled, sends your messages to Google
Gemini with context from your profile: name, age, sex, height, weight, goal,
training experience and targets. Its error records can include your account ID, email,
IP address and browser details. Account deletion removes those error records;
the current export does not include them. Before publishing this notice,
confirm whether that web route will remain enabled.

If you configure a webhook, Exerly sends the receiver a change notification and
signature. The receiver needs an authorized token to read the records.

## Your choices

Use Profile, Account settings, Export data to save an account export.
An offline device export contains the records available on that device. Files
you export or share become your responsibility to store securely.

You can delete your account in Profile, Account settings, Delete account. The
app offers an export first, explains what is removed, and asks for your password
or Sign in with Apple. Deletion signs out every device and ends access for
agents you connected. Deletion removes the
account's records from the active service and starts cleanup on this device.
Keep the app installed if it asks to retry local cleanup. Other devices may
retain offline copies until they reconnect. Deleting Exerly does not delete
records from Apple Health or copies held by services you connected.

Exerly's current app has no advertising SDK or third-party analytics SDK and
does not track you across other companies' apps or websites. During TestFlight,
Apple handles beta feedback and crash reports through its testing service.

The published notice will identify the production hosting providers, retention
periods, backup deletion schedule, applicable privacy rights and effective date
after those operational and legal decisions are confirmed.
