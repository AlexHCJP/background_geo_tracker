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

---

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

---

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
