# Overlays

Este directorio contiene una implementación del overlay por plataforma. El
host lee `platforms.json` y arranca la entrada correspondiente a
`process.platform`; no hay que elegir nada al instalar el plugin.

- `windows/`: overlay WPF + PowerShell (funcional).
- `macos/`: slot para la app AppKit (pendiente; ver `docs/MACOS.md`).
- `linux/`: slot para un overlay Linux (pendiente).
- `frames/`: frames PNG compartidos (no incluidos en el repo público).

Cuando añadas un overlay nuevo, coloca el ejecutable en su carpeta y activa
`supported: true` en `platforms.json`. El puente web y la ruta de estado
funcionan en todas las plataformas aunque el overlay nativo no exista.
