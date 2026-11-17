# Quod splash artwork

The existing six-colour Quod dodecahedron, with a geometric lowercase wordmark
drawn as paths. The cream lettering is intended for a dark background.

- `quod-logo.svg`: editable transparent logo, 480 × 480. No font dependencies.
- `quod-logo.png`: transparent export, 960 × 960.
- `quod-splash.svg`: 1920 × 1080 splash composition; keep it beside the logo SVG.
- `quod-splash.png`: standalone 1920 × 1080 splash export.

The emblem uses the geometry and colours from
[`quod-dodecahedron-gradient.svg`](../dodecahedron/styles/quod-dodecahedron-gradient.svg).
The background continues the client's deep teal palette.

The Godot client does not show this artwork at start. Its boot image is
[`client/godot/assets/quod-splash.png`](../../client/godot/assets/quod-splash.png),
the app icon without the wordmark. Using this splash there is a separate step.

Regenerate the PNG exports with librsvg:

```sh
rsvg-convert -w 960 -h 960 assets/splash/quod-logo.svg -o assets/splash/quod-logo.png
rsvg-convert assets/splash/quod-splash.svg -o assets/splash/quod-splash.png
```
