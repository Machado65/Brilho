# Brilho

Automatic brightness for the Mac that learns what you like.

Brilho follows the light in the room with the MacBook's ambient light sensor and
sets every display to match: the built-in one, Apple's and HDR monitors through
macOS, other monitors over DDC/CI, and the ones that answer neither by dimming
their picture. Each time you correct it, it learns: not just "brighter", but
brighter *in this light*, at this hour, in this app. It also warms the screens'
white in the evening, as warm as you like it.

*Brilho* is Portuguese for brightness.

## What it does

- **Brightness by the light, learnt from you.** A curve from lux to nits for each
  display, starting from a sensible default and bent by every correction you
  make: with the brightness keys, the panel's slider, or the monitor's own
  buttons.
- **The circumstances count.** Corrections are learnt by the time of night, the
  app in front, the dark appearance and the power source. If you like video
  brighter and white pages dimmer, Brilho comes to set them that way.
- **Night Warmth.** From sunset (worked out for your location) the screens warm
  to 3500 K, and to 2000 K by bedtime, nine hours before you wake. The Warmth
  slider sets how warm, and that's learnt too, per app: neutral in your photo
  editor, warm everywhere else.
- **Every display.** Native control where macOS has it; DDC/CI for other
  monitors, with their contrast learnt as well; software dimming for the ones
  that answer neither, until they do. The brightness keys work on whichever
  display the pointer is on.
- **Nits, not percentages.** Displays are measured (where macOS reports the
  nits) or calibrated by eye against the built-in display, so the same
  preference gives the same light on any of them. A new monitor starts from what
  the others have learnt.
- **XDR in the sun.** On XDR MacBooks, the built-in display can go past its
  500-nit SDR limit, only in bright light (over 1000 lux), and back when the
  light drops.
- **HDR switch, Room Colour, Open at Login**, and `brilho://auto` and
  `brilho://xdr` URLs to toggle those from a keyboard shortcut.

## How the learning works

Each preference is a small regularised regression, refitted exactly whenever a
correction comes in (typically in under a millisecond):

- a curve over the light level, log10(lux + 1), through knots spaced a quarter
  of a decade apart, drawn towards a prior curve and bending away from it only
  gradually, so one correction moves its neighbourhood most and far-off light a
  little;
- an additive shift for each circumstance: night (by your own hours), dark
  appearance, battery, and each app you've corrected in. Each shift stays at
  zero until the corrections disagree in a way only it explains;
- brightness kept monotonic: more light never asks for less;
- robust to a stray correction (Huber weights, by iteratively reweighted least
  squares);
- older corrections count less as newer ones come in, not as time passes, so a
  curve you stopped correcting because it's right is never forgotten;
- the newest correction always holds: the curve passes through what you just
  chose.

Brightness is learnt in log10(nits), contrast in DDC steps, and warmth as the
strength of Night Warmth (0 is none, 1 the schedule). A new display's prior is
the other displays' learnt curves, weighted by how much each has to go on.

The tests include simulated users with preferences only they know, who correct
Brilho whenever it's plainly off. Brilho typically learns one of them within
three or four days, from a dozen corrections: its error falls from about 35% of
the light to about 6%. Learning the circumstances cuts a month's corrections
from over two hundred to about ten for someone who likes some apps brighter than
others, and next to nothing for someone who doesn't.

## Requirements

- An Apple Silicon Mac with macOS 14 or later.
- An ambient light sensor, as in MacBooks, to follow the light. Without one,
  or with the lid closed, Brilho follows the time of day instead, and doesn't
  learn from corrections made meanwhile.
- For DDC/CI, a monitor with it on (it's often in the monitor's menu). Over
  some docks and adapters it doesn't get through; Brilho then dims in software.

Brilho is a Mac app. Its core (the learning, Night Warmth's schedule, the colour
and light maths) is plain Swift with no Apple frameworks, and its tests run on
Linux as well.

## Install

Brilho is installed from its source, which takes a couple of minutes and no
Xcode.

1. **Install Apple's Command Line Tools**, if you haven't (a terminal will say
   so if they're there already):

   ```sh
   xcode-select --install
   ```

2. **Get Brilho and build it:**

   ```sh
   git clone https://github.com/Machado65/Brilho.git
   cd Brilho
   ./build.sh --local-identity
   ```

   This builds `~/Applications/Brilho.app` and starts it: a sun appears in the
   menu bar. `--local-identity` makes a signing certificate of Brilho's own,
   once, in a keychain of its own, so that macOS remembers Brilho's
   permissions across updates.

3. **Set it up**, from the sun in the menu bar:
   - turn on **Open at Login**, so it keeps running;
   - **Use Current Location** under Night Warmth, for sunset times, and set
     your **wake-up time**;
   - for each external monitor, **Calibrate** (by eye, against the built-in
     display, in about a minute) or **Measure** it, so that its nits are right;
   - if you have external monitors, **Allow…** the brightness keys for them.

Then just use your Mac. Whenever the brightness isn't right, set it as you'd
like it, with the keys, the panel or the monitor's buttons: that's what Brilho
learns from.

To update, from the `Brilho` folder:

```sh
git pull
./build.sh
```

Set `BRILHO_IDENTITY` to sign with a certificate of your own, or `BRILHO_APP`
to build somewhere else; without `--local-identity` the first time, the app is
signed ad hoc, and macOS asks for the Accessibility permission again after
every update. `./build.sh test` runs the tests.

## Permissions

All optional:

- **Accessibility**, for the brightness keys on displays macOS can't dim. Brilho
  listens only to the media keys, and acts only on the brightness ones.
- **Location**, once, when you press *Use Current Location*: for sunset times.
  It's kept rounded to about a kilometre.
- **Login Items**, for *Open at Login*.

## Privacy

Brilho itself makes no network connections. What it learns stays in its
preferences on your Mac (`defaults read io.github.machado65.brilho`): your corrections, each
with the light level and the circumstances it was made in, including the
bundle identifier of the app in front; your displays' calibrations; your
location for sunsets, if you set it. *Forget My Adjustments* clears the
corrections; deleting the app's preferences clears the rest.

## Diagnostics

```sh
~/Applications/Brilho.app/Contents/MacOS/Brilho --diagnose
```

prints what Brilho sees (sensor, displays, DDC answers, what it has learnt)
without changing anything; include it in bug reports. Brilho logs what it does
to the system log:

```sh
log stream --predicate 'subsystem == "io.github.machado65.brilho"'
```

## Private APIs

macOS has no public interface for most of this, so Brilho uses private ones:
DisplayServices (brightness), the IOHID event system (the light sensor),
IOAVService (DDC/CI on Apple Silicon), MonitorPanel (the HDR switch) and the
framebuffer's brightness level (nits). Any macOS update can change them. When
one is missing, Brilho logs it and leaves out what needs it rather than
failing. It can't be on the Mac App Store for the same reason.

## Uninstall

Turn off **Open at Login**, quit Brilho from its panel, then:

```sh
rm -rf ~/Applications/Brilho.app "$HOME/Library/Application Support/Brilho"
defaults delete io.github.machado65.brilho
```

Brilho turns off macOS's own automatic brightness, which would fight it: turn
it back on in System Settings › Displays if you'd like it.

## Licence

Copyright © 2026 Machado65.

Brilho is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).

Colour temperatures follow Kim et al.'s cubic approximation of the Planckian
locus; sunsets, NOAA's solar equations.
