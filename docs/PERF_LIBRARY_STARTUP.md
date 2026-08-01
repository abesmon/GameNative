# Library startup performance investigation

Status: findings recorded, fixes landing incrementally.
Measured 2026-08-01 on a Nintendo Switch (`odin`, Android 15 / SDK 35, Tegra), Steam library of
497 apps, `debug` build installed over ADB.

The goal of this document is to let anyone pick up one item and fix it in isolation. Each finding
lists the evidence, the exact code location, and what a minimal fix looks like.

---

## 1. Measurements

Clean run: `am force-stop` → `logcat -c` → `am start`. Device-wide `log.tag=I` suppresses `Log.d`,
so Timber debug output is invisible by default — enable it first:

```bash
adb shell setprop log.tag.LibraryViewModel V
adb shell setprop log.tag.LibraryListPane V
```

| Event | Time from launch |
| --- | --- |
| First frame (`ActivityTaskManager: Displayed`) | **9.2 s** |
| Catalogue rendered (1st time) | ~14 s |
| Catalogue blanks, second load starts | ~21 s |
| Catalogue rendered (2nd time) | ~25 s |
| Skipped frames over a 190 s window | **1354 (≈22.5 s of frozen UI)**, worst bursts 366 and 254 |
| GC cycles | 12, freeing 6–17 MB each; heap 18 → 48 MB |

Supporting log lines:

```
I ActivityTaskManager: Displayed app.gamenative/.MainActivity for user 0: +9s221ms
I Choreographer: Skipped 366 frames!  The application may be doing too much work on its main thread.
I app.gamenative: Compiler allocated 5267KB to compile
    app.gamenative.ui.model.LibraryViewModel$onFilterApps$1.invokeSuspend(java.lang.Object)
I SQLiteConnection: Long db operation: /data/user/0/app.gamenative/databases/pluvia.db
```

A 5 MB JIT allocation for a single method — emitted twice — is a direct signal that
`onFilterApps` is both enormous and very hot.

---

## 2. Finding A — the library is genuinely built twice (highest cost)

**Cost: ~10–12 s of the startup path.**

`startDestination` resolves to `Home?offline=true` when Steam credentials exist but the session is
not logged on yet ([`PluviaMain.kt:1300`](../app/src/main/java/app/gamenative/ui/PluviaMain.kt#L1300)).
About 15 s later `LogonEnded` arrives and the handler navigates to `Home?offline=false` with
`popUpTo(..., inclusive = true)`
([`PluviaMain.kt:561`](../app/src/main/java/app/gamenative/ui/PluviaMain.kt#L561)).

That pops the old `NavBackStackEntry`, which destroys its `ViewModelStore`, which destroys
`LibraryViewModel` — along with every Room collector it owns. Everything is rebuilt from scratch.

Evidence — `isFirstLoad: true` appears twice, from two distinct VM instances:

```
14:37:52 D LibraryViewModel: onFilterApps - appList.size: 0, isFirstLoad: true   <- VM #1
14:37:57 D LibraryViewModel: onFilterApps - appList.size: 497, isFirstLoad: false
14:37:59 D LibraryViewModel: Filtered list size (with Custom Games): 179          <- catalogue shown
14:38:06 I PluviaMainKt$PluviaMain: onDestinationChanged to home?offline={offline}
14:38:07 D LibraryViewModel: Retrieved GPU name: NVIDIA Tegra                     <- VM #2 constructed
14:38:07 D LibraryViewModel: onFilterApps - appList.size: 0, isFirstLoad: true
14:38:10 D LibraryViewModel: Filtered list size (with Custom Games): 179
```

`Collecting 497 apps` and `Collecting 0 GOG games` each appear exactly twice — two full sets of
collectors.

**Key insight:** the `offline` flag does not gate library *data*. It is threaded down to
`HomeScreen`/`LibraryScreen` purely as a UI + launch-mode boolean. Fresh data after login arrives
independently through `SteamService` → licenses/PICS → Room → the DAO `Flow`s that
`LibraryViewModel` already collects. The re-navigation buys nothing data-wise; it only pays for a
teardown and rebuild.

The one thing the rebuild does accidentally provide: `onFilterApps` reads
`SteamService.familyMembers` and `PrefManager.steamUserAccountId`, which are only populated after
login and have no flow behind them. A minimal fix therefore has two parts — make `offline`
reactive instead of navigational, and add one explicit cheap re-filter once ownership is known.

### Gotcha: family share settles later than `LogonEnded`

A first attempt hung the re-filter off `SteamEvent.LogonEnded` and silently dropped 20 games
(179 → 159). `familyGroupMembers` is filled by a *separate* coroutine doing a `getFamilyGroup`
network round-trip ([`SteamService.kt:3763`](../app/src/main/java/app/gamenative/service/SteamService.kt#L3763)),
which lands several seconds after `LogonEnded`. A re-filter fired at `LogonEnded` therefore sees an
empty `familyMembers`, falls back to `listOf(userSteamId)` and hides everything owned by the other
family member. The old re-navigation happened ~6 s after logon and accidentally landed on the right
side of that race.

The fix emits `AndroidEvent.LibraryOwnershipResolved` when the family-group job completes (via
`invokeOnCompletion`, so failures still fire it) and immediately when the account has no family
group. Anything that re-filters on login must hang off that, not off `LogonEnded`.

### Status: fixed

`AndroidEvent.LibraryOwnershipResolved` + reactive `offline` flag. Verified on device:

| | before | after |
| --- | --- | --- |
| `LibraryViewModel` instances per cold start | 2 | 1 |
| Launch → catalogue settled | ~25 s | ~12 s |
| Skipped frames in the first 40 s | 1354 (~22.6 s) | 874 (~14.6 s) |
| Filtered app count after login | 179 | 179 (unchanged) |

GC pressure is essentially unchanged (11 → 10 cycles) — that is Finding D's territory.

---

## 3. Finding B — `onFilterApps` is not conflated; stale passes overwrite fresh results

[`LibraryViewModel.kt:566`](../app/src/main/java/app/gamenative/ui/model/LibraryViewModel.kt#L566)

There are 24 call sites. Each one does its own fire-and-forget
`viewModelScope.launch(Dispatchers.IO)` with no cancellation of the previous pass, so the winner is
whichever coroutine *finishes* last — not the one that started last. A pass that began while
`appList` was still empty can land after a pass that had all 497 apps and blank the list.

This is not hypothetical. In the captured run a stale empty pass persisted zeroes:

```
14:38:08 D LibraryViewModel: Saved counts - Custom: 0, Steam: 0, GOG: 0, ...
```

`PrefManager.steamGamesCount` is written from inside the filter pass
([`LibraryViewModel.kt:862`](../app/src/main/java/app/gamenative/ui/model/LibraryViewModel.kt#L862)),
so an empty pass corrupts the skeleton-loader counts for the *next* cold start too (skeleton falls
back to 6 placeholders instead of ~179).

`_state.update { it.copy(isLoading = true) }` at the head of every pass also makes the skeleton
overlay flicker over an already-populated list
([`LibraryListPane.kt:209`](../app/src/main/java/app/gamenative/ui/screen/library/components/LibraryListPane.kt#L209)).

**Minimal fix:** funnel all triggers through a single
`MutableSharedFlow(extraBufferCapacity = 1, onBufferOverflow = DROP_OLDEST)` collected with
`mapLatest`, plus a ~100 ms debounce. Guard the `PrefManager.*Count` writes on a non-empty
`appList`.

---

## 4. Finding C — one filter pass costs ~2 s for 497 apps

From the log: pass start 14:37:57 → result 14:37:59, and 14:38:08 → 14:38:10.

Per-item work inside the pass:

- **Depot resolution for every app just to compute a size.**
  `SteamService.buildLicensedDepotMap` + `resolveDownloadableDepots` run for all 497 filtered apps
  ([`LibraryViewModel.kt:670`](../app/src/main/java/app/gamenative/ui/model/LibraryViewModel.kt#L670))
  only to fill `LibraryItem.sizeBytes`. `buildLicensedDepotMap` additionally does `runBlocking`
  ([`SteamService.kt:612`](../app/src/main/java/app/gamenative/service/SteamService.kt#L612)).
- **A blocking DB round-trip per installed app.**
  `SteamService.getInstalledApp(item.id)` is `runBlocking`
  ([`SteamService.kt:661`](../app/src/main/java/app/gamenative/service/SteamService.kt#L661)) and is
  called inside the `map` over installed entries.
- **`getAppDirName(it)` is called from inside the sort comparator**
  ([`LibraryViewModel.kt:659`](../app/src/main/java/app/gamenative/ui/model/LibraryViewModel.kt#L659)),
  making it O(n log n) instead of O(n).

**Minimal fixes:** compute `sizeBytes` lazily (only when a size sort is active) or cache it by
`appId + branch`; fetch installed apps once into a `Map<Int, AppInfo>`; precompute the directory
name once per item before sorting.

---

## 5. Finding D — every emission reloads all rows and re-parses JSON blobs

[`SteamAppDao.kt:116`](../app/src/main/java/app/gamenative/db/dao/SteamAppDao.kt#L116)

`getAllOwnedApps` observes `COUNT(*)` and, on any change, re-runs `SELECT *` for all owned rows.
`OWNED_APPS_WHERE` references `steam_license`, so Room invalidates the query on license writes too —
and login inserts a batch:

```
14:38:00 I SteamService: Received License List OK, size: 223
14:38:00 I SteamService$onLicenseList: Adding 208 licenses
```

Each reload materialises 497 `SteamApp` rows including the `depots` blob (≈600 KB of JSON across the
table, largest single row 27 KB), decoded with kotlinx-serialization per row
([`AppConverter.kt:44`](../app/src/main/java/app/gamenative/db/converters/AppConverter.kt#L44)).
That is the source of the GC storm and of `SQLiteConnection: Long db operation`.

Measured on-device:

```
$ adb shell "run-as app.gamenative sqlite3 databases/pluvia.db \
    'select count(*), sum(length(depots)), max(length(depots)) from steam_app where type!=0'"
510|597988|27035
```

**Minimal fix:** give the list query a projection into a light POJO (id, name, type, package_id,
owner_account_id, install_dir, icon hashes) instead of the full entity. That removes the JSON decode
*and* obsoletes the paging workaround that exists only to dodge
`SQLiteBlobTooBigException`
([`SteamAppDao.kt:86`](../app/src/main/java/app/gamenative/db/dao/SteamAppDao.kt#L86)).

---

## 6. Finding E — the installed build has no compiled code at all

```
$ adb shell dumpsys package dexopt | grep -A3 app.gamenative
  [app.gamenative]
    arm64: [status=run-from-apk] [reason=unknown] [primary-abi]
        [location is error]
```

`status=run-from-apk`, no `base.dm`, and `Late-enabling -Xcheck:jni` in the log. Every class is
verified at runtime and every method interpreted until JIT catches up. This is a multiplier on top
of every other finding, and it explains the "works better after a couple of restarts" symptom — the
JIT profile accumulates across launches.

**Implications for anyone measuring:**

- Benchmark on `release` / `release-signed`, not `debug`.
- If a debug build must be measured, force compilation after install:
  ```bash
  adb shell cmd package compile -m speed -f app.gamenative
  ```
- For release builds, wire up a baseline profile (`androidx.profileinstaller` + Macrobenchmark) so
  `base.dm` is not empty.

---

## 7. Lower-priority observations

- **Cold start is 9.2 s to first frame.** `PluviaApp.onCreate` synchronously runs PostHog setup,
  `PlayIntegrity.warmUp`, an external-volume scan in `DownloadService.populateDownloadService`, and
  `PrefManager.init` — whose getters are `runBlocking { dataStore.data.first() }`
  ([`PrefManager.kt:124`](../app/src/main/java/app/gamenative/PrefManager.kt#L124)). `LibraryState`'s
  default constructor alone reads ~10 preferences during composition.
- **`isFirstLoad`** in `LibraryViewModel` is documented as applying a minimum load time but no delay
  is ever applied — it only gates a log line.
- **`getGridImageUrl` does `File.listFiles()` during composition**
  ([`LibraryGridCard.kt:579`](../app/src/main/java/app/gamenative/ui/screen/library/components/LibraryGridCard.kt#L579)),
  but only on the `CUSTOM_GAME` branch, so it does not affect Steam-only libraries.

---

## 8. Suggested order of work

Ordered so each step is independently reviewable and mergeable.

| # | Item | Finding | Expected effect |
| --- | --- | --- | --- |
| A | ~~Make `offline` reactive; drop the post-login re-navigation~~ **done** | §2 | removed the entire second build (~13 s) |
| B | Conflate `onFilterApps`; guard count persistence | §3 | stops the catalogue blanking and the skeleton flicker |
| C | Lazy `sizeBytes`, batched installed-app lookup, precomputed dir names | §4 | ~2 s → a few hundred ms per pass |
| D | Projection query for the library list | §5 | removes the JSON decode and the GC storm |
| E | Measure on release / force dexopt / baseline profile | §6 | multiplier on everything above |

### Working agreement

This branch is an **accumulator**. Every stage lands as its own commit, and each commit must stand
on its own — it must make sense and work without any later commit. Verbose comments and extended
documentation (including this file) are welcome here; they record why a change looks the way it
does while the work is still in flight.

The upstream PRs are cut later, as **separate branches carrying code only** — no explanatory
comments, no docs. Write each fix so that stripping the commentary leaves working, reviewable code:
never put load-bearing information in a comment, and keep the code diff itself as small as the fix
allows. Small self-contained diffs are what gets merged.
