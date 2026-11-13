# Linux overlay

Slot reservado para una implementación Linux. El host arrancará el ejecutable
`overlay/linux/dsh-session-notifier-overlay` cuando `linux.supported` sea `true`
en `overlay/platforms.json`.

Mientras no exista, el plugin se instala y el puente de estado funciona, pero no
hay mascota nativa en Linux.
