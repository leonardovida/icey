# App icon

The app icon is `Ice/Resources/AppIcon.icon`, a layered Icon Composer document. macOS 26 and later render it with Liquid Glass in every appearance (default, dark, clear and tinted). Xcode generates a matching flat icon for macOS 14 and 15.

- `Cube.svg` and `Highlights.svg` are the sources of the icon's two layers. The `.icon` document holds 1024×1024 PNG renders of them, because Icon Composer recolors SVG strokes in the dark appearance as filled shapes.
- `AppIcon-<size>.png` are renders for the README and the website. Regenerate them after changing the icon:

```sh
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for w in 32 64 256 512 1024; do
  "$ICTOOL" Ice/Resources/AppIcon.icon --export-image --output-file Resources/AppIcon/AppIcon-$w.png \
    --platform macOS --rendition Default --width $w --height $w --scale 1
done
```
