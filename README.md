# claude-code-wakeup-alarm

You give Claude Code a long task. You pick up your phone. Twenty minutes later you look
back at your laptop and it's been sitting on a permission prompt for nineteen of them.

This fixes that. When Claude Code needs you, it plays a video at you — fullscreen, with
sound — and stops the moment you touch the keyboard.

```
Claude needs permission  →  wait 10s  →  still not back?  →  🔊 VIDEO
                                      ↘  you're typing?   →  stays quiet
```

macOS and Windows are supported. Linux isn't yet — see
[Porting to Windows or Linux](#porting-to-windows-or-linux) if you want to change that.

## Install

### macOS

```bash
git clone https://github.com/rafcopy/claude-code-wakeup-alarm.git
cd claude-code-wakeup-alarm
./install.sh          # or ./install.sh --project for this repo only
```

Needs `jq` and `ffplay` (`brew install jq ffmpeg`). Without `ffplay` it falls back to
QuickTime Player, which works fine and needs nothing installed.

Undo it any time with `./uninstall.sh`.

### Windows

```powershell
git clone https://github.com/rafcopy/claude-code-wakeup-alarm.git
cd claude-code-wakeup-alarm
.\install.ps1          # or .\install.ps1 -Project for this repo only
```

No dependencies required — `ConvertFrom-Json` and `GetLastInputInfo` (idle detection)
are both built in. If `ffplay` is on your `PATH` (`winget install ffmpeg` or
`scoop install ffmpeg`) it's used for playback; otherwise it falls back to a borderless
WPF window (`lib\wpf-player.ps1`), which needs nothing installed either.

Undo it any time with `.\uninstall.ps1`. Both `.ps1` scripts also strip any `wakeup.sh`
entry, so switching between the bash and PowerShell install on the same machine is safe.

`WAKEUP_VOLUME` is currently a documented no-op on Windows (see the Porting table below)
— everything else in [Configuration](#configuration) behaves identically on both platforms,
reading the same `config.env`.

---

Then restart Claude Code — hooks are read when a session starts.

Both platforms' scripts back up your `settings.json` first and leave every other setting
and hook alone.

## When it wakes you

| Event | What happened |
|---|---|
| `permission_prompt` | Claude is blocked waiting for you to approve a tool |
| `idle_prompt` | Claude Code's own "still there?" nudge |
| `agent_needs_input` | Claude is asking you a question mid-task |
| `agent_completed` | A background agent finished |
| `stop` | Claude finished responding |

Every one of them goes through the same gate: **wait a bit, and only shout if you're
actually gone.** If you're sitting there typing, nothing happens — you'll never hear the
video during normal back-and-forth work.

## Configuration

Everything lives in [`config.env`](config.env). Edit it, save, restart Claude Code.

| Setting | Default | What it does |
|---|---|---|
| `WAKEUP_DELAY_SECS` | `10` | Grace period after Claude asks for you |
| `WAKEUP_IDLE_SECS` | `10` | Only fire if you've been away at least this long |
| `WAKEUP_EVENTS` | all five | Which moments arm the alarm |
| `WAKEUP_VIDEO` | *(empty)* | A specific clip; empty picks a random one from `media/` |
| `WAKEUP_PLAYER` | `ffplay` | `ffplay` or `quicktime` |
| `WAKEUP_VOLUME` | *(empty)* | Force system volume 0–100 while playing, then restore it |
| `WAKEUP_LOOP` | `0` | `1` replays until you come back |
| `WAKEUP_MAX_SECS` | `120` | Hard cap on playback |
| `WAKEUP_RETURN_SECS` | `2` | Idle below this means you're back, so cut the alarm |
| `WAKEUP_LOG` | `~/.claude/wakeup.log` | Where decisions get logged |

Want it to only fire when you're really gone? `WAKEUP_IDLE_SECS=45`.
Want to be woken only when work is *done*, not for permission prompts?
`WAKEUP_EVENTS="stop"`.

### Your own videos

Drop any `.mp4` or `.mov` into `media/`. With more than one in there, each alarm picks
one at random.

## How it works

`wakeup.sh` is the hook Claude Code calls. It reads the event JSON on stdin, decides
whether it's one you care about, spawns a detached worker, and exits — in about 45ms.
It never blocks your session and never exits non-zero, so a broken config or a missing
video can't get in the way of your work.

`lib/play.sh` is the worker. It takes an atomic lock (a permission prompt and a Stop
landing seconds apart should be one alarm, not two), waits out the grace period, checks
how long you've really been idle, plays, then watches idle time once a second so it can
kill the player the instant you're back.

## Tests

```bash
./tests/run-tests.sh      # logic only — fakes idle time, plays nothing, safe any time
./tests/live-test.sh      # really plays the video, then proves it stops when you return
./tests/live-test.sh --real   # no faking: walk away and see if it catches you
```

```powershell
.\tests\run-tests.ps1
.\tests\live-test.ps1
.\tests\live-test.ps1 -Real
```

The logic suite covers the away/at-the-desk split, event filtering, double-fire
deduplication, the hook speed budget (sub-500ms on macOS; the PowerShell suite loosens
this to 1.5s since `powershell.exe` startup itself takes longer than the whole bash
hook), worker survival after the hook exits, and malformed input.

## Troubleshooting

**Nothing happens.** Check `~/.claude/wakeup.log` — it records every decision, including
`skipped: you're here (idle 3s < 10s)`. If the log is empty, the hooks aren't installed:
`jq '.hooks' ~/.claude/settings.json` should show `wakeup.sh`, and you need to have
restarted Claude Code since installing.

**It fires while I'm working.** Raise `WAKEUP_IDLE_SECS`, or drop `stop` from
`WAKEUP_EVENTS`.

**No sound.** Set `WAKEUP_VOLUME=70` so it turns the volume up itself and puts it back
afterwards.

## Porting to Windows or Linux

Windows has a native PowerShell twin now (`wakeup.ps1`, `lib\common.ps1`, `lib\play.ps1`,
`lib\wpf-player.ps1`, `install.ps1`, `uninstall.ps1`) — no Git Bash dependency, built the
way the table below originally called for. Linux is the one still open; PRs welcome.

| Piece | What macOS uses | Windows (implemented) | Linux (still open) |
|---|---|---|---|
| Idle detection | `ioreg -c IOHIDSystem` (`lib/common.sh`) | `GetLastInputInfo` from `user32.dll` via a small inline C# `Add-Type` in `lib\common.ps1` — no dependencies | `xprintidle` on X11; Wayland has no portable equivalent and is the real blocker |
| Playback | `ffplay -fs -autoexit` | Same — used automatically when `ffplay` is on `PATH` | `ffplay` already runs everywhere |
| Fallback player | QuickTime via `osascript` | A WPF `MediaElement` window (`lib\wpf-player.ps1`, fullscreen + topmost, ~30 lines), run as its own process so it's trackable/killable by PID like `ffplay` | `mpv --fs` |
| Volume | `osascript set volume` | Documented no-op (`WAKEUP_VOLUME` set but not applied) — no clean restore-safe API without a COM interop dependency | `pactl set-sink-volume` |
| Detaching the worker | `nohup … &` (`wakeup.sh`) | `Start-Process -WindowStyle Hidden` (`wakeup.ps1`). The lock directory (`New-Item -ItemType Directory`) is atomic on NTFS too, so that logic carries over unchanged | — |
| JSON parsing | `jq` | `ConvertFrom-Json`, built into PowerShell — no dependency | — |

Everything else — the grace period, the idle gate, the atomic lock, event filtering, the
config — is already OS-agnostic, and the Windows port reads the same `config.env`.

On the Claude Code side: the Windows hook entry runs `powershell.exe -NoProfile
-ExecutionPolicy Bypass -File wakeup.ps1` directly as its `command`, rather than relying
on Git Bash — a `.ps1` invoked through Git Bash would force a dependency *and* make the
once-per-second idle check spawn `powershell.exe` every tick.

Whatever the platform, `WAKEUP_IDLE_OVERRIDE` and `WAKEUP_IDLE_OVERRIDE_FILE` (see
`Get-IdleSecs` in `lib\common.ps1` / `idle_secs` in `lib/common.sh`) are the seams that
let the whole flow be tested without touching real idle time — both `run-tests.sh` and
`run-tests.ps1` are built on them.

## License

MIT
