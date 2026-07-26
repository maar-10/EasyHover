# EasyHover — music module: exactly what it needs

Scoped to a late phase. This document exists so the requirements are unambiguous before any
work starts.

## What CC:Tweaked can and cannot do

| | |
|---|---|
| `speaker.playAudio(buffer)` | Plays **raw 8-bit signed PCM**, 48 kHz mono, 128 KiB max per call, fed continuously. |
| `cc.audio.dfpwm` | Vanilla CC module that **decodes** DFPWM to that PCM. |
| `http.get` / `http.request` | Vanilla. Can fetch bytes and parse JSON (`textutils.unserialiseJSON`). |
| **Transcoding** | **Impossible in CC.** No ffmpeg, no codecs, and YouTube does not serve DFPWM. |
| **YouTube search** | Needs the YouTube Data API (key) or HTML scraping. CC can do the *HTTP* part, but not usefully the scraping. |

So the shape is forced: **an external service does search + transcode; the computer is a thin
client that streams DFPWM chunks, decodes them, and feeds the speaker.** Your existing program
almost certainly does exactly this — "no extra mods" is true (CC's `http` is vanilla), but there
will be a server involved. That is why my dependency call stands.

## What we need, concretely

1. **A search + transcode service.** Three ways to get one:
   - **Public instance** of a YouCube-style server — zero setup, but you depend on someone
     else's uptime and it can vanish.
   - **Self-hosted** (recommended) — Docker, exactly the workflow you already run for Firecrawl.
     Yours forever, no rate limits, works offline from the internet's opinion of you.
   - **Our own minimal service** — `yt-dlp` + `ffmpeg` + a tiny HTTP wrapper returning DFPWM.
     ~100 lines. Most control, most maintenance.
2. **`http_enable = true`** in the server's CC config, and the service's host in the
   **HTTP whitelist** (`http.rules`). If the service is on your LAN, note CC blocks private IP
   ranges by default — that rule has to be relaxed for a self-hosted box.
3. **Its own computer**, adjacent or networked **speaker**, and a monitor. Audio streaming is
   continuous work; it never shares hardware with the flight computer.

## What we build (the part that's actually ours)

The client, and making it not clunky:

- Basalt 2.0 search screen — query, results list, one-click queue.
- Playlists persisted to disk, import/export via floppy.
- Queue with skip / previous / repeat / shuffle, seek if the service supports it.
- Volume + independent mute, and a **ducking hook**: the annunciator tells the music computer to
  duck or mute when a flight alarm fires. Alarms must never be drowned out by the stereo.
- Now-playing readout available to the other UIs over `eh_music`.

## Next step for this module

Point me at the existing program (path on the computer, or its name/URL) and I'll read it. That
tells us which backend it uses, and if it's a sane one we reuse it and simply put a much better
client on top — no new infrastructure at all.
