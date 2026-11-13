# macOS overlay

La implementación nativa de macOS todavía no está incluida. El host ya está
preparado para arrancarla cuando exista:

- Ruta esperada: `overlay/macos/DSHSessionNotifier.app/Contents/MacOS/DSHSessionNotifier`.
- Entrada en `overlay/platforms.json`: `darwin.supported = true`.
- La app debe leer `~/Library/Application Support/dsh-session-notifier/state.json`.
- El resto de la lógica (frames, burbuja, sonidos, click-through, autoarranque)
  está descrita en [`docs/MACOS.md`](../../docs/MACOS.md).

Mientras no exista, el plugin se instala y el puente de estado funciona, pero no
hay mascota nativa en macOS.
