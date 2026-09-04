
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

* **`stopTimeoutSeconds: 0` выключает стоп-детекцию.** GPS горит всю сессию.
  Раньше выключить машину состояний было нечем: приходилось ставить абсурдно
  большой таймаут и надеяться, что до него не дойдёт. Ноль означает
  «выключено», а не «останавливаться немедленно» — второе прочтение гасило бы
  сбор на втором фиксе каждой сессии. Та же идиома, что у
  `elasticityMultiplier: 0`.
* **iOS: `distanceFilterMeters: 0` теперь действительно значит «без фильтра».**
  `kCLDistanceFilterNone` — это `-1`, а ноль CoreLocation не определяет: на
  практике делегат просто замолкал. Конфигурация просила все фиксы подряд и
  получала тишину — худший вид расхождения платформ, потому что Android при
  тех же настройках работал. Ноль и меньше переводятся в константу.
* README получил раздел о том, как собрать конфигурацию под реальное время, и
  что это стоит по батарее, запросам и дрожанию неподвижного маркера.

## 0.8.0

* **`sendAfterPoints` отделён от `batchSize`.** Одно число отвечало на два
  вопроса — «когда уходит запрос» и «сколько точек он несёт», — и это делало
  свежесть неоплачиваемой: купить её можно было только вместе с крошечным
  запросом, а значит час офлайна уезжал ста восемьюдесятью round trip'ами и
  одного сбоя среди них хватало, чтобы положить очередь на бэкофф.

  ```dart
  GeoUploadConfig.standard(
    …,
    sendAfterPoints: 1,   // запрос уходит с каждой записанной точкой
    batchSize: 50,        // накопленное офлайн уезжает по пятьдесят
  )
  ```

  Ничего не ломается: `sendAfterPoints` по умолчанию равен `batchSize`, а
  нативные сторы читают старый ключ как фолбэк, так что конфигурация от прежней
  сборки ведёт себя ровно как вела.
* Обе платформы считают порог по новому полю, а размер запроса — по-прежнему по
  `batchSize`: воркер на Android вычерпывает очередь `while (true)`, iOS шлёт
  `oldest(batchSize)` в цикле, поэтому низкий порог не дробит бэклог.
* Статусная строка `waiting for a sweep — n/m` на iOS теперь показывает порог, а
  не размер батча: раньше она называла число, которое к решению уже не имело
  отношения.

## 0.7.0

* **Breaking: уведомление настраивается через `GeoNotificationConfig`.**
  `notificationTitle` и `notificationBody` уехали в новый объект рядом с
  `filter` и `motion`; `GeoUploadConfig.notification` обязателен и без
  умолчания, потому что половина его — пользовательский текст, а локали у
  пакета нет. Правка на стороне вызывающего:

  ```dart
  GeoUploadConfig.standard(
    url: …,
    headers: …,
    notification: GeoNotificationConfig.standard(
      title: 'Запись маршрута',
      body: 'Пишем ваш маршрут',
      channelName: 'Запись маршрута',
    ),
  )
  ```

  Ключи `notification_title` и `notification_body` на проводе не изменились, так
  что нативный стор от прежней сборки читается как был.
* **Иконка в статус-баре — хоста, а не Android.** `smallIcon` берёт имя
  drawable из ресурсов приложения; нативная сторона ищет его в `drawable`,
  потом в `mipmap`, и при промахе пишет `notification.icon` в лог и ставит
  системную. Не бросает: невалидный id роняет уведомление при публикации, а это
  уносит весь foreground-сервис.
* **Канал называется словами приложения.** `channelName` вместо зашитого
  английского «Location tracking», который до сих пор так и читался в системных
  настройках русского приложения. Переименование применяется на следующем
  `configure`; смена `importance` — нет, после создания канала его двигает
  только пользователь.
* **`importance`** — `low` (по умолчанию, без звука) или `normal`. Неизвестное
  имя читается как `low`: сессия идёт часами, и незнакомая строка не должна
  быть тем, из-за чего она начнёт звучать.
* **`tapOpensApp`** — нажатие открывает лаунчер-активити хоста. По умолчанию
  включено: постоянное уведомление, которое не реагирует на нажатие, читается
  как зависшее приложение.
* Не делается и не планируется: кнопки-действия, свой layout, largeIcon.
  Кнопку некому обслужить — Dart-изолята в этот момент нет.

## 0.6.0

* **Коллектор гасит GPS, когда устройство стоит.** Простояв
  `motion.stopTimeoutSeconds` внутри `motion.stationaryRadiusMeters`, сессия
  выключает location updates и вооружает два детектора — Activity Recognition
  (`CMMotionActivityManager` на iOS) и геозону вокруг якоря. Первый
  сработавший включает сбор обратно. До этого телефон, пролежавший на столе
  восемь часов, все восемь часов держал GPS: это было единственное отличие от
  референса, которое пользователь чувствует не читая логов.
* **`distanceFilterMeters` растёт со скоростью.** На 90 км/ч точка пишется раз
  в ~360 м вместо каждых 20, с потолком 500 м.
  `GeoMotionConfig(elasticityMultiplier: 0)` отключает растяжение — это
  «выключено», а не «фильтр в ноль метров», и эти два прочтения дают
  противоположный результат, поэтому ноль обрабатывается отдельной веткой до
  вычисления.
* **`GeoUploadConfig` получает обязательное поле `motion`.** `standard()`
  подставляет `GeoMotionConfig.standard()`, так что вызывающему коду менять
  нечего, если он не хочет других чисел.
* **Статус говорит, спит ли коллектор.** `GeoTrackingStatus.isMoving` и
  `motionPermission` — `granted` / `denied` / `unavailable`. Без них
  остановленный сбор выглядит как исправная сессия, у которой почему-то не
  меняется позиция; `unavailable` отделено от `denied`, потому что во втором
  случае разрешение можно спросить, а в первом спрашивать нечего.
* **Хостам:** iOS нужен ключ `NSMotionUsageDescription` в Info.plist — без него
  приложение падает при первом обращении к CoreMotion. Android объявляет
  `ACTIVITY_RECOGNITION` сам и спрашивает его при `start()`; отказ стоит
  задержки пробуждения (~200 м на геозоне), а не функциональности.
* Машина состояний работает только под `Always`: под `whenInUse` выключенный
  GPS будить некому, поэтому там коллектор ведёт себя как раньше. Растяжение
  фильтра работает на любой авторизации.

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
