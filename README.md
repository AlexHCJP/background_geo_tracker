# background_geo_tracker

Native continuous route tracking with backend upload. iOS and Android.

The native layer is self-sufficient: it collects points and uploads them
without a live Dart isolate. A session keeps running while the app is
backgrounded or evicted from memory, and resumes by itself afterwards.

This repository is a maintained fork of
[`AlexHCJP/background_geo_tracker`](https://github.com/AlexHCJP/background_geo_tracker).
The original MIT copyright and license are preserved.

- [Install](#install)
- [iOS setup](#ios-setup)
- [Android setup](#android-setup)
- [Usage](#usage)
- [Backend contract](#backend-contract)
- [What the package guarantees](#what-the-package-guarantees)
- [Tuning](#tuning)
- [Store review](#store-review)
- [Testing](#testing)

## Install

```yaml
dependencies:
  background_geo_tracker:
    git:
      url: https://github.com/tahayildirm/background_geo_tracker.git
      ref: v0.5.1
```

Platform floors, both enforced by the package:

| Platform | Minimum |
|---|---|
| iOS | 13.0 |
| Android | `minSdk` 24 |

`BackgroundGeoTracker` is the whole Dart API. Worth wrapping it in a service
of your own that owns the backend URL and the auth headers, so the rest of the
app never has to hold a token to start a track — and so there is somewhere to
put a mock for working on screens without a GPS fix.

---

## iOS setup

### 1. `ios/Runner/Info.plist`

All three entries are mandatory.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>…why you need the location while the app is open…</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>…why you need to keep recording after the user leaves the app…</string>
<key>UIBackgroundModes</key>
<array>
	<string>location</string>
</array>
```

Two failure modes worth knowing before you hit them:

- **Missing usage string → silent refusal.** iOS does not show the prompt and
  does not report an error. It looks exactly like the user tapping "Don't
  Allow", and you will go looking for the bug in the wrong place.
- **Missing `UIBackgroundModes` → crash.** Setting
  `allowsBackgroundLocationUpdates`, which the tracker does on `start()`,
  throws when the background mode is absent.

**`location` is the only background mode you need — including for the
uploads.** There is no background mode for networking on iOS; the list is
closed and has no networking entry. Networking is not a gated capability —
any app that is *running* may use it. Background modes decide whether your app
gets to keep running, and `location` is what keeps us alive; while alive,
`URLSession` works normally, and each request is additionally wrapped in
`beginBackgroundTask` (a runtime API, not a plist key) to survive the moment of
suspension. Declaring `fetch` or `processing` "to be safe" is actively harmful:
App Review asks you to justify every mode you declare, and we use neither.

### 2. `ios/Runner/AppDelegate.swift`

One line, and the session survives the process dying:

```swift
import background_geo_tracker

override func application(
  _ application: UIApplication,
  didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
  AttractorGeoLaunch.resumeIfTracking()
  return super.application(application, didFinishLaunchingWithOptions: launchOptions)
}
```

**Leave it out and tracking never comes back after a reboot.** iOS wakes the
app in the background when a significant location change arrives after the
process died, and hands that launch to `UIApplicationDelegate` alone. A
scene-based app — which is every app on a recent Flutter — instantiates its
storyboard only when a *UI* scene connects, and a background launch connects
none. The implicit `FlutterViewController` is what triggers plugin
registration, so on that path this plugin is never registered and its own
application delegate is never called. Nothing creates a `CLLocationManager`,
nothing drains the queue, and the last position the backend has is the one
from the moment the phone was switched off — until the user opens the app by
hand. The symptom is a device that goes quiet for hours and looks, from the
server, like it never moved.

The call is safe on every launch and does nothing when no session was running.

### Privacy manifest

The package ships its own `PrivacyInfo.xcprivacy`, declaring precise-location
collection and its use of `UserDefaults` (a required-reason API, code
`CA92.1`). You do not need to repeat those.

You **do** need to declare location collection in your own app's privacy
manifest and in the App Store privacy questionnaire. Apple rejects submissions
that collect location without declaring it.

### Reduced accuracy

From iOS 14 the user can grant **Approximate** location instead of precise.
The permission still reads as granted and points still arrive — but they are
off by kilometres, which is useless for a route track. The package does not
currently detect or request an upgrade to full accuracy
(`requestTemporaryFullAccuracyAuthorization`); if your feature depends on
precision, treat this as a known gap rather than an assumption you can make.

---

## Android setup

### 1. Nothing in the manifest

The plugin manifest already declares everything and is merged into the host:

| Permission | Why |
|---|---|
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | the fix itself |
| `ACCESS_BACKGROUND_LOCATION` | keep collecting once the app is backgrounded |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` | the collector runs as a `location`-typed foreground service |
| `POST_NOTIFICATIONS` | the service's mandatory ongoing notification |
| `RECEIVE_BOOT_COMPLETED` | resume an active session after a reboot |
| `WAKE_LOCK`, `INTERNET` | uploading |
| `ACCESS_NETWORK_STATE` | arrives transitively from WorkManager, which needs it for the "only on a connection" upload constraint |

Also merged in: `GeoTrackingService` (foreground service, type `location`) and
`BootReceiver`.

Note what this means for the host: **adding this package makes your app
request background location**, whether or not any screen uses tracking yet.
That has Play Console consequences — see [Store review](#store-review).

### 2. `POST_NOTIFICATIONS` is asked for by the package

On Android 13+ the foreground-service notification does not appear without it,
and a session the user cannot see running is both hostile and a review risk.
`start()` asks for it once if it is missing, and proceeds either way — refusing
it hides the notification but does not stop the session.

It is deliberately not part of `requestPermission()`, which escalates location
and nothing else, and not a precondition of `start()`, which would let a
notification prompt block a track.

Asked at `start` rather than next to the location prompt so that a user who
granted location before this behaviour existed still gets asked once.

### 3. Background location goes through Settings

From Android 11 `ACCESS_BACKGROUND_LOCATION` cannot be granted from an in-app
dialog. The second `requestPermission()` call deep-links to the app's settings
page instead. Your UI has to explain what the user is being sent to do, because
the OS screen will not.

---

## Usage

Permission is a **two-step escalation**, and the order is not optional: ask for
foreground first, and only ask for background once a session is actually
starting. Requesting background up front is presented by iOS as "allow once",
with no way to upgrade later.

```dart
final geo = BackgroundGeoTracker.standard();

// 1. Foreground. Call again to escalate to background.
await geo.requestPermission();

// 2. URL, credentials and policy. Safe to call repeatedly.
await geo.configure(
  GeoUploadConfig.standard(
    sessionId: consentId,
    url: 'https://api.example.com/v1/tracking/points',
    headers: {'Authorization': 'Bearer $token'},
    notificationTitle: 'Tracking',            // Android notification copy;
    notificationBody: 'Recording your route', // ignored on iOS
  ),
);

// 3. Go. Both platforms require “Always” location authorization.
await geo.start();

// …later
await geo.stop();
```

### Signing out

`stop()` ends collection and makes one final upload attempt. Any offline tail
stays in the queue with its own `session_id`; it can never be attributed to a
later sharing session on the same device.

Signing out is the other case, and `stop()` is **not** enough for it:

```dart
await geo.reset();
```

This ends the session, cancels any drain the OS still has scheduled, wipes the
stored credentials and empties the queue. Both the credentials and the queue
live natively — that is what lets uploading survive with no Dart isolate alive,
and it also means both would otherwise outlive a sign-out and hand the next
account on the device someone else's track to upload under its own name.

What survives a reset, on purpose, is the record that this device has already
been shown the location prompt. That is knowledge about the device, not about
whoever was signed in; clearing it would make a permanently denied permission
look re-askable and the UI would offer a dialog the OS refuses to show.

Nothing in the package knows what a sign-out is, so nothing calls this for you.
Wire it into whatever tears a session down, next to clearing your own tokens —
the one place that already knows the account is going away.

### Watching a session

```dart
geo.statusChanges.listen((status) {
  status.isTracking;               // session running
  status.permission;               // denied / whenInUse / always / permanentlyDenied
  status.queuedPoints;             // waiting to upload
  status.authFailed;               // backend rejected our credentials
  status.locationServicesEnabled;  // location switched on device-wide
});

geo.points.listen(...);            // live points, for a map or a debug readout
```

Both streams are built once and reused — reading the getter twice hands you the
same stream. Points upload natively whether or not anyone is listening.

A status is published whenever one can have changed, on both platforms: a
session starting or ending, an answered permission dialog, a permission revoked
from Settings mid-session, a reset, and a credential the backend refused. The
same status may arrive twice — an explicit `stop()` is reported by the plugin
and again by the collector shutting down — so treat the stream as state to read,
not as events to count.

### Where am I, right now

```dart
final point = await geo.currentPosition();          // null when it cannot say
final soon = await geo.currentPosition(timeout: const Duration(seconds: 3));
```

`points` is a stream of *changes*: a fix reaches it only once the device has
moved `distanceFilterMeters`, and whatever was collected before you subscribed
is gone, because collection does not wait for a listener. So a screen that opens
while the phone sits on a desk can wait minutes for its first point — which is a
map with nothing to centre on. `currentPosition` is the answer that stream
cannot give.

It hands back the platform's own cached fix when that fix is recent, which
returns at once; otherwise it asks the OS for a fresh one, and falls back to a
stale cached fix rather than to nothing when that does not arrive in time. Null
means the permission has not been granted, location services are off, or nothing
came back in time. It never prompts, so a screen asking where it is cannot be
what puts a permission dialog in front of the user.

It is a read: the point is neither queued for upload nor pushed onto `points`,
and asking does not start a session. The two are independent — this answers with
no session running, and a running session is not disturbed by it.

### Recovering from `authFailed`

A 401 stops uploading and **keeps collecting**. Call `configure` again with a
fresh token and the queue drains; nothing collected in the meantime is lost.

```dart
if (status.authFailed) {
  await geo.configure(
    GeoUploadConfig.standard(
      sessionId: sessionId,
      url: url,
      headers: {'Authorization': 'Bearer $freshToken'},
      notificationTitle: title,
      notificationBody: body,
    ),
  );
}
```

Cheapest way not to have to think about this: call `configure` on every
`start()` rather than once at boot. A token rotated while the app was closed is
then picked up without anyone having to notice `authFailed` at all.

### When permission is permanently denied

```dart
await geo.openSystemSettings();
```

---

## Backend contract

`POST {url}` with a flat JSON array:

```json
[
  {
    "id": "b7e4…",
    "lat": 55.751244,
    "lon": 37.618423,
    "accuracy": 8.5,
    "altitude": 156.0,
    "speed": 4.2,
    "heading": 271.0,
    "recorded_at": "2026-08-02T10:15:03Z",
    "is_mock": false,
    "battery_level": 0.62
  }
]
```

Units, so client and server cannot quietly disagree: `accuracy` and `altitude`
in metres, `speed` in m/s, `heading` in degrees clockwise from true north,
`recorded_at` ISO 8601 **UTC** with a `Z`, `battery_level` a fraction from
`0.0` to `1.0` — not a percentage. `altitude`, `speed`, `heading` and
`battery_level` are present as `null` when the platform has nothing to report.

**The backend must de-duplicate by `id`.** This is a requirement, not a
preference. A response that times out is retried, and the client cannot know
whether the batch landed — without server-side dedup the track doubles.

`is_mock` flags a fix from a mock location provider. If the track affects money
or accountability, do not trust data without checking it.

### What the client does with your response

| Response | Action |
|---|---|
| 2xx | points deleted from the queue |
| 401 | `authFailed` raised, uploading halts, **collection continues** |
| 408, 429, 5xx, network error | batch kept, exponential backoff |
| any other 4xx | **batch dropped** and logged |

That last row is deliberate. A batch the server will never accept would
otherwise retry forever and block every point behind it. If you return 400 for
something transient, you will lose those points.

---

## What the package guarantees

The track survives backgrounding and eviction by the system, and resumes on its
own afterwards.

After a **manual** kill — swiping the app away on iOS, `Force stop` on Android
— it degrades rather than dies:

- iOS falls back to significant-location-change wake-ups: coarse points,
  roughly every 500 m or cell handover.
- Android resumes at the next reboot.
- Either way, opening the app restores full tracking and drains the queue.

Queued points are not lost to a crash, a kill or a reboot: they live in a
native database, bounded to 20 000 points or 7 days, oldest evicted first.

Two things do throw them away, both on purpose. The ceilings above evict the
oldest first, and [`reset()`](#signing-out) empties the queue outright — a
sign-out must not leave one account's track for the next one to upload.

**Metre-accurate continuous tracking after a manual swipe is not achievable on
iOS.** Not by this package and not by any other, paid ones included. iOS treats
the swipe as "stop doing things", and only significant-change or region
monitoring will wake the app again. Do not design a feature that depends on it.

---

## Tuning

`GeoUploadConfig.standard(...)` fills in the tuned defaults below. `sessionId`
is required and is written into every queued point. Use the full
constructor to override them — every field is required there, so an override
states the whole policy rather than silently inheriting half of it.

| Setting | Default | Meaning |
|---|---|---|
| `distanceFilterMeters` | 20 | record a point after this much movement |
| `minIntervalSeconds` | 10 | …but never more often than this |
| `batchSize` | 50 | upload once this many are queued |
| `uploadIntervalSeconds` | 60 | …or after this long, whichever comes first |
| `queueMaxPoints` | 20000 | queue ceiling, oldest evicted first |
| `queueMaxAgeDays` | 7 | age ceiling, same eviction |

**`uploadIntervalSeconds` means the same thing on both platforms while a
session is running** — the collector drives the drain itself, iOS on a timer
and Android from the foreground service.

It parts company only after the OS kills the collector with points still
queued. Draining then falls to Android's background scheduler, which refuses
periodic work more often than every 15 minutes, so leftovers can wait that long
for the next pass. iOS gets relaunched by significant-location-change instead
and resumes on its own schedule.

---

## Store review

Both stores treat background location as a privileged capability, and both
will ask you to justify it in prose:

- **App Store** — the review form needs a written justification for `Always`
  plus background location.
- **Play Console** — needs a justification *and* a video demonstrating the
  in-app flow that leads to the background-location prompt.

Budget real time for this. It is a common cause of rejection, and it is not a
formality you can fill in at the last minute.

---

## Testing

```bash
# Dart — from the package root
flutter test

# Android
cd example/android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  ./gradlew :background_geo_tracker:testDebugUnitTest

# iOS (boots a simulator)
cd example/ios
flutter build ios --simulator --config-only   # once, to generate the xcconfig
xcrun simctl list devices available           # pick a UDID from the list
xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:RunnerTests
```

Give the destination as a **UDID, not a name**: with more than one iOS runtime
installed, `name=iPhone 13 Pro` matches nothing and xcodebuild fails with
"Unable to find a device matching the provided destination specifier".

To compile the tests without booting anything — enough to catch a Swift error —
swap `test` for `build-for-testing -destination 'generic/platform=iOS
Simulator'`.

Unit tests cover response classification, backoff and its gate, wire
serialisation, queue eviction and emptying, and what a credential reset does
and does not forget. Everything that actually distinguishes this package —
background
survival, relaunch after eviction, real GPS — is **not** unit-testable and has
to be checked by hand on a physical device. `example/` is the harness for
testing backgrounding, process eviction, device reboot, offline queue recovery,
permission changes and token renewal.

An emulator or simulator will not do: neither reproduces Doze, memory
eviction, or a moving GPS fix.
