# Guía para replicar el overlay en macOS

El plugin de DSH y el puente de estado son multiplataforma y el host ya es
platform-adaptive: lee `overlay/platforms.json` y arranca la entrada de la
plataforma actual. La implementación Windows (WPF/PowerShell) vive en
`overlay/windows`; para macOS hay que crear `overlay/macos`, activar
`darwin.supported` y empaquetar la app. El host no necesita una rama nueva.

Esta guía asume que DSH Desktop ya funciona en el Mac y que el plugin se instala
con Plugin Manager igual que en Windows.

---

## 1. Qué se reutiliza y qué no

| Pieza | Windows hoy | macOS |
|---|---|---|
| `client.js` (puente invisible, actividad, estado) | Sí | **Se reutiliza tal cual** |
| Ruta HTTP `/dsh-session-notifier/state` | Sí | **Se reutiliza** |
| Esquema JSON del estado | Sí | **Se reutiliza** |
| Frames PNG y mapeo de filas | Sí | **Se reutiliza** |
| `index.js` (host) | Ruta multiplataforma + manifiesto | **Se reutiliza; solo activar `darwin`** |
| Overlay visual | `overlay/windows` (WPF) | **Crear `overlay/macos`** (AppKit, Tauri o Electron) |
| Sonido | `System.Media.SoundPlayer` | **AVAudioPlayer / NSSound** |
| Lanzador | `.cmd` | **`.app` o ejecutable** |
| Instalación del plugin | `plugin_manager install_bundle` | **Igual** |

No conviene intentar ejecutar WPF/PowerShell en macOS: no existe una capa de
compatibilidad razonable.

---

## 2. Decisión de arquitectura

### Opción A — App nativa Swift + AppKit (recomendada)

Ventajas:

- Ventana transparente, flotante y en todos los Spaces con APIs nativas.
- Muy poco consumo y arranque rápido.
- Control fino de frames, sonido, menú y posición.
- No requiere runtime adicional.

Coste:

- Hay que mantener una segunda implementación del overlay.
- Requiere Xcode/Command Line Tools y, para distribuir, firma y notarización.

### Opción B — Tauri 2 (Rust + WKWebView)

Ventajas:

- Una sola implementación web para macOS, Windows y Linux.
- Permite reutilizar HTML/CSS y los mismos PNG.
- Binario pequeño comparado con Electron.

Coste:

- Toolchain de Rust.
- El control de transparencia, click-through y nivel de ventana depende de
  APIs de macOS/Tauri; hay que probarlo en varias versiones.

### Opción C — Electron

Ventajas:

- Reutiliza casi todo el código web.
- `BrowserWindow` transparente, `alwaysOnTop` y `setIgnoreMouseEvents`.

Coste:

- Bundle grande (~100 MB), más RAM.
- Firma/notarización más pesada.

Recomendación: **AppKit** si el objetivo es la mejor integración en macOS;
**Tauri** si se quiere una sola base para Windows/macOS a futuro.

---

## 3. Paso 1: hacer el host multiplataforma

En `index.js` la ruta ya se resuelve por plataforma. La implementación actual es
equivalente a:

```js
import { homedir } from 'node:os';
import { join } from 'node:path';

function stateDir() {
  if (process.platform === 'darwin') {
    return join(homedir(), 'Library', 'Application Support', 'dsh-session-notifier');
  }
  if (process.platform === 'win32') {
    return join(process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local'), 'dsh-session-notifier');
  }
  const base = process.env.XDG_STATE_HOME ?? join(homedir(), '.local', 'state');
  return join(base, 'dsh-session-notifier');
}
```

El resto del host (ruta HTTP, normalización del JSON, escritura atómica) no
cambia.

### Autoarranque en macOS

El repositorio ya es platform-adaptive: `index.js` lee `overlay/platforms.json`,
resuelve la entrada de `process.platform` y arranca el overlay con `spawn`.
Para macOS no hay que añadir una rama `darwin` al host:

1. Coloca la app en `overlay/macos/DSHSessionNotifier.app`.
2. En `overlay/platforms.json`, pon `darwin.supported` en `true`. La entrada ya
   existe:

```json
{
  "darwin": {
    "supported": true,
    "kind": "executable",
    "entry": "macos/DSHSessionNotifier.app/Contents/MacOS/DSHSessionNotifier",
    "label": "macOS AppKit overlay"
  }
}
```

El host ya soporta `kind: "executable"`: lanza ese binario y lo termina con
`child.kill()` cuando se cierra DSH. Si la entrada no existe, el host solo
registra un aviso y el puente de estado sigue activo.

Notas:

- Arranca el **ejecutable interno** del `.app`, no `open -a`, para conservar el
  `child` y poder terminarlo al cerrar DSH.
- Si usas `open -a`, tendrás que localizar el PID por bundle id y terminarlo
  aparte; es más frágil.
- Alternativa: un `LaunchAgent` con `RunAtLoad`/`KeepAlive`. Es útil si quieres
  que el overlay viva aunque DSH no esté abierto, pero entonces no se cierra con
  DSH.
- Firma la app; macOS puede bloquear un ejecutable sin firmar descargado de
  Internet.

---

## 4. Paso 2: ventana nativa en AppKit

Estructura sugerida:

```text
overlay/macos/
  DSHSessionNotifier.xcodeproj/        # o Package.swift
  Sources/
    AppDelegate.swift
    OverlayPanel.swift
    PetView.swift
    StateStore.swift
    SoundPlayer.swift
  Info.plist
  Resources/
    frames/                             # no se commitean
```

`Info.plist` mínimo relevante:

```xml
<key>LSUIElement</key>
<true/>
<key>NSHighResolutionCapable</key>
<true/>
```

`LSUIElement` oculta el icono del Dock y evita que la app aparezca como una app
normal.

Ventana:

```swift
let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 168, height: 252),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.hidesOnDeactivate = false
panel.becomesKeyOnlyIfNeeded = true
panel.isMovableByWindowBackground = true
```

`NSApp.setActivationPolicy(.accessory)` en `applicationDidFinishLaunching`
completa el modo agente.

### Click-through

macOS no ofrece un “hit test por píxel” a nivel de ventana tan directo como el
`WM_NCHITTEST` de Windows. Dos estrategias:

1. **Modo click-through total**: `panel.ignoresMouseEvents = true`. La ventana no
   intercepta nada, pero tampoco se puede arrastrar ni abrir el menú. Añade un
   `NSStatusItem` en la barra de menús para activar/desactivar este modo.
2. **Hit testing por vista**: un `NSView` personalizado cuyo `hitTest` devuelva
   `nil` fuera de la silueta de la mascota. Reduce el área interactiva, pero
   macOS puede seguir considerando la ventana para algunos eventos; pruébalo en
   varias versiones.

Para una primera versión, la opción 1 + ítem de barra de menús es la más
predecible.

### Arrastrar y posición

Puedes usar `panel.isMovableByWindowBackground = true` para arrastrar desde
cualquier zona opaca, o implementar `mouseDown`/`mouseDragged` en `PetView`.
Guarda la posición en:

```text
~/Library/Application Support/dsh-session-notifier/overlay-position.json
```

Usa coordenadas en puntos (`CGFloat`), no en píxeles, y limita la ventana al
`visibleFrame` de la pantalla que contiene su centro. En macOS con Retina, los
frames son PNG de 192×208; muéstralos con `imageView.layer.magnificationFilter =
.nearest` para que el pixel art no se vea borroso.

---

## 5. Paso 3: leer el estado

El host escribe el mismo JSON que en Windows. En Swift:

```swift
struct OverlayState: Decodable {
    let updatedAt: Double
    let runningCount: Int
    let pendingCount: Int
    let completedCount: Int
    let activity: String?
    let activityTool: String?
    let error: Bool?
    // alerts...
}

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let stateURL = appSupport
    .appendingPathComponent("dsh-session-notifier", isDirectory: true)
    .appendingPathComponent("state.json")

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    guard let data = try? Data(contentsOf: stateURL),
          let state = try? JSONDecoder().decode(OverlayState.self, from: data) else {
        // mostrar dormido/sin conexión
        return
    }
    // actualizar frames, burbuja, badge y sonido
}
```

La lógica de estados es la misma que en el overlay de Windows:

- prioridad: `pending` > `error` > `completed` > `running` > `idle`;
- `activity` elige el frame: `commands`, `searching`, `writing`, `thinking`,
  etc.;
- la burbuja se oculta en `idle` y `stale`;
- `recentCompletion` se dispara cuando `runningCount` baja y la página no tiene
  foco (`focused == false`).

---

## 6. Paso 4: frames, burbuja y sonido

### Frames

Usa los mismos nombres de carpeta que el overlay de Windows:
`idle`, `thinking`, `commands`, `searching`, `writing`, `approval`, `excited`,
`happy`, `sad`, `sleeping`.

Un `Timer` a 30 fps cambia `NSImage` en un `NSImageView` según la velocidad de
cada estado. Para el giro de celebración puedes usar una animación de
`CALayer`/`CAKeyframeAnimation` o rotar la vista con `CGAffineTransform`.

Los frames no se distribuyen en el repo público. En macOS el extractor también
funciona:

```bash
python3 -m pip install --user -r requirements.txt
python3 tools/extract_gengar_frames.py --zip "$HOME/Downloads/gengar.zip"
```

### Burbuja

Un `NSView` con `wantsLayer = true`, fondo oscuro semitransparente, borde de
color del estado y un `NSTextField` centrado. El texto se actualiza con el
mismo criterio que en Windows. Ocúltala en `idle` y `sleeping`.

### Sonido

Dos chimes distintos, generados una vez como WAV:

```swift
let player = try? AVAudioPlayer(contentsOf: wavURL)
player?.play()
```

O `NSSound(contentsOf: url, byReference: true)?.play()`. Guarda la preferencia
de mute en `overlay-settings.json` dentro de Application Support. No necesitas
permisos especiales para reproducir audio.

### Menú

En `rightMouseDown` abre un `NSMenu` con:

- Abrir DeepSeek Harness.
- Sonido (check).
- Siempre visible (check).
- Modo click-through (check, opcional).
- Reiniciar posición.
- Salir.

Para enfocar DSH:

```swift
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseek.dsh")
apps.first?.activate(options: [.activateAllWindows])
```

Si el bundle id cambia en el futuro, búscalo por nombre o por `bundleURL`.

---

## 7. Paso 5: empaquetado, firma y notarización

Para uso local:

```bash
xattr -dr com.apple.quarantine /path/to/DSHSessionNotifier.app
open /path/to/DSHSessionNotifier.app
```

Para distribuir:

1. `codesign --force --deep --options runtime --sign "Developer ID Application: ..." DSHSessionNotifier.app`
2. `xcrun notarytool submit DSHSessionNotifier.zip --apple-id ... --team-id ... --password ... --wait`
3. `xcrun stapler staple DSHSessionNotifier.app`

Compila un binario universal (`arm64` + `x86_64`) si quieres cubrir Intel y
Apple Silicon.

Si la app va a la Mac App Store, el sandbox cambia el acceso a Application
Support: el overlay no podrá leer directamente el archivo del host fuera de su
contenedor. En ese caso usa un App Group y haz que el host escriba en la ruta
del grupo, o distribuye fuera de la App Store.

---

## 8. Alternativa Tauri (si quieres una sola base)

Configuración de ventana:

```json
{
  "transparent": true,
  "decorations": false,
  "alwaysOnTop": true,
  "skipTaskbar": true,
  "resizable": false,
  "shadow": false,
  "width": 168,
  "height": 252
}
```

- `set_ignore_cursor_events(true/false)` para click-through.
- `set_visible_on_all_workspaces(true)`.
- Nivel de ventana flotante y activación `.accessory` mediante APIs nativas.
- Un comando Rust lee `state.json` cada 500 ms o recibe eventos del host.
- Un `LSUIElement` en `Info.plist` oculta el Dock icon.

La ventaja es reutilizar HTML/CSS y los PNG; la desventaja es que el control
fino de transparencia y click-through requiere probar cada versión de macOS.

---

## 9. Checklist de pruebas en macOS

- [ ] El host escribe `~/Library/Application Support/dsh-session-notifier/state.json`.
- [ ] El overlay arranca al abrir DSH y se cierra al cerrar DSH.
- [ ] Ventana transparente, sin sombra y sin icono en el Dock.
- [ ] Visible sobre Finder, Safari, VS Code y una app a pantalla completa.
- [ ] Funciona en varios Spaces y con Stage Manager.
- [ ] Multi-monitor y Retina sin desplazamientos ni frames borrosos.
- [ ] Arrastrar, reiniciar posición y persistencia tras reiniciar.
- [ ] Click-through fuera de la mascota y menú contextual.
- [ ] Burbuja oculta en reposo/sin conexión.
- [ ] Textos: Razonando, Shell, Codeando, Escribiendo, Editando, Leyendo, Buscando.
- [ ] Badge y contadores con varias sesiones.
- [ ] Dos sonidos distintos y mute persistente.
- [ ] Estado de error (sad) y finalización (happy/excited).
- [ ] Firma/notarización y arranque en un Mac limpio.

---

## 10. Plan de migración sugerido

1. **Host multiplataforma**: ruta de estado y rama `darwin` del autoarranque.
2. **Stub del overlay**: ventana AppKit/Tauri que lea el JSON y muestre un
   rectángulo; verifica arranque/cierre y posición.
3. **Frames y burbuja**: mismos estados y textos que Windows.
4. **Interacción**: drag, menú, click-through, mute y persistencia.
5. **Sonidos y error**: AVAudioPlayer, estados sad/happy/excited.
6. **Empaquetado**: `.app`, icono, universal binary, firma y notarización.
7. **CI/release**: GitHub Actions con runner `macos-latest` para construir y
   adjuntar el `.zip`/`.dmg` al release.

Con esto, `client.js`, la ruta HTTP, el esquema de estado y los frames quedan
iguales; solo cambia la capa nativa y las rutas del host.
