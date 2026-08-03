# claude-code-wakeup

You give Claude Code a long task. You pick up your phone. Twenty minutes later you look
back at your laptop and it's been sitting on a permission prompt for nineteen of them.

This fixes that. When Claude Code needs you, it plays a video at you — fullscreen, with
sound — and stops the moment you touch the keyboard.

```
Claude needs permission  →  wait 10s  →  still not back?  →  🔊 VIDEO
                                      ↘  you're typing?   →  stays quiet
```

macOS only, for now. Idle detection uses `IOHIDSystem`.

## Install

```bash
git clone https://github.com/rafcopy/claude-code-wakeup.git
cd claude-code-wakeup
./install.sh          # or ./install.sh --project for this repo only
```

Then restart Claude Code — hooks are read when a session starts.

Needs `jq` and `ffplay` (`brew install jq ffmpeg`). Without `ffplay` it falls back to
QuickTime Player, which works fine and needs nothing installed.

Undo it any time with `./uninstall.sh`. Both scripts back up your `settings.json` first
and leave every other setting and hook alone.

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

The logic suite covers the away/at-the-desk split, event filtering, double-fire
deduplication, the sub-500ms hook budget, worker survival after the hook exits, and
malformed input.

## Troubleshooting

**Nothing happens.** Check `~/.claude/wakeup.log` — it records every decision, including
`skipped: you're here (idle 3s < 10s)`. If the log is empty, the hooks aren't installed:
`jq '.hooks' ~/.claude/settings.json` should show `wakeup.sh`, and you need to have
restarted Claude Code since installing.

**It fires while I'm working.** Raise `WAKEUP_IDLE_SECS`, or drop `stop` from
`WAKEUP_EVENTS`.

**No sound.** Set `WAKEUP_VOLUME=70` so it turns the volume up itself and puts it back
afterwards.

## License

MIT
