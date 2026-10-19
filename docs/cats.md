# Cats

Pixel cats wander the free part of the status bar. They are decoration with a little life in them.

## Setup

`barCat` turns them on. `barCatSheets` lists one entry per cat: either `builtin` for the hand-drawn 16×11 cat tinted with the bar's text colour, or a path to a sprite sheet in Last tick's free [Pixel Cats 64×64](https://last-tick.itch.io/animated-pixel-cats-64x64) layout, for example `cat 2 (64x64).png`. That pack forbids redistribution, so it is never bundled: download it yourself and point at the files. Settings › Cats has Add Sheet… and Add Built-in Cat buttons. With no entries you get one built-in cat.

The sheet loader knows the pack's rows for walk, run, sit, groom, lie and sleep in both directions and scales them to the bar height.

## Behaviour

Each cat has three slow-moving drives, energy, boredom and affection, and a personality seeded from its sheet path: lazy, playful, clingy multipliers that stay the same across launches. About once a second a walking cat picks its next pose from the drives: tired cats nap, longer if lazy; bored playful cats run or start a scene; petted cats groom and seek company.

With two or more cats, scenes happen: a chase, a visit where one sits beside another, mutual grooming, or a cuddle in the middle of the bar when both are tired. The initiating cat picks the nearest partner.

## Interaction

- **Hover** the empty part of the bar and interested cats run to the pointer and sit beside it, each in its own spot. Interest depends on playfulness and affection; sleeping cats are reluctant, and one cat always humours you. When the pointer leaves, they stroll to where it was and look around.
- **Click** a cat to pet it. A sleeping cat wakes and looks about. Three pets in a row and it lies down purring with hearts; too many and it walks off, slightly offended.

Clicks elsewhere on the strip pass through to the bar.

## The notch

On a notched MacBook, with `barNotchPortals` on, the cats cross the notch through a pair of Portal-style portals, blue on the left and orange on the right, lit only while a cat is passing. The part of the cat that has entered one edge comes out of the other. With portals off the cats stay on the left of the notch. A long window title leaves room for the cats; if there is none, they live right of the notch instead.
