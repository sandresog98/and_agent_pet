# and_agent_pet — DSH Session Notifier

Overlay nativo **platform-adaptive** para **DeepSeek Harness**: una mascota Gengar que se queda por encima de las demás ventanas, muestra el estado de tus sesiones y avisa con animaciones y sonidos cuando una sesión piensa, ejecuta una herramienta, pide aprobación o termina.

Un solo repositorio. El host lee `overlay/platforms.json` y arranca la implementación de la plataforma actual; el puente web y el esquema de estado son compartidos.

| Plataforma | Overlay nativo | Estado |
|---|---|---|
| Windows 10/11 | WPF + PowerShell | Funcional |
| macOS | AppKit (slot preparado) | Pendiente; el puente de estado ya funciona |
| Linux | Slot preparado | Pendiente; el puente de estado ya funciona |

El plugin de la interfaz web es un puente invisible: ya no dibuja una campana dentro de DSH; lee el estado de las sesiones y lo publica para el overlay nativo.

> Repositorio: <https://github.com/sandresog98/and_agent_pet>

> ¿Quieres llevarlo a macOS? Hay una guía de portabilidad en [docs/MACOS.md](docs/MACOS.md).

## Características

- Mascota Gengar animada por frames (idle, thinking, shell, buscando, approval, happy, excited, sad, sleeping, writing).
- Burbuja de actividad con texto breve: «Razonando...», «Shell...», «Codeando...», «Escribiendo...», «Editando...», «Leyendo...», «Buscando...», «Necesita tu aprobación», «¡Listo!», «Algo falló», etc.
- Se oculta la burbuja en reposo y sin conexión.
- Arrastrable, `Topmost`, con zonas transparentes que no bloquean clics.
- Dos chimes suaves distintos: uno para aprobación/pregunta y otro para finalización.
- Menú contextual para abrir DSH, activar/desactivar sonido, reiniciar posición o salir.
- Autoarranque con DeepSeek Harness y cierre al cerrar DSH.
- Indicador agregado para varias sesiones: contadores totales y tooltip con hasta 8 sesiones.

## Requisitos

- Windows 10/11 para el overlay completo actual.
- DeepSeek Harness (probado con `0.2.2-rc.1`).
- En macOS/Linux el plugin se instala y el puente de estado funciona, pero el overlay nativo está pendiente.
- Python 3 y Pillow **solo si quieres extraer los frames de Gengar** desde tu propio spritesheet/ZIP.

## Instalación

1. Clona el repositorio:

   ```powershell
   git clone https://github.com/sandresog98/and_agent_pet.git
   cd and_agent_pet
   ```

2. Instala el plugin en DSH con **Plugin Manager** usando la carpeta absoluta del repo (`install_bundle`). El paquete se llama `dsh-session-notifier`.

3. El overlay se inicia automáticamente al abrir DSH en la plataforma soportada. En Windows, si quieres abrirlo aparte:

   ```powershell
   overlay\windows\Iniciar notificador.cmd
   ```

En macOS/Linux, el plugin queda activo como puente de estado hasta que se añada la implementación nativa correspondiente.

## Frames de Gengar

El repositorio **no distribuye los frames de Gengar** por derechos del personaje. El código funciona sin ellos usando una mascota genérica de respaldo.

Para activar a Gengar, usa un spritesheet o ZIP que tengas derecho a usar:

```powershell
python -m pip install -r requirements.txt
python tools\extract_gengar_frames.py --zip "C:\ruta\a\gengar.zip"
```

El script extrae los frames en `overlay/frames/<estado>/`. También acepta `--spritesheet`.

Después de extraerlos, reinicia DSH o cierra y vuelve a abrir el overlay para que cargue los frames nuevos.

## Cómo funciona

```
DSH Web UI
  └─ client.js (puente invisible)
       └─ GET /dsh-session-notifier/state
            └─ index.js (host) → state.json
                 ├─ Windows: %LOCALAPPDATA%\dsh-session-notifier\state.json
                 ├─ macOS:   ~/Library/Application Support/dsh-session-notifier/state.json
                 └─ Linux:   $XDG_STATE_HOME/dsh-session-notifier/state.json
                      └─ overlay/platforms.json → overlay nativo de la plataforma
```

- La actividad se obtiene del feed de eventos de la sesión (`tool/call`, `tool/result`, `turn/end`) cada 500 ms mientras hay una sesión en ejecución.
- El host escribe el estado en la ruta de la plataforma.
- La ruta interna solo acepta peticiones del mismo origen.
- La posición y la preferencia de sonido se guardan junto al estado.

## Mapeo de filas del spritesheet

| Fila | Uso |
|---|---|
| 1 | Reposo |
| 2 | Shell / comandos |
| 3 | Leer / buscar / inspeccionar |
| 4 | Aprobación / acción |
| 5 | Celebración / entusiasmo |
| 6 | Dormir, tristeza/error; poder reservado |
| 7 | Pensando / esperando |
| 8 | Escribiendo / edición |
| 9 | Felicidad / variaciones finales |

## Estructura

- `client.js`: puente invisible que lee las sesiones y publica el estado.
- `index.js`: host, ruta de estado y autoarranque según la plataforma.
- `overlay/platforms.json`: manifiesto que elige la implementación nativa.
- `overlay/windows/`: overlay WPF, mascota, animaciones y sonido.
- `overlay/macos/`: slot para la app AppKit (guía en `docs/MACOS.md`).
- `overlay/linux/`: slot para un overlay Linux.
- `overlay/frames/`: frames compartidos (no incluidos en el repo).
- `tools/extract_gengar_frames.py`: extractor de frames desde un ZIP/spritesheet propio.

## Licencia

El **código** está bajo licencia MIT. Ver [LICENSE](LICENSE).

Los derechos de **Gengar** pertenecen a Nintendo / Game Freak / The Pokémon Company. Este proyecto es no oficial y no distribuye sprites. Ver [NOTICE.md](NOTICE.md).

## Limitaciones

- El overlay completo actual es WPF/Windows: queda por encima de ventanas normales y de la mayoría de apps a pantalla completa, pero no de juegos en pantalla completa exclusiva.
- macOS y Linux están preparados en el manifiesto, pero el overlay nativo aún no está implementado; el puente de estado sí funciona.
- El overlay se inicia con DSH; no se inicia con el sistema por sí solo.
- La página de DSH debe estar abierta para que el estado se actualice en vivo. Si se cierra, el overlay conserva el último estado y luego pasa a reposo/sin conexión.
- No navega a una sesión concreta; enfoca DSH y la sesión se elige en la barra lateral.
