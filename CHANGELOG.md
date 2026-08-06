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
