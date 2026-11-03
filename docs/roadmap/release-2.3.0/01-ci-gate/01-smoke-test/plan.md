---
kind: task
status: done
detailed: true
---

# Replace the counter template with a start-screen smoke test

## Task

`test/widget_test.dart` is the Flutter template's counter test: it pumps
`MyApp` and looks for the texts `0` and `1` and for `Icons.add`. `lib/main.dart`
defines no `MyApp` and the app has no counter, so the file does not compile
and `flutter test` over the whole tree fails. That is the one error of the
analyzer baseline and the reason `ci.yml:54-56` and `release.yml:53-55` run
three test files by name.

Replace it with a widget test of the app's own start screen, as designed in
`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.3. The workflows change in
`03-full-dart-suite`, not here.

## Steps

1. Write `test/app_smoke_test.dart` with one `testWidgets` that pumps
   `ChangeNotifierProvider(create: (_) => AppState(), child: const DnsttClientApp())`
   (`package:dnstt_xyz_app/main.dart`, `.../providers/app_state.dart`,
   `package:provider/provider.dart`).
   Do not call `AppState.init()` and do not use `StorageService`: the fields
   the start screen reads are initialised in their declarations
   (`lib/providers/app_state.dart:13-33`) and the getters do not touch storage
   (`:35-54`), so `SharedPreferences` needs no mock.
2. Assert what the empty state shows, in `lib/screens/home_screen.dart`:
   - the app bar title `DNSTT.XYZ` (`:63`);
   - the status `Disconnected` (`:219-224`);
   - the placeholders `No config selected` (`:411`) and `No DNS selected`
     (`:432`), and the hint `Select a config and DNS server to connect`
     (`:436-446`);
   - the menu cards `Configs` (`:591`), `DNS Servers` (`:602`), `Settings`
     (`:615`);
   - the power icon `Icons.power_settings_new` (`:271`).
3. Tap the power icon, `pump()`, and expect the status to stay `Disconnected`:
   without a config and a DNS server the tap does nothing (`:234-242`).
4. Assert nothing that depends on the test host. `HomeScreen.initState` calls
   `VpnService().init()` (`:30`). On a desktop host it tries to load `libdnstt`
   and catches the failure (`lib/services/vpn_service.dart:101-110`); on
   Android-only paths the mode toggle (`home_screen.dart:449`) stays hidden.
   Do not mock platform channels unless the run shows that one is called.
5. Keep one widget test in the file. `VpnService` is a process-wide singleton
   with a one-shot `_initialized` flag (`vpn_service.dart:21-23`, `:95-97`), so
   a second test would not get a fresh start.
6. Delete `test/widget_test.dart` and run `flutter test` with no arguments: all
   four files must pass.
7. Make one expectation false, see the run fail, restore it.
8. `flutter test` runs `pub get`, which can rewrite
   `linux/flutter/generated_plugins.cmake` and
   `windows/flutter/generated_plugins.cmake`: revert them (`CLAUDE.md`).

## Done when

- `test/app_smoke_test.dart` pumps `DnsttClientApp` under an `AppState`
  provider and asserts the title, `Disconnected`, both placeholders, the hint,
  the three menu titles and the power icon; a tap on the icon leaves the status
  `Disconnected`.
- `test/widget_test.dart` is gone.
- `flutter test` with no arguments passes all four test files.
- A deliberately false expectation in the new test fails the run.
- Outside the map, the task's diff touches only `test/`.

## Risks and what is needed from the user

Nothing is needed from the user. The test has not been tried yet: the plan
comes from reading the code. If the start screen overflows in the default
800x600 test window or calls a platform channel, set the window size or add
the mock in the test; do not change `lib/` to make the test pass.

## Outcome

Done as planned. `test/widget_test.dart` is gone; `test/app_smoke_test.dart`
holds one `testWidgets` that pumps `DnsttClientApp` under an `AppState`
provider, asserts the empty start screen and taps the power icon.

- `flutter test` with no arguments: 75 tests in four files pass (before: 74
  and a compile error in `widget_test.dart`).
- A false expectation (`No DNS selected` with `findsNothing`) fails the run.
  The review also broke the screen on purpose: a renamed placeholder, a tap
  that sets `connecting`, a tap that calls `_connect` without a config — the
  test fails on each.
- The default 800x600 test window needs no size override: the screen is a
  `SingleChildScrollView`, nothing overflows, and finders reach the menu cards
  below the fold.
- No platform channel is called. On a desktop host `VpnService.init()` takes
  the FFI branch and catches the missing `libdnstt`; the run prints
  `Failed to load dnstt library: …` twice (`dnstt_ffi_service.dart` and
  `vpn_service.dart` both print it). No mock is needed.
- `flutter analyze` after the change: 109 issues, no errors (108 infos, one
  warning), none in `test/`. Input for `02-analyzer-baseline`.
- Left for later nodes: `ci.yml` and `release.yml` still list three test files
  and carry the "stale test" comment (`03-full-dart-suite`); `CLAUDE.md` still
  mentions the stale file in "Run the tests" (`07-describe-the-gate`).
- Noticed, not in this map: `HomeScreen` subscribes to `VpnService.stateStream`
  in `initState` and never cancels the subscription (it has no `dispose`).
