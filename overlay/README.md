# DSH Session Notifier — overlay nativo

Este overlay es un compañero de escritorio para Windows. Se ejecuta aparte de DeepSeek Harness y permanece por encima de las demás ventanas.

## Iniciar

Se inicia automáticamente al abrir DeepSeek Harness. También puedes abrirlo a mano con `Iniciar notificador.cmd`.

El lanzador ejecuta `dsh-session-notifier-overlay.ps1` con PowerShell en modo STA y sin consola visible.

## Uso

- **Arrastrar**: mantén pulsada la mascota y muévela.
- **Clic**: enfoca la ventana de DeepSeek Harness.
- **Clic derecho**: abre el menú para abrir DSH, activar/desactivar *Siempre visible*, activar/desactivar **Sonido**, reiniciar la posición o salir.
- **Zonas transparentes**: los clics fuera de la mascota, la insignia y la etiqueta pasan a la aplicación que esté debajo.

La posición se guarda en `%LOCALAPPDATA%\dsh-session-notifier\overlay-position.json`.
La preferencia de sonido se guarda en `%LOCALAPPDATA%\dsh-session-notifier\overlay-settings.json`.

## Estados

- **Reposo**: Gengar quieto, sin burbuja.
- **Pensando**: «Razonando...» con pose de espera.
- **Herramienta activa**: «Shell...», «Codeando...», «Escribiendo...», «Editando...», «Leyendo...», «Buscando...», «Esperando subagente...», etc.
- **Requiere aprobación / Esperando respuesta**: aura ámbar, insignia numérica, etiqueta y burbuja.
- **Finalizada**: Gengar feliz, aura verde, badge ✓ y burbuja «¡Listo!».
- **Celebración**: pose de entusiasmo con burbuja «¡Genial!».
- **Error**: Gengar triste, aura roja, badge `!` y burbuja «Algo falló».
- **Sin conexión**: duerme y oculta la burbuja si el estado lleva más de 30 segundos sin actualizarse.

La burbuja solo se muestra cuando hay actividad, una alerta, una finalización o un error; en reposo y sin conexión queda oculta.

## Mapeo de filas

| Fila | Uso |
|---|---|
| 1 | Reposo |
| 2 | Shell / comandos |
| 3 | Leer / buscar / inspeccionar |
| 4 | Aprobación / acción |
| 5 | Celebración / entusiasmo |
| 6 | Dormir, tristeza/error, poder |
| 7 | Pensando / esperando |
| 8 | Escribiendo / edición |
| 9 | Felicidad / variaciones finales |

La fila 5 real es más enérgica que «feliz»; se usa para celebración/entusiasmo. La fila 6 se usa para dormir y para el estado triste de error. La pose de «poder» de la fila 6 queda reservada para una acción especial.

## Sonido

Dos chimes suaves y distintos, generados en memoria:

- atención para una aprobación o pregunta pendiente;
- finalización para una sesión que termina.

El menú contextual permite silenciarlos.

## Varios chats

El overlay es un indicador agregado:

- los contadores suman todas las sesiones;
- la prioridad visual es aprobación/pregunta > error > finalizada > ejecutando > reposo;
- la burbuja describe la sesión principal, o la primera en ejecución si la principal está inactiva;
- el tooltip lista hasta 8 sesiones con título y motivo, y añade «… y N más» si hay más;
- el clic enfoca DSH; la sesión concreta se elige en la barra lateral.

Si DSH no tiene el foco y todas las sesiones en ejecución terminan, la mascota celebra durante 4 segundos aunque el contador de completadas sea 0.

## Puente de estado

El plugin de DSH escribe `%LOCALAPPDATA%\dsh-session-notifier\state.json` mediante la ruta interna `/dsh-session-notifier/state`. El overlay la lee cada 500 ms. Si cierras la página de DSH, el overlay conserva el último estado conocido y luego pasa a reposo/sin conexión.

## Gengar

El repositorio público no incluye los frames de Gengar. Usa un ZIP o spritesheet propio:

```powershell
python tools\extract_gengar_frames.py --zip "C:\ruta\a\gengar.zip"
```

Sin frames, el overlay usa una mascota genérica de respaldo. No se descargan imágenes de terceros. Reinicia DSH o vuelve a abrir el overlay después de extraerlos.

## Limitaciones

- Es una ventana WPF `Topmost`: queda por encima de ventanas normales y de la mayoría de apps a pantalla completa, pero no de juegos en pantalla completa exclusiva.
- Es un proceso independiente lanzado por el plugin de DSH; si cierras DSH, se cierra.
- No navega a una sesión concreta; enfoca DSH.
