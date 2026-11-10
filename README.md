<p align="center"><img src="docs/assets/lockup.png" alt="TagAlert" width="420"></p>

<p align="center"><b>Is there an AirTag following me? TagAlert answers that now.</b><br>
An iPhone app that finds nearby Apple AirTags and warns when one is traveling with you.<br>
APCV 498 Senior Capstone, University of Arizona. Elizabeth Hadik-Barkoczy.</p>

<p align="center"><a href="https://hadik-uofa.github.io/TagAlert">Project website</a> ·
<a href="docs/files/TagAlert_Final_Report.pdf">Final report (PDF)</a> ·
<a href="docs/files/TagAlert_Test_Results.xlsx">Test results</a> ·
<a href="logs/">Test logs</a></p>

---

## What it does

- **Finds AirTags on an iPhone**, even though iOS hides the Find My broadcast that identifies them.
- **Warns only when a tag moves with you.** Tags that are simply nearby stay at Low.
- **Makes the tag beep** so you can find it, after asking you first.
- **Uses no location.** Movement comes from the step counter and activity type. No account, no server, nothing leaves the phone.

## How it identifies an AirTag

iOS does not pass Apple's Find My advertisement to third-party apps. In every scan logged, nearby AirTags appeared only as unnamed Bluetooth devices with no identifying data. So TagAlert checks each one:

1. **Queue** every unnamed device seen in a scan (strongest signal first, with a queue-age rule so weak devices are not starved).
2. **Connect** briefly (6 s for a strong device, 10 s for a weak one; retries back off at 10, 20, 40, then every 60 s).
3. **Ask for one service:** UUID `7DFC9000-7D1C-4951-86AA-8D9728F8D66C`.
4. **Decide and disconnect.** A device that offers the service is an AirTag. TagAlert never pairs with or changes it.

The same service carries the sound command: writing byte `AF` to characteristic `7DFC9001` makes a tag separated from its owner beep. Apple's tags refuse it when the owner is nearby.

The method follows the [AirGuard](https://github.com/seemoo-lab/AirGuard-iOS) research project (Secure Mobile Networking Lab, TU Darmstadt). TagAlert's code is an independent implementation; no AirGuard code was copied.

## Threat levels (Version 6 build b)

| Level | Rule |
|---|---|
| Low | Seen under 1 minute, or not moving with you |
| Medium | Seen 1 to 2 minutes and moving with you |
| High | Seen 2 minutes or more and moving with you |

**Moving with you** means 50 m walked (or 60 s in a vehicle) between the tag's first and latest sighting, the tag seen in at least 60% of scan cycles over at least 4 cycles, and seen within the last 25 s. Signal strength is not used: two tags side by side read about 15 dB apart. Without movement data (Fitness Tracking off), levels use time only and High is capped at Medium.

## Results (iPhone SE 2nd gen, iOS 17.6.1, November 1 to 9, 2026)

| Measure | Result |
|---|---|
| Time to confirm an AirTag (strongest-first probing, 21 confirmations) | 2.9 to 28.0 s, median 10.4 s |
| Final walk, tag in pocket (B7) | Medium at 72 s / 77 m, High at 123 s / 148 m, beep accepted |
| Stationary controls with the movement check (7 tests, up to 47 min) | 0 alerts |
| False Medium or High on the last 4 walks | 0 |
| Beep on the user's tags, separated from owner | 26 of 27 accepted |
| Beep on a tag whose owner was nearby | 0 of 3 (same tag 1 of 1 with owner away) |
| Battery, screen on, 47-minute run | 13% used, about 17% per hour |

Every number can be recomputed from the logs:

```bash
python3 tools/analyze_log.py --totals logs/*.csv
```

## Limits

- Works only while the app is open (iOS does not deliver these scans to a suspended app).
- One phone, one home, one walking route, three to four AirTags over nine days.
- iOS hides whether a tag is with its owner, so a stranger's tag that genuinely travels with you (a fellow commuter's keys) is flagged like a planted one.
- Beep works only on a tag separated from its owner and in range.
- AirTags only; other Find My accessories, SmartTags and Tile are not detected.
- Walking distances are step-counter estimates; the vehicle rule is untested.

## Repository layout

```
app/TagAlert/      Swift source (SwiftUI, Core Bluetooth, Core Motion), Info.plist reference
app/Sounds/        Four alert sounds made for the project
logs/              21 CSV test logs (nearby device names redacted)
tools/             analyze_log.py, recomputes the reported results
docs/              Project website (GitHub Pages), report, test results, screenshots
branding/          Logo and app icon
```

## Build it

Requires a Mac with Xcode and a physical iPhone (Bluetooth scanning does not work in the Simulator).

1. In Xcode, create a new **iOS App** named `TagAlert` (Interface: SwiftUI, Language: Swift).
2. Delete the generated `ContentView.swift` and `TagAlertApp.swift`, then drag in every `.swift` file from `app/TagAlert/` and the `.wav` files from `app/Sounds/`. Check **Copy items if needed** and the TagAlert target.
3. In the target's **Info** tab, add the keys from `app/TagAlert/Info.plist`: `NSBluetoothAlwaysUsageDescription`, `NSMotionUsageDescription`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`.
4. Optional: add `branding/AppIcon-1024.png` as the app icon.
5. Select your team under **Signing & Capabilities**, connect the iPhone, enable Developer Mode on it, and run.

Test logs are written to the app's Documents folder (visible in the Files app under On My iPhone > TagAlert).

## Credits and references

- Heinrich, Bittner and Hollick (2022). *AirGuard: Protecting Android Users from Stalking Attacks by Apple Find My Devices.* ACM WiSec. Source: [seemoo-lab/AirGuard-iOS](https://github.com/seemoo-lab/AirGuard-iOS)
- Heinrich, Stute, Kornhuber and Hollick (2021). *Who Can Find My Devices?* Proceedings on Privacy Enhancing Technologies.
- IETF, *Detecting Unwanted Location Trackers Accessory Protocol* (Internet-Draft).

AirTag, Find My and iOS are trademarks of Apple Inc. This project is not affiliated with Apple.

## License

MIT. See [LICENSE](LICENSE).
