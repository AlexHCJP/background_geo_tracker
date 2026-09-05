## 0.12.0

Changelog


## 0.11.0

* **Removed the last `Attractor`/`attractor_geo` naming** — the Android
  package (`school.attractor.attractor_geo` → `dev.background_geo_tracker.plugin`),
  the `AttractorGeoPlugin`/`AttractorGeoLaunch` classes (now
  `BackgroundGeoTrackerPlugin`/`BackgroundGeoTrackerLaunch`), the method
  channel names, and every on-device storage identifier (SQLite filenames,
  the Keychain service, the `UserDefaults` prefix, the `SharedPreferences`
  files, the notification channel and the WorkManager job names) now say
  `background_geo_tracker` throughout. Unlike the 0.3.0 rename, this one is
  breaking for existing installs: upgrading orphans any queued points and
  stored credentials, and an already-scheduled Android job from an older
  version has to be cancelled by hand, because none of the old identifiers
  survive.
* Update the iOS host call to `BackgroundGeoTrackerLaunch.resumeIfTracking()`.
  Nothing about the Dart API moved.

## 0.10.0

* Every queued and uploaded point now carries a required `session_id`, so an
  offline tail cannot be attributed to a later sharing session.
* Both platforms refuse to start without a valid HTTPS configuration,
  background/Always permission, and enabled location services.
* Status now separates persisted user intent (`isTracking`) from the native
  collector's current runtime state (`collectorRunning`).
* Stopping makes a final best-effort drain; sign-out/reset still cancels all
  work and clears credentials and points.
* Android restores a desired session after the user manually reopens a
  force-stopped app. Boot restore is permission-checked and the receiver is no
  longer exported.
* iOS automatically resumes on ordinary plugin registration; the host launch
  hook remains required for location-triggered launches with no Flutter UI.
* iOS queue storage uses Data Protection, is excluded from backup, and safely
  discards unattributable rows from older schemas.

## 0.9.0

* **`stopTimeoutSeconds: 0` disables stop detection.** The GPS stays on for
  the whole session. Previously there was no way to turn the state machine
  off: you had to set an absurdly large timeout and hope it was never
  reached. Zero means "disabled", not "stop immediately" — the second
  reading would have killed collection on the second fix of every session.
  The same convention as `elasticityMultiplier: 0`.
* **iOS: `distanceFilterMeters: 0` now really means "no filter".**
  `kCLDistanceFilterNone` is `-1`, and CoreLocation does not define zero: in
  practice the delegate simply went silent. The configuration asked for
  every fix and got silence — the worst kind of platform divergence, because
  Android worked fine with the same settings. Zero and below are now
  translated to the constant.
* README got a section on how to configure the package for real-time use,
  and what it costs in battery, requests, and stationary-marker jitter.

## 0.8.0

* **`sendAfterPoints` split off from `batchSize`.** A single number answered
  two questions — "when does the request go out" and "how many points does
  it carry" — and that made freshness unaffordable on its own: the only way
  to buy it was to pair it with a tiny request, so an hour offline would
  leave as a hundred and eighty round trips, and a single failure among
  them was enough to put the queue into backoff.

  ```dart
  GeoUploadConfig.standard(
    …,
    sendAfterPoints: 1,   // the request leaves with every recorded point
    batchSize: 50,        // anything accumulated offline leaves fifty at a time
  )
  ```

  Nothing breaks: `sendAfterPoints` defaults to `batchSize`, and the native
  stores read the old key as a fallback, so a configuration from an earlier
  build behaves exactly as it did before.
* Both platforms count the threshold from the new field, while the request
  size still comes from `batchSize`: the Android worker drains the queue in
  a `while (true)` loop, iOS sends `oldest(batchSize)` in a loop, so a low
  threshold does not fragment the backlog.
* The `waiting for a sweep — n/m` status line on iOS now shows the
  threshold rather than the batch size: previously it named a number that no
  longer had anything to do with the decision.

## 0.7.0

* **Breaking: the notification is now configured via `GeoNotificationConfig`.**
  `notificationTitle` and `notificationBody` moved into a new object
  alongside `filter` and `motion`; `GeoUploadConfig.notification` is
  required and has no default, because half of it is user-facing text and
  the package has no locale of its own. Caller-side change:

  ```dart
  GeoUploadConfig.standard(
    url: …,
    headers: …,
    notification: GeoNotificationConfig.standard(
      title: 'Route recording',
      body: 'Recording your route',
      channelName: 'Route recording',
    ),
  )
  ```

  The `notification_title` and `notification_body` wire keys are unchanged,
  so the native store from a previous build reads exactly as it did.
* **The status-bar icon belongs to the host, not to Android.** `smallIcon`
  takes a drawable name from the app's own resources; the native side looks
  it up in `drawable`, then `mipmap`, and on a miss logs
  `notification.icon` and falls back to the system icon. It never throws:
  an invalid id would drop the notification when it is posted, taking the
  whole foreground service down with it.
* **The channel is named in the app's own words.** `channelName` replaces
  the hardcoded English "Location tracking", which used to read exactly
  that way in the system settings of a localized app. Renaming applies on
  the next `configure`; changing `importance` does not — once a channel is
  created, only the user can move it.
* **`importance`** — `low` (default, silent) or `normal`. An unknown name
  reads as `low`: a session runs for hours, and an unfamiliar string should
  not be what makes it start making noise.
* **`tapOpensApp`** — tapping opens the host's launcher activity. Enabled by
  default: a persistent notification that does not react to a tap reads as
  a frozen app.
* Not implemented and not planned: action buttons, a custom layout,
  `largeIcon`. There is nobody to service a button — there is no Dart
  isolate at that moment.

## 0.6.0

* **The collector switches off the GPS when the device is stationary.**
  After standing still inside `motion.stationaryRadiusMeters` for
  `motion.stopTimeoutSeconds`, the session turns off location updates and
  arms two detectors — Activity Recognition (`CMMotionActivityManager` on
  iOS) and a geofence around the anchor. Whichever fires first turns
  collection back on. Before this, a phone that sat on a desk for eight
  hours kept the GPS on for all eight hours: this was the one difference
  from the reference implementation a user could feel without reading logs.
* **`distanceFilterMeters` grows with speed.** At 90 km/h a point is written
  roughly once every ~360 m instead of every 20, with a ceiling of 500 m.
  `GeoMotionConfig(elasticityMultiplier: 0)` disables the stretching — that
  is "disabled", not "filter set to zero metres", and these two readings
  give opposite results, so zero is handled by a separate branch before the
  calculation.
* **`GeoUploadConfig` gains a required `motion` field.** `standard()`
  supplies `GeoMotionConfig.standard()`, so calling code has nothing to
  change unless it wants different numbers.
* **The status reports whether the collector is asleep.**
  `GeoTrackingStatus.isMoving` and `motionPermission` —
  `granted` / `denied` / `unavailable`. Without them, stopped collection
  looks like a healthy session whose position just isn't changing for some
  reason; `unavailable` is kept separate from `denied` because in the
  latter case the permission can be asked for, and in the former there is
  nothing to ask.
* **For hosts:** iOS needs the `NSMotionUsageDescription` key in
  Info.plist — without it the app crashes on the first call to CoreMotion.
  Android declares `ACTIVITY_RECOGNITION` itself and asks for it at
  `start()`; a refusal costs wake-up latency (~200 m on the geofence), not
  functionality.
* The state machine only runs under `Always`: under `whenInUse` there is
  nobody to wake a switched-off GPS, so the collector behaves as before
  there. Filter stretching works under any authorization.

## 0.5.0


* **Breaking: `GeoUploadConfig` takes one `url`, not `baseUrl` and `path`.**
  The uploader never had a use for the two halves apart — it joined them back
  together and posted to the result. All the split bought was a way to be
  wrong about who owns the slash between them, re-answered by every caller,
  with the caller that got it wrong finding out as a 404 inside a background
  uploader nobody watches. Callers pass the finished endpoint:

  ```dart
  GeoUploadConfig.standard(url: 'https://api.example.com/v1/points', …)
  ```

  The method-channel key changes with it — `base_url` and `path` become `url`
  — and both platforms read only the new one. Nothing reads the old pair and
  nothing migrates it: an install carrying a stored config from an earlier
  build reads an empty URL and posts nowhere until something calls `configure`
  again. Reinstall, or make the host re-configure on launch.
* **The status says why the queue is not draining.** `GeoTrackingStatus` gains
  `uploadUrl` — the endpoint the *native* uploader holds, which is not always
  what the app believes it configured — and `lastUpload`, how the last drain
  ended: `ok`, `no url — never configured`, `http 500`, `network: …`,
  `halted: credentials refused`. The uploader gives up at five separate guards
  and did so in silence at every one, which made a growing queue on an
  otherwise healthy-looking collector impossible to explain from a log. Both
  fields decode with fallbacks, so a platform that has not implemented them
  still produces a usable status.
* **Android: an unusable endpoint no longer kills the worker.** `Request.url`
  throws `IllegalArgumentException`, which the worker's `IOException` catch
  never covered, so an empty URL took the drain down with nothing to show for
  it. Parsed up front now, and recorded as `lastUpload`.

## 0.4.1

* **iOS: a session comes back after a reboot again.** The relaunch path ran
  entirely through the plugin's own application delegate, and a plugin is
  registered only once the implicit `FlutterViewController` exists. In a
  scene-based app that view controller is instantiated when a UI scene
  connects — and iOS waking the app in the background for a significant
  location change connects none. So on the one launch the whole path was built
  for, nothing ran: no `CLLocationManager`, no drain, no points. A phone
  switched off and back on stayed silent, and the position the backend served
  for it was the one from the moment it powered down, until its owner opened
  the app by hand.
* **One line for hosts:** call `AttractorGeoLaunch.resumeIfTracking()` from
  your `AppDelegate`'s `application(_:didFinishLaunchingWithOptions:)`. That
  method is what a background launch does call. See the iOS setup section of
  the README, which until now said no `AppDelegate` changes were needed.
* The collector's "a point arrived" hook onto the uploader moved next to the
  resume, so both ways of bringing the native stack up wire it identically.

## 0.4.0

* **`currentPosition()`** — one fix, read once, for a caller that cannot wait
  for the session's next point. `points` only carries a fix after the device
  has moved `distanceFilterMeters`, and drops whatever it collects while nobody
  is subscribed, so a map opening on a stationary phone had nothing to centre
  on for as long as it took the device to move. Returns a recent cached fix at
  once, otherwise asks the OS and falls back to a stale one; null when the
  permission is missing or nothing arrives in time. It never prompts, never
  queues the point for upload, never pushes it onto `points`, and neither needs
  nor disturbs a running session.
* iOS runs the read on a `CLLocationManager` of its own. The tracker's manager
  has one delegate for both ways of asking, so a `requestLocation` on it would
  have delivered its answer into the collector — recording a point nobody asked
  to record. Android asks the fused provider through `CurrentLocationRequest`,
  which applies the timeout itself.
* Building a point out of a platform location moved to one place per platform,
  shared by the collector and the read, so the same fix cannot describe itself
  differently depending on which way it arrived.

## 0.3.0

First release on pub.dev. Nothing about how tracking works changed; everything
below is naming, packaging and documentation.

* **Renamed from `attractor_geo` to `background_geo_tracker`**, and
  `AttractorGeoController` to `BackgroundGeoTracker` with it. The old name said
  who wrote the package rather than what it does, which is no use to anyone
  finding it on pub.dev. Update the dependency, the import and the one class
  name; nothing else about the API moved.
* **Storage identifiers deliberately kept as `attractor_geo*`** — the SQLite
  filenames, the Keychain service, the `UserDefaults` prefix, the
  `SharedPreferences` files, the notification channel and the WorkManager job
  names. Renaming them would orphan the queue and the stored credentials of
  every install that upgrades, and leave an already-scheduled Android job that
  the new code no longer knows how to cancel. An upgrade from 0.2.0 keeps its
  undelivered points.
* Documentation rewritten for use outside the repository it was extracted
  from. The install snippet is a version, not a path, and the passages that
  pointed at wrapper classes living in that app are gone — `reset()` on
  sign-out and re-`configure()` on `start()` are now stated as the host's job,
  because outside that app nothing else does them for you.
* Dropped the App Transport Security and Android cleartext-HTTP sections. Both
  documented how to weaken a host app's network security to reach a plaintext
  development backend, which is a local concern and not something a package
  should be teaching.
* Every public member now carries documentation, and the package ships with a
  `.pubignore`, MIT licence and pub.dev metadata.

## 0.2.0

* **Added `reset()`** — ends the session and forgets what belonged to the
  account that was signed in: the stored upload credentials and every queued
  point. `stop()` deliberately keeps both. Without this the credentials and the
  queue outlived a sign-out, and the next account on the device would upload
  the previous one's track under its own name.
* **Android now reports status changes.** It previously published a status only
  when the backend refused a credential, so a UI watching `statusChanges` never
  learned that a session had started, that a permission dialog had been
  answered, or that permission had been revoked mid-session — while iOS
  reported all of them. Answered permission dialogs are picked up through a
  `RequestPermissionsResultListener`, which the plugin did not register at all.
* **Android asks for `POST_NOTIFICATIONS`** once at `start`, on API 33+. The
  foreground service's notification is required to be visible for the whole
  session and did not appear without the runtime grant. Refusing it hides the
  notification and does not stop the session.
* **Stopping cancels the one-shot upload job too.** Only the periodic one was
  cancelled, so a drain enqueued moments earlier could still wake up and upload
  using credentials the app had already discarded.
* **Android honours `uploadIntervalSeconds`.** The interval was served by
  WorkManager, whose floor for periodic work is 15 minutes, so a phone sitting
  still under `batchSize` held its points for a quarter of an hour while iOS
  shipped them in a minute — one setting meaning two different things. The
  foreground service, alive for the whole session anyway, now drives the drain
  itself and only enqueues when the queue is non-empty. The periodic worker
  stays as the fallback for a collector the OS has killed.
* **iOS honours its own backoff.** The periodic drain ran on its own schedule
  regardless of a backoff in progress, so a backend that was down was retried
  every upload interval and the computed backoff only ever delayed whichever
  attempt lost the race.
* One `OkHttpClient` across worker runs on Android, instead of one per run
  throwing away the connection pool.

## 0.1.0

* Continuous route tracking on iOS and Android, collected and uploaded entirely
  in native code — a session survives the app being backgrounded, evicted or
  rebooted, with no live Dart isolate.
* Durable SQLite queue bounded by both a point ceiling and an age window, so a
  long offline stretch cannot grow without limit.
* Batched upload with shared response classification: success, stale
  credentials, permanently rejected, or retry.
* Upload credentials stored in EncryptedSharedPreferences and the Keychain.
* Permission escalated one step at a time, foreground before background.
