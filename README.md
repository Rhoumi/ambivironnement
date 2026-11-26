# Ambivironnement

A spatialisation tool designed for [Cagire](https://cagi.re): it places Cagire's sound in a
higher-order ambisonic field (HOA, order 3) and plays it on any speaker layout or on headphones,
with a low-resolution 3D view of what is happening.

It listens to two things from Cagire: its audio (through JACK / PipeWire) and its OSC "mirror"
stream (the events Cagire plays), so the space can react to the music.

```
 Cagire ──audio (JACK)──▶ ambi-engine (C++) ──▶ spk_01..spk_NN  (speakers)
    │                         ▲   │          └─▶ bin_L / bin_R    (headphones)
    └──OSC /cagire/mirror──▶ Godot ──OSC 9100──┘   │
                              ▲─────── telemetry 9101
```

The audio runs in a separate C++ program (`ambi-engine`). The Godot app is the interface: it
starts the engine, controls it over OSC and shows its telemetry.

## Build and run

```bash
git clone --recursive https://github.com/Rhoumi/ambivironnement.git
cd ambivironnement      # in an existing clone without Link: git submodule update --init --recursive
cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j
godot --path .        # or open the project in the Godot editor (Godot 4.7)
```

Godot starts `engine/build/ambi-engine` by itself and restarts it if it disappears. The engine
stops when Godot quits or crashes, but not when the interface is only frozen (for example a
hidden window under Hyprland). Engine log: `~/.local/share/godot/app_userdata/Ambivironnement/engine.log`.

The engine can also run on its own: `engine/build/ambi-engine --help` (`--no-autoconnect` to
leave all connections alone).

Requirements: JACK or PipeWire (with `pipewire-jack`), CMake, a C++17 compiler, Godot 4.7.
`engine/third_party/link` is Ableton Link (header-only, with its asio submodule), included as
a git submodule from github.com/Ableton/link. The engine is built with `-march=native`: build it
on the machine that runs it.

## Platforms

- **Linux** (PipeWire or JACK): developed and used there.
- **macOS**: untested. The engine is written to build there (no Linux-only code left in the
  build, ARM64 denormal handling for Apple Silicon), with JACK2 installed
  (`brew install jack pkg-config cmake`) and a running JACK server. Getting Cagire's audio into
  JACK on macOS also needs a loopback device (for example BlackHole) used as JACK's input.
  Reports welcome.
- **Windows**: not supported (the engine uses POSIX sockets and JACK).

## Routing

- **Cagire**: `F6` > Audio > Driver = JACK (or PipeWire), and enable Link in Synchronization.
  Then in the **OUT** tab: `input <-` choose the Cagire client > `connect`.
  The choice is remembered and reconnected at every start.
- **"Orbits" virtual device** (16 in / 16 out), for the orbits mode: copy
  [`config/pipewire/20-orbits-16ch.conf`](config/pipewire/20-orbits-16ch.conf) to
  `~/.config/pipewire/pipewire.conf.d/` and restart PipeWire. Cagire plays into "Orbits"
  (orbit n → channels 2n-1 / 2n), then in the OUT tab, `input <-` **Orbits** > `connect`.
  `monitor_AUX0..15` then arrive on `in_1L..in_8R`, in order.
- **Binaural**: connected to the physical outputs (headphones) by default.
- **Speakers**: `speakers ->` choose the multichannel interface > `connect` (spk_01 → first
  input, and so on, unless a speaker has an output channel set). qpwgraph works too.
- **OSC mirror**: Cagire sends `/cagire/mirror` to `127.0.0.1:57120` by default, which is the
  port the app listens to (OSC tab). Note: SuperCollider (sclang) also uses 57120; change the
  port in both tools if they run together.

## Input modes

- **ORBITS** (default): 8 stereo inputs `in_1L/R … in_8L/R`, one source per Cagire orbit.
  In Cagire (`F6` > ROUTING), send orbit n to outputs 2n-1 / 2n. Ports connect in order.
- **STEREO (bands)**: a single stereo input `in_1L/R`, split into 1 to 16 frequency bands, one
  source per band (LR4 crossovers with phase compensation, so the bands sum back flat).
  Band presets: Simple 4, Octaves 8, **Buchla 296** (16 bands, or 8 pairs), **Bark 16**
  (critical bands), **Ear / localisation 8** (ITD, ILD, concha and pinna zones), **Ear / highs 12/16**
  (dense split between 2 and 15 kHz, where the pinna cues live).

Sources are called O1..O8 in orbits mode and B1..B16 in stereo mode.
Placement patterns for all sources at once: circle, alternate L/R, rising spiral,
low front > high back, dome, random.

## Audio chain (engine)

1. **Clock**: **Ableton Link** by default (the engine joins the Link session, Cagire included).
   Synced LFOs and the delay follow the *phase* of the Link beat. In **manual** mode the BPM is
   internal. In Link mode the app never imposes its tempo: it only proposes one to the other
   peers when you change the BPM yourself.
2. **Mono bass**: below `f` (80 Hz by default) each input is split by an LR4 crossover. The
   bass is summed to mono and sent to both ears of the binaural output, and to the speakers:
   - if the layout has **subwoofers** (the `sub` column in the SPK tab), the bass goes to the
     subwoofers only. They are left out of the ambisonic decoder, and the full-range speakers
     play everything above `f`;
   - without subwoofers, the bass goes to every speaker at the same level.

   The bass stays in phase with the band split, and with distance compensation the subwoofers
   are time-aligned with the other speakers. Mono bass is useful on headphones (binaural) as
   well as on speakers; when it is off, the subwoofers are silent and every speaker plays the
   full range.
3. **Stereo image per source**:
   - **mono sum** (L+R at one point) or **mirror** (two images).
   - Mirror types: `azimuth` (± spread), `elevation`, `plane` (R is L reflected across the
     vertical plane at angle `axis`, so trajectories become symmetric), `floor` (R below the
     floor), `antipode` (R goes to the opposite side, with the spread).
   - `center` (M/S): the mid part is placed *between* the two images, L and R keep the side part.
   - "apply stereo to all" button.
4. **Source parameters**: azimuth, elevation, distance (1/d and air absorption; below 1 the
   source becomes omnidirectional at the centre), gain, **lobe** (fractional order, like
   `hoa.wider`: 0 = diffuse, 1 = sharp), jitter.
5. **Modulation** (**LFO** tab): 16 LFOs (synced in divisions from 1/16 to 32 bars, or free in Hz)
   and **24 envelope followers** (8 inputs and 16 sources, adjustable attack / release), into a
   **64-slot matrix** towards any source parameter (one source or all) or any global parameter.
   Trajectories (SRC tab) are synced presets built on this matrix.
6. **FX**: everything acts on the whole field, and everything can be modulated (GLOBAL target):
   - rotation yaw / pitch / roll, focus (fisheye warp), lobes;
   - **kaleidoscope** left/right, front/back, up/down (0.5 = symmetric field, 1 = flipped);
   - **ring modulator**, 4 models: classic, **rotating** (the carrier phase follows the azimuth,
     so the sidebands turn around the room), **vertical**, **freq field** (different carrier
     frequency in front and behind);
   - **spatial tremolo**: a gain lobe you can point (`am_az` driven by a saw LFO = rotating chopper);
   - **decimator**, with a different sample rate per direction;
   - **diffuser** (decorrelating all-pass filters);
   - **spatial delay**, ping-pong through the centre, in seconds or in beats;
   - **diffuse reverb**, with `rotate` moving the tail from one direction to another.

   These effects run in a domain of 24 plane waves: decode, process per direction, re-encode,
   like the projector / recomposer of the CICM HOA library. The round trip is transparent when
   every effect is at 0.
7. **Decoding** (order 1 to 3, maxRe / inPhase / basic): **AllRAD** (default) with VBAP and
   imaginary speakers, **mode-matching** or **sampling**. Distance compensation (delay and gain)
   per speaker.
8. **Binaural**: 36 virtual speakers with a Brown-Duda spherical head model. It is meant for
   checking on headphones, not as a replacement for a measured (SOFA) HRTF.
9. **Safety**: linked peak limiter (instant attack, 150 ms release, ceiling -0.3 dBFS) on the
   speakers and on the binaural output. The `LIM` indicator appears in the meters when it works.
   The binaural output is normalised to unity gain at the ears, with 6 dB of headroom.

Convention: ACN / SN3D (AmbiX), positive azimuth = left, 0 = front.

## Interface

- Theme: cream text on true black, cyan accent (the colour of sources and trajectories),
  purple for the selection, orange for warnings (Cagire's Pitch Black colours). Other themes
  and the palette are in `scripts/palette.gd`.
- The window resizes freely: the interface scales smoothly and stays sharp, and the 3D view
  keeps its low-resolution dithered rendering.
- **F11** (or `FULL`): fullscreen. **F10** (`PANEL`): hide the panel to keep only the 3D view.
  **Esc**: leave fullscreen.
- Bottom meters: 16 inputs grouped O1 to O8 in orbits mode (IN L/R in stereo mode), then
  binaural, speakers, LFOs and the `LIM` indicator.

## Speakers (SPK tab)

- Layout presets (stereo to 7.1.4, domes, icosahedron, the GRAME studio with its two
  subwoofers), or your own layout saved in `user://layouts`.
- Per speaker: azimuth, elevation, distance, `out` (output channel, 1-based; 0 = in order),
  `sub` (subwoofer, see Mono bass above). Press `apply` after editing.
- In the 3D view, each speaker shows its output channel when one is set (so the GRAME layouts
  show the studio's numbers), otherwise its position in the list. Subwoofers are drawn as
  wider, flatter boxes.

## Presets (PRESETS tab)

- Presets are sorted in two lists, **ORBITS** and **STEREO (bands)**, one per input mode.
  The list shown follows the current mode. The tabs let you look at the other list; recalling
  a preset from it switches the input mode.
- Click a preset to recall it, with an optional **morph** time (0 to 20 s), when the input
  mode does not change (the sources differ between modes). During a morph:
  - source and global parameters, crossovers, bass frequency and envelopes glide;
  - the modulation matrix crossfades. When an LFO changes, its old modulations fade out over
    the first half, the LFO switches in the middle and its new modulations fade in, so
    trajectories hand over without a jump;
  - with `layout` checked, the speakers glide to their new positions, in the 3D view and in
    the decoder;
  - on / off and list choices (stereo mode, mute, ring modulator model, bass on, band count,
    speaker count, outputs, subwoofers, decoder settings) switch in the middle.

  The morph time and the `layout` / `OSC rules` boxes are remembered.
- **save** (new name, into the current mode's list), **overwrite selected**, **delete selected**,
  **restore examples**.
- A preset holds the mode, the bands, the sources of both modes, the FX, the mono bass, the
  envelopes, the LFOs and the matrix. It can optionally include the speaker layout and the OSC
  rules. It never touches levels, routing or the clock.
- Examples: 13 for orbits (ring, mirror plane, crushed, counter rings, pendulum wave,
  lissajous dome, swarm, pulse approach, vertical wheel, antipodes, phasing, rising spiral,
  breathing ring) and 7 for stereo (init 4 bands, buchla 296 spiral, ear highs shimmer,
  ring rotor, dub space, kaleidoscope, diffuse wash).
- Recall from Cagire: an OSC rule with the `preset` action (for example key `preset`, value `*`,
  index read from the key `preset`). A message to the mirror port carrying `preset 3` recalls
  the 4th preset **of the current mode's list**. A name works too, and `orbits/<name>` or
  `stereo/<name>` picks a list explicitly.
- Files: `user://presets/orbits/*.json` and `user://presets/stereo/*.json`, that is
  `~/.local/share/godot/app_userdata/Ambivironnement/presets/`. Presets saved by an older
  version (directly in `presets/`) are moved into the list of their mode at start-up.

## OSC rules (OSC tab)

Each received message is decoded into a key=value dictionary (`s=kick note=36 orbit=1 …`) and
shown in the log.
A rule is `key = value` (`*` = any value) → an action on a target (`O1..O8` / `B1..B16`, `ALL`,
`GLOBAL`, or `=orbit`, which uses the event's `orbit` value as the source number).

| action      | effect |
|-------------|--------|
| `pulse`     | adds `amount` (× the value of a key if `scale by key` is set) to the parameter, then decays over `decay` s |
| `set`       | sets the base value of the parameter to `remap(key, in, out)` |
| `random`    | random base value between `out min` and `out max` |
| `lfo_reset` | resets an LFO to phase 0 (to lock a trajectory to an event) |
| `preset`    | recalls a preset (index or name, read from an event key, else a fixed index) |

`+ from last event` creates a rule from the last received message. A few examples (disabled)
are included.

## Files

- `engine/src/`: `engine.cpp` (real-time audio callback), `decoder.cpp` (AllRAD / VBAP /
  pseudo-inverse), `dsp.hpp` (filters), `osc.hpp`, `main.cpp` (OSC server, 30 Hz telemetry).
- `scripts/session.gd`: the whole state, saved automatically to `user://session.json`.
  Export / import in the OUT tab.
- `scripts/presets.gd`: presets and the built-in examples.
- `scripts/layouts.gd`: speaker layout presets.
- `scripts/ui.gd`: the control panel. `scripts/main.gd`: window, top bar, first-person mode.
- `scripts/view3d.gd` + `shaders/field.gdshader`: 3D scene and intensity balloon (64 directions
  measured on the HOA bus).
- `shaders/dither.gdshader`: 4×4 Bayer dithering on 4 colours. Palette in `scripts/palette.gd`.

## Control protocol (UDP 9100)

Any OSC tool can drive the engine directly:

- `/src i param value`, `/srcmode i smode mtype`, `/mute i on`
- `/global param value`, `/lfo i param value`, `/lfo/reset i`
- `/mod slot source target param amount` (source: 0-15 LFO, 16-23 input envelopes, 24-39 source
  envelopes; target: source index, -1 global, -2 all sources), `/mod/clear`
- `/pulse target param amount decay`
- `/bands/count n`, `/bands/xover i freq`
- `/spksub flag…` (1 = subwoofer, one value per speaker; send before `/layout`)
- `/layout n az el dist …`, `/decoder type optim order`, `/distcomp on`
- `/spkmap ch…` (output channel per speaker, 1-based, 0 = in order; send before `/connect/speakers`)
- `/set name value` with name in: master spk bin input binon mode (0 stereo bands, 1 orbits)
  basson bassfreq envatk envrel clock rmmodel dlsync, and the listener pose lx ly lz lyaw
  lpitch lrotspk
- `/tempo bpm`, `/connect/input regex`, `/connect/binaural regex`, `/connect/speakers regex`
- `/ports`, `/ping`, `/quit`

## Debug and testing

- `AMBI_SCREENSHOT=/tmp/x.png [AMBI_TAB=n] godot --path .` saves a capture after 3 s and quits.
- Isolated test instance (leaves your session, presets and engine alone):
  `AMBI_TEST=1 AMBI_CTRL_PORT=9300 AMBI_TELE_PORT=9301 AMBI_ENGINE_NAME=ambishot AMBI_NO_AUTOCONNECT=1 AMBI_MIRROR_PORT=9302`.

## License

Ambivironnement is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. See [LICENSE](LICENSE).

It uses [Ableton Link](https://github.com/Ableton/link) (GPL-2.0-or-later) and its bundled
[asio](https://github.com/chriskohlhoff/asio) (Boost Software License).
