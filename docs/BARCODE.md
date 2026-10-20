# Barcode scanning

Scan barcode, from Today's Scan button or food search. Decision record:
`docs/DECISIONS.md`, 2026-10-20.

## How a scan works

1. **Frames.** `BarcodeCamera` (`apps/ios/Exerly/Features/Nutrition/NutritionBarcodeCamera.swift`)
   runs an `AVCaptureSession` on the triple, dual-wide or wide camera at 1080p, with
   continuous near-range autofocus. It zooms so a 20 mm code fills the frame at the wide
   lens's closest focus, as Apple's barcode sample does (`ScannerOptics.zoomFactor`), and
   stays short of the telephoto lens so the macro switch still happens. Pinch zooms; a tap
   focuses and meters there.
2. **Decode.** Every frame goes to `BarcodeDecoder` (ExerlyCore), which runs Vision's
   `VNDetectBarcodesRequest` in the viewfinder window plus a margin
   (`ScannerOptics.visionRegion`). Symbologies: EAN-13, UPC-A (reported as EAN-13),
   EAN-8, UPC-E, ITF-14 (and Interleaved 2 of 5 at 14 digits), GS1-128, GS1 DataBar,
   DataBar Stacked, DataBar Limited, DataBar Expanded, QR and Micro QR (GS1 Digital Link
   and element strings), and GS1 DataMatrix.
3. **Refuse misreads.** `BarcodePayload.read` turns each payload into a `GTIN`, refusing a
   wrong check digit or length. `BarcodeConsensus` accepts a code only after two agreeing
   reads within 1.2 s. An accepted code is held while it stays in view, and a pack shown
   again after a second out of view counts again.
4. **Resolve.** `BarcodeLibrary` (ExerlyCore) answers from this account's cache, then asks
   the server for the canonical GTIN-14. Offline and never seen, the scan is saved and
   resolves after the next sync or when the scanner opens.
5. **Plate.** A found food joins the plate at the amount it's usually logged at. The same
   food again adds one more serving; a pack still in view when the camera resumes, after
   the portion sheet, isn't added again until it has left the frame. While a scan is
   still being looked up, Log waits for it ("Finding 1 more food…"). Each row has − and + for one serving, a tap for any
   amount, and ×. One button logs the plate to the chosen meal. A success haptic and a
   VoiceOver announcement ("Found Synthetic oat bar. 2 foods to log.") mark each scan; a
   warning haptic marks a miss.
6. **Light.** The frame's EXIF brightness feeds `LowLightAdvisor`. After 1.2 s too dark to
   read bars, the status line becomes "Too dark to read. Turn on the light".

## One key for every form of a code

`GTIN` (`ExerlyCore/Sources/ExerlyCore/Barcodes.swift`) stores 14 digits. UPC-A
`036000291452`, EAN-13 `0036000291452`, GTIN-14 `00036000291452`, and the same typed
without its leading zero all share one key. UPC-E expands to UPC-A by GS1's
zero-suppression rules before keying. The server's `normalizeBarcode` gives the same key
and Open Food Facts code for the same inputs (`keysMatchTheServer`).

Prefixes that aren't products are recognised and never looked up:

| GTIN-13 prefix | Meaning | What the scanner says |
| --- | --- | --- |
| 020–029, 200–299 | In-store weighed or priced label (item + price or weight) | "This is a store's own label" |
| 040–049, and EAN-8s starting 0 or 2 | A store's own number (restricted circulation) | "This code only works in its store" |
| 050–059, 980–984, 990–999 | Coupon or refund receipt | "This is a coupon" |
| 977–979 | ISSN, ISBN, ISMN | "This is a book or magazine" |
| GTIN-14 indicator 9 | Variable-measure trade item | "This is a store's own label" |

GS1 reserves EAN-8s starting 0 or 2 for numbers a company issues for itself, so two
retailers can use one for different foods: they're never looked up, and a cached product
never answers them. A food the person enters for such a code answers it on their account
(`BarcodeLibrary.Product.own`). Typed digits may drop leading zeros; eight digits are tried
as EAN-8 and UPC-E, a product reading first.

## Never a dead end

A miss shows the code with **Search by name**, **Enter it** (the food editor, carrying the
code) and **Read label**. A food entered for a missed code, or a store's own code, is
remembered for that code on this account, so the next scan finds it, offline too.

Offline, a new code shows "Saved for when you're online" with the code. Each such scan is
kept apart from the history (`BarcodeLibrary.Pending`) with its own meal, day and time, so
scanning the same bar for Lunch and again for Dinner keeps both. Once online, each comes
back as "Ready to log" to where it was scanned for. With foods on the plate, a past scan's
button reads "Add to plate" and joins them instead of logging alone.

Open Food Facts's ODbL attribution is shown under the plate, Recent scans and the history,
wherever its foods appear.

Hooks for the next wave: `BarcodeScanSession.Notice.missing(GTIN)` carries the code for
label OCR on a miss and for contributing a food; `BarcodeLibrary.remember` is where a
contributed food would be cached.

## Benchmark

`ExerlyCore/Tests/ExerlyCoreTests/BarcodeBenchmarkTests.swift`, run by `swift test`. It
draws synthetic codes on a grey pack, applies one condition, and reads two jittered
frames through `BarcodeDecoder` and `BarcodeConsensus`, the camera's own path. EAN, UPC,
ITF-14, GS1-128, DataBar, DataBar Stacked and Digital Link QR are drawn by
`BarcodeEncoder` and `SyntheticBarcode` (ExerlyCore), whose DataBar widths match the
bwip-js reference encoder. DataBar Limited, DataBar Expanded, GS1 DataMatrix and Micro QR
come from `BarcodeFixtures`, rendered once by bwip-js (MIT) for synthetic GTINs under GS1's
demonstration prefix 950.

It runs on the Mac because the iOS simulator can't run Vision's current barcode revision
("Could not create inference context"). The Mac runs the same decoder at the revision a
phone uses, and the benchmark skips itself where only revision 1 is available. In the
simulator, the decoder falls back to revision 1 so the UI tests still go through Vision.

Conditions: **rotated** 35°; **perspective**, the pack turned about 40°; **curved**
round a can five times the label's width (a 37 mm EAN-13 on a 60 mm can); **blurred**, half
a module of Gaussian defocus; **low contrast**, black at 45% and white at 72%; **low
light**, white at 20% with σ 3.5% sensor noise; **small**, 40% scale (1.6 px a module);
**damaged**, a smudge over part of the bars and a scratch across them. Labels are framed
to at most 85% of a 960 × 720 frame at about 4 px a module; every frame also has σ 1%
noise and a ±2° hand tremble.

Results on devbox1 (M1 Max, macOS, Vision's current revision), 2026-10-20: hit rate by
symbology and condition, where a hit is the right GTIN accepted from two frames.

| Symbology | n | clean | rotated | perspective | curved | blurred | low contrast | low light | small | damaged |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| EAN-13 | 10 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| UPC-A | 10 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| EAN-8 | 10 | 100% | 60% | 100% | 100% | 100% | 100% | 100% | 0% | 100% |
| UPC-E | 10 | 100% | 100% | 100% | 100% | 90% | 100% | 100% | 0% | 100% |
| ITF-14 | 10 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| GS1-128 | 10 | 100% | 100% | 100% | 100% | 100% | 100% | 60% | 100% | 100% |
| GS1 DataBar | 10 | 80% | 100% | 80% | 90% | 30% | 80% | 0% | 40% | 80% |
| GS1 DataBar Stacked | 10 | 70% | 70% | 50% | 70% | 20% | 80% | 0% | 10% | 70% |
| GS1 Digital Link QR | 10 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 20% |
| GS1 DataBar Expanded | 6 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| GS1 DataBar Limited | 6 | 100% | 100% | 0% | 100% | 67% | 100% | 0% | 0% | 100% |
| GS1 DataMatrix | 6 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Micro QR | 6 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 50% |
| All | 114 | 96% | 94% | 89% | 96% | 84% | 96% | 74% | 64% | 86% |

**Wrong reads accepted: 0.** Single frames with a wrong but check-digit-valid read: 0. Short-code reads refused as too small to trust: 33.
Mean decode 16 ms over 2052 frames of 960×720 on this machine.

What the numbers say:

- Every symbology reads every clean code except GS1 DataBar and DataBar Stacked. Vision
  misses some DataBar codes whatever their height; their widths match the bwip-js
  reference exactly, and Vision misses bwip-js's rendering of them too. DataBar is
  mostly on loose produce, but it's the scanner's weakest symbology. The test holds
  DataBar to 70% and Stacked to 60% clean, and everything else to 100%.
- **Small** EAN-8 and UPC-E are refused, not misread. At about two pixels a module Vision
  read small DataBars as EAN-8s whose check digit passed, twice in a row, so an earlier
  build accepted one wrong code. Short codes now need 2.5 pixels a module
  (`BarcodeLegibility`), and the scanner says "Hold it closer". Closer, they read at 100%.
- **Low light** at 20% white with heavy noise defeats every DataBar and some GS1-128; the
  light prompt is for exactly this. **Damage** hurts QR and Micro QR, which lose finder
  patterns to the smudge.
- Rotated EAN-8 reads 60% at 35°; most people hold a code level.

## Time from open to logged

`BarcodeScannerUITests.testBarcodeToLoggedInThreeTapsWithEachStepTimed`, iPhone 17 Pro Max
simulator, iOS 26.2. The stand-in feed polls the fixture every 100 ms; the in-app times start
when it has the code.

Taps from Today: **3** (Scan, the scan, Log), within the budget of 3. One food found
before logs again from Recent scans in **2** (Scan, Log).

Measured inside the app (two runs; the stand-in feed decodes four frames through Vision
revision 1 in the simulator, slower than a phone's current revision):

| Step | Run 1 | Run 2 |
| --- | ---: | ---: |
| Scanner open to camera watching | 58 ms | 112 ms |
| Code shown to accepted (two agreeing reads) | 176 ms | 184 ms |
| Accepted to on the plate (lookup and plate) | 75 ms | 70 ms |

Wall-clock through XCUITest, on devbox1 shared with three other simulators. XCUITest
polls for elements about once a second and waits for the app to idle after each tap, so
these measure the harness more than the app:

| Step | Run 1 | Run 2 |
| --- | ---: | ---: |
| Tap Scan to camera ready | 8.8 s | 9.3 s |
| Code shown to food on plate | 1.1 s | 1.1 s |
| Tap Log to Today showing the entry | 13.9 s | 13.2 s |
| Open to logged | 25.0 s | 24.8 s |
| Repeat scan from the cache, open to logged | 23.9 s | 22.7 s |

## Still to check on a phone

The simulator has no camera, so these are unverified until run on hardware:

- The region of interest lines up with the drawn window (`ScannerOptics.visionRegion`),
  in portrait, on a Pro (triple camera) and a non-Pro (dual wide) phone.
- Auto zoom picks about 2× on the wide lens, macro switching still happens close up, and
  pinch feels right.
- EXIF brightness crosses −1 in a dim kitchen but not in normal room light, and the
  torch prompt appears within about a second and a half.
- Real packs: a curved can, a shiny wrapper under kitchen light, a crumpled bag, a small
  UPC-E on a gum pack, an ITF-14 on a case, a DataBar on produce, a Digital Link QR.
- Holding one pack in view adds it once; showing a second identical pack adds one more.
- The success haptic, and VoiceOver's announcement, with the screen reader on.
- Frame rate stays smooth with Vision on every frame (one in flight, late frames dropped).
