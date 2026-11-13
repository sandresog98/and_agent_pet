# Asset notice

The **code** in this repository is covered by the MIT license in `LICENSE`.

The **Gengar character** is a trademark and copyrighted character of Nintendo /
Game Freak / The Pokémon Company. This repository is an unofficial companion
and is not affiliated with them.

This repository does **not** distribute Gengar sprites or frames. The
`overlay/frames/*/*.png` files are intentionally ignored. If you want the
Gengar pet, you must provide a spritesheet or ZIP you have the rights to use and
run:

```bash
python tools/extract_gengar_frames.py --zip "path/to/your/gengar.zip"
```

Only do this if you own the artwork or have permission to use it. Without the
frames, the overlay falls back to its original generic ghost pet, so the plugin
remains functional.
