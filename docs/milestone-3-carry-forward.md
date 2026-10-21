# Carried forward into milestone 3

Milestones 1-2 (`DisplayCore` + `displayctl`) are complete: 112 tests, seven scoped reviews and
one whole-branch review. These are the things those reviews found and deliberately did not fix
here. Read this before starting the menu bar app.

## 1. `RevertCoordinator` is correct but defenceless — fix this first

It is deliberately not `Sendable` and documents a single-execution-context obligation, while
`PendingChange` — the token every entry point takes — is `public` and `Sendable` and travels
freely across threads. `displayctl` honours the contract only because `runSet` is single-threaded
start to finish.

Milestone 3 breaks that by construction. A countdown panel ticking `expireIfNeeded` on a timer, a
Keep/Revert button on the main actor, and a display-reconfiguration notification arriving on a
CoreGraphics callback thread are three drivers of one unsynchronised `Set<Int>`. The failure mode
is a revert that silently does not fire because a concurrent write lost the insert — which is the
exact failure the product exists to prevent.

**Make it an actor or a `@MainActor` type before the first timer is attached, not after.**

## 2. A killed process leaves the screen changed

If `displayctl` is killed mid-window — Ctrl-C, terminal closed, crash — nothing reverts, and the
session-scoped mode persists until logout. Neither the plan nor any review caught this until late.
The menu bar app needs the panic hotkey (spec §8.3) and should consider a crash-safe path, since
an app that dies mid-countdown has the same hole.

## 3. `expireIfNeeded` and `secondsRemaining` have never run

Both are well tested and have **no caller** on this branch — `runSet` drives the revert entirely
off `awaitConfirmation` returning, which is legitimate because the semaphore wait is bounded. So
the poll API ships unexercised end to end. Do not assume it is field-proven.

## 4. `restore` cannot undo `--permanent`

`CGRestorePermanentDisplayConfiguration` restores the *permanent* configuration, and a confirmed
`--permanent` change is that configuration. The help text is honest about this now, but the
milestone-3 panic hotkey inherits the same limitation from spec §8.3. Decide what the hotkey does
about a permanent change before shipping it.

## 5. There is no main-display concept

`displayctl set` with no `--display` targets `ids.first` from `CGGetOnlineDisplayList`, and
`CGMainDisplayID` appears nowhere in the tree. The online list also includes inactive and mirrored
targets. The help now says "display 1, as shown by `list`" rather than "the main display", which is
true but is not what a menu bar app wants. Widening `DisplayEnumerating` with a main-display query
is milestone-3-shaped work.

## 6. Small open residuals

- `revertOrThrowRevertFailure` catches only `DisplayError`. Every current throw site is one, so a
  non-`DisplayError` falling through to the generic handler is unreachable today — but `apply` is
  untyped `throws`, so it will not stay unreachable forever.
- User-facing strings have drifted outside `Rendering.swift` on the CLI side: `helpText` and two
  display errors live in `Commands.swift`, the whole report in `Doctor.swift`, every `ParseError`
  in `ArgumentParsing.swift`. `DisplayCore` is clean, so the binding constraint holds, but the
  CLI-side convention no longer does.
- `resolveDisplay` throws `ParseError` for runtime conditions ("no displays are connected"), which
  is not a parse failure. Cosmetic — both types exit 1 through the same path.
- `Confirmation` collides by name with swift-testing's own `Confirmation` in test files. Ruled not
  worth renaming public API; there is a warning comment at the top of `SetCommandTests.swift`.

## 7. Manual hardware verification is owed

Nothing on this branch has been run against a real display. Every review and every implementer was
explicitly forbidden from applying a mode, because the machine's owner was not at the keyboard.

### Partly paid, 2026-10-21 — read path only

The first real hardware verification this project has had. Installed build 1.1.0, commit
`352891e`, two displays attached: `7789:23305:79350` and `19501:57513:0` (serial field zero, so
tier 2 cannot separate it on its own).

`~/Library/Application Support/Pitch/presets.json`, written 2026-09-14 by the build at `439af52`,
loaded cleanly under a build that no longer knows the `lastSeenName` key it still contains. After a
relaunch the recent-resolution dot rendered on both displays. One observation, four facts:

- an old-format file decoded despite two keys this version does not declare;
- `CGDisplayCreateUUIDFromDisplayID` returned the same UUIDs it had returned a month earlier;
- the tier walk matched both live displays to their stored entries, including the serial-`0` one;
- `isReadOnly` is false, so writes are armed — the silent-failure path would have shown no dots at
  all rather than wrong ones, which is exactly why the dots are the signal worth watching.

**Mode application is still entirely unverified.** The confirm-or-revert countdown — items 1-7
below, and the property the whole product rests on — has never been observed on hardware. Nothing
above touches it: recording a recent happens on *selection*, before the countdown resolves either
way.

Run these by hand, one at a time, while watching the screen, with a phone or a second machine ready
in case a mode leaves the display unreadable. `displayctl restore` is the escape hatch and can be
typed blind.

Read-only first:

```bash
swift build --build-system native
.build/debug/displayctl list                 # every display and mode appears
.build/debug/displayctl list --all --json    # the JSON parses
.build/debug/displayctl doctor               # the HiDPI mode count is NOT 0
```

A doctor report showing 0 HiDPI modes means the §4.1 options-dictionary key regressed — stop there.

Then the write path, which actually changes the screen:

1. `displayctl set <a resolution list showed>` — answer `y`. The mode should stick.
2. Repeat, answer `n`. The old mode should come straight back.
3. Repeat, and **type nothing**. After 15s it should revert on its own. This is the property the
   whole product rests on, and it has never been observed.
4. Repeat, and press Enter without typing anything. It must revert — bare Enter declines. This was
   a real bug (it used to confirm) and the fix has only ever been verified in tests.
5. `displayctl restore` — every display back to the system's saved configuration.
6. With two displays attached, repeat 1-3 with `--display 2` and confirm the *other* screen changed.
7. `displayctl set <resolution> --permanent`, confirm, log out and back in, check it survived. Note
   that `restore` will not undo this one — see item 4 above.

## 8. Brightness hardware verification is owed (spec §18)

Everything under §18 is tested against fakes only. No real gamma, DisplayServices or DDC write has
ever been issued by Pitch, and nothing on the development machine could have exercised the Apple
backend: its only display was asleep, and a DDC read spike returned `FA`×12 with Vorssaint holding
the same service. Treat each line below as unobserved.

**A write changes the screen, and a DDC write persists in the monitor after Pitch exits.** Do these
with someone at the keyboard, a known-good brightness to return to, and the monitor's own OSD within
reach. `displayctl brightness list|get` and `displayctl doctor` only probe and read, so start there:

```bash
.build/debug/displayctl brightness list     # each display names a method; a built-in is not "gamma"
.build/debug/displayctl brightness get      # readable displays report a level; write-only ones say so
.build/debug/displayctl doctor              # the Brightness section agrees with the two above
```

Then, one backend at a time, `displayctl brightness set <level> [--display N]` and watch the panel:

1. **Apple panel (DisplayServices).** The backlight itself moves. The slider's floor is 5%, not 0.
2. **DDC monitor.** Quit Vorssaint and any other DDC tool first — two owners of the service fight.
   The backlight moves, the floor is 5%, and the level survives quitting Pitch (that is the monitor
   holding it, not Pitch). Record what the monitor replies when it is awake: this is the unresolved
   `FA`×12 question, and it decides whether the row is readable or write-only.
3. **Gamma.** Use a display with neither of the above. The row reads "Dimming", the tooltip says it
   does not deepen blacks, and the floor is 20% — at 0 the screen would be unreadable.
4. **Read-back offset and settle.** On a DDC display, set a level, wait, `brightness get`. The
   value should match within a step. If it lags, the settle delay is too short; if it is off by a
   constant, the read offset is wrong.

Slider behaviour in the panel:

5. A fast drag ends on the value the pointer stopped at, however slow the monitor is (latest wins).
6. Two displays move independently; dragging one never moves the other.
7. A write-only DDC monitor shows its last-set level after relaunch, and Pitch does **not** reapply
   it on launch or wake (§18.3).
8. A failing display shows a disabled row with an explanatory tooltip and no alert. Unplug it
   mid-drag to provoke this.
9. Dock/undock, and sleep/wake: rows reappear within about a second, on the right display, with no
   stale level from the monitor that used to hold that ID.
10. Changing resolution on a dimmed display resets software dimming (the reconfiguration restores
    the system colour tables); the slider should return to full rather than lie.
11. Quit Pitch while dimmed with gamma: the screen returns to normal. `kill -9` it instead: gamma
    is released by the OS when the process dies, and DDC/Apple levels stay where they were. Confirm
    both, since only the first is Pitch's doing.
12. Another tool's colour adjustment (Night Shift, a calibrated profile) survives a quit when Pitch
    never dimmed anything — the guarded `shutDown` should not touch it.
