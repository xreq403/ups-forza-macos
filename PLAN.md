# UPS Forza — Plan de tecnología y alcance

> Complementa a [spec.md](spec.md) (hallazgos del protocolo y requisitos).
> Creado: 2026-10-12 · Última actualización: 2026-10-12

---

## 1. Tecnología elegida

**App nativa de macOS en Swift + SwiftUI.**

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Swift + SwiftUI** | Look nativo, `MenuBarExtra`, Swift Charts, notificaciones nativas, IOKit HID sin dependencias, bajo consumo, `SMAppService` para login item y daemon | Hay que portar unas 150 líneas de Python | ✅ Elegida |
| Python + `rumps`/PyObjC | Reusa el código tal cual | UI anticuada, empaquetado frágil (py2app) | ❌ |
| Tauri / Electron | UI web flexible | Pesado para una app de barra de menús; HID por un puente Rust/Node; look no nativo | ❌ |

El código Python (`discovery/forza_ups.py`) queda como **referencia** del protocolo. La trama real del spec se usa como **test unitario** para validar el port.

### Decisiones técnicas

- **Lenguaje y toolchain:** Swift 6 y Xcode.
  - La app es un **proyecto Xcode** (`UPSForza.xcodeproj`) con Info.plist generado desde *Build Settings*.
  - La lógica vive en el **paquete local `UPSKit`**, que también se compila y testea por separado con `swift`.
- **macOS mínimo:** 14 (Sonoma). Hace falta para `@Observable` y `openSettings`. Probado en macOS 27.
- **USB HID:** IOKit nativo (`IOHIDManager`), sin hidapi.
  - No necesita drivers ni permisos, porque la página de uso es `0xFF00`, definida por el fabricante.
  - Los callbacks de conexión y desconexión resuelven el caso del dock desconectado.
- **Sin App Sandbox** y fuera del App Store. Firma manual con el certificado **Apple Development** del equipo `L77R5X2WV6` (Eduardo Torres). La firma con equipo es obligatoria para el daemon: la app y el daemon validan entre sí su firma.
- **Apagado de la Mac:**
  - Fase 1: AppleEvent `kAEShutDown` a `loginwindow`, que es un apagado ordenado. Si falla, usa `osascript` a System Events.
  - Requiere el entitlement `com.apple.security.automation.apple-events`, por el runtime endurecido.
  - Fase 2: el daemon root fuerza `shutdown -h now` si el apagado ordenado no se completa en 90 s, o de inmediato si no hay sesión con la app abierta.
- **Arranque automático:** ítem de inicio de sesión con `SMAppService.mainApp`, activable en Ajustes. Reemplaza el `LaunchAgent` del spec.
- **Ajustes:** en `UserDefaults` y editables desde la UI. Reemplaza el `config.toml` del spec.
- **Notificaciones:** `UNUserNotificationCenter`. El aviso de apagado es *time sensitive*.
- **Registro:** `/Library/Logs/UPSForza/ups-forza.log` con el daemon activo; `~/Library/Logs/ups-forza.log` en modo local. Eventos y lecturas.
  - Las lecturas se guardan cada 60 s con luz y en cada consulta durante un corte, lo que sirve para calibrar la curva.
  - Rota a `ups-forza.1.log` al superar 5 MB.

### Builds Debug y Release

| | Debug (Xcode ⌘R) | Release (`scripts/build-app.sh`) |
|---|---|---|
| Bundle id | `com.xreq403.UPSForza.debug` | `com.xreq403.UPSForza` |
| Nombre visible | UPS Forza Dev | UPS Forza |
| Ubicación | DerivedData de Xcode | `/Applications/UPSForza.app` |
| Ajustes | dominio propio (`…debug`) | dominio propio |

Los bundle id distintos evitan que macOS mezcle las dos copias, por ejemplo en el ícono de las notificaciones.

- **No correr las dos a la vez:** ambas consultan la misma UPS por USB y las respuestas se pueden mezclar.
- **Ajustes al usar Debug por primera vez:** copiar los ajustes de la Release con
  `defaults export com.xreq403.UPSForza - | defaults import com.xreq403.UPSForza.debug -`.
  Si no, la Debug arranca con los valores por defecto, por ejemplo con la alarma activada.

## 2. Arquitectura

### Daemon root y app

```
UPSForza.app
├── Contents/MacOS/UPSForza            app (UI): popover, ajustes, notificaciones, aviso, apagado ordenado
├── Contents/MacOS/UPSForzaDaemon      daemon root: lee la UPS, aplica la política, fuerza el apagado
└── Contents/Library/LaunchDaemons/    com.xreq403.UPSForza[.debug].daemon.plist (SMAppService)

App ──XPC (JSON)──▶ Daemon:  snapshot (estado + eventos), ajustes, posponer, apagar ahora
```

- **Núcleo compartido (`MonitorCore`):** el sondeo, la política, la alarma, el registro y la ejecución del apagado viven en `UPSKit`, sin UI. Lo usan el daemon y, como respaldo, la app.
- **Quién monitorea:**
  - El daemon, si está activo.
  - Si no, el daemon de la otra build (Release/Debug) si está corriendo.
  - Si no, la app en modo local.
  - **Nunca dos a la vez**, para no competir por el USB.
- **La app es cliente:** consulta el snapshot cada 1 s, envía los ajustes (`UserDefaults` → daemon) y reacciona a los eventos con notificaciones, el panel de aviso y el apagado ordenado. Los eventos tienen id; al conectarse no se repiten los viejos, y un `shutdownNow` de hace más de 60 s se ignora.
- **Apagado con daemon:**
  - La app intenta el apagado ordenado.
  - Si a los 90 s la Mac sigue encendida, el daemon ejecuta `shutdown -h now`.
  - Sin app conectada en los últimos 10 s (sin sesión, o con la app cerrada), el daemon apaga directamente al vencer el aviso.
- **Seguridad XPC:**
  - El daemon solo acepta clientes que cumplan el requisito: firma Apple, OU `L77R5X2WV6` e identificador de la app (Release o Debug).
  - La app solo acepta el daemon con identificador `com.xreq403.UPSForza.daemon` del mismo equipo.
- **Ajustes del daemon:** se guardan en `/Library/Application Support/UPSForza/settings.json` para funcionar sin sesión. En el primer arranque, sin ajustes guardados, el daemon no toca la alarma hasta recibir los del usuario.
- **Actualización:** al reinstalar la app, el daemon detecta que su ejecutable cambió (inodo y fecha, vía `proc_pidpath`) y sale. launchd (`KeepAlive`) levanta la versión nueva en menos de 60 s.
- **Activación:**
  - En Ajustes → *Servicio en segundo plano* → *Activar*. Después hay que aprobarlo en Ajustes del Sistema → General → Ítems de inicio y extensiones.
  - La primera vez `register()` devuelve "Operation not permitted" hasta que se aprueba. Es esperable.

### Archivos

```
UPSForza.xcodeproj          proyecto de la app (esquemas UPSForza, UPSKit, upsctl)
UPSForza/                   app de barra de menús, SwiftUI (carpeta sincronizada)
├── UPSForzaApp.swift          MenuBarExtra + Settings + ícono de la barra
├── UPSMonitor.swift           polling, eventos, alarma sonora, acciones
├── AppSettings.swift          claves y valores por defecto
├── Assets.xcassets            AppIcon
├── Views/                     popover, ajustes, aviso de apagado, historial (Swift Charts)
└── System/                    notificaciones, apagado, backends (local / XPC), registro del daemon
UPSForzaDaemon/main.swift   daemon root: XPC, ajustes persistidos, apagado forzado, autoactualización
UPSKit/                     paquete local Swift (sin UI, testeable)
├── Package.swift
├── Sources/UPSKit/
│   ├── UPSStatus.swift        modelo de estado + consumo estimado en W
│   ├── QSParser.swift         port de _tokenize / parse_qs
│   ├── BatteryEstimator.swift curva de plomo-ácido 24 V
│   ├── HIDTransport.swift     IOHIDManager, reports de 8 bytes
│   ├── ForzaUPS.swift         comandos M, QS, Q, T, C, S<n> + setBeeper
│   ├── ShutdownEngine.swift   máquina de estados de la política de apagado
│   ├── MonitorCore.swift      núcleo de monitoreo compartido (daemon y app)
│   ├── DaemonProtocol.swift   interfaz XPC e identidades de firma
│   ├── History.swift          historial (JSONL) y resumen por día
│   ├── LogImporter.swift      reconstruye el historial desde los registros de texto
│   └── EventLog.swift         registro en archivo
├── Sources/upsctl/         CLI equivalente a forza_ups.py, para probar el hardware
└── Tests/UPSKitTests/      parser, curva, consumo, política, núcleo con UPS simulada e historial (46 tests)
Support/UPSForza.entitlements  automation.apple-events (runtime endurecido)
Support/forza-logo.svg      logo fuente del ícono
Support/LaunchDaemons/      plists de launchd del daemon (Release y Debug)
scripts/build-app.sh        xcodebuild Release → build/UPSForza.app (--install a /Applications)
scripts/make-app-icon.swift genera AppIcon desde el SVG
discovery/                  scripts Python de diagnóstico (referencia)
```

### Interfaz

- **Ícono de la barra de menús:**
  - Enchufe con luz.
  - Batería con el % durante un corte.
  - Triángulo de alerta ante batería baja, falla, aviso de apagado o sin comunicación.
- **Popover:**
  - Estado (Red eléctrica / En batería / Apagando / Sin conexión).
  - Gauge de batería con voltaje y tiempo sin luz.
  - Entrada, salida, **consumo** (% y W estimados sobre 1200 W) y frecuencia.
  - Control de **alarma** al estilo del Centro de Control.
  - Chips de falla, AVR, batería baja o test en curso, solo cuando aplican.
- **Aviso de apagado:** panel flotante en todos los Spaces con cuenta regresiva, *Apagar ahora* y *Posponer 5 min*.
- **Ajustes:**
  - Umbrales de apagado y aviso previo.
  - Intervalo de consulta.
  - Abrir al iniciar sesión.
  - Servicio en segundo plano: estado, activar o desactivar y aprobación.
  - Notificación de prueba y mostrar el registro.
  - Alarma sonora, sincronizada con el control del popover.
  - Datos de la UPS: protocolo y valores nominales.

### Política de apagado (`ShutdownEngine`)

Estados: `unknown → online ⇄ onBattery → warning → shuttingDown`.

- **Confirmación del corte:** hacen falta **2 lecturas consecutivas** en batería (antirrebote). El bit de batería baja de la UPS lo confirma de inmediato.
- **Disparo del aviso:** con lo primero que ocurra: **batería baja de la UPS**, **% < mínimo** o **minutos sin luz**. Cada umbral se puede desactivar.
- **Aviso:** cuenta regresiva (60 s por defecto) con *Apagar ahora* o *Posponer 5 min*. Con batería baja de la UPS no se puede posponer.
- **Vuelve la luz:** se cancela el aviso y se notifica la duración del corte.
- **Sin comunicación** (2 fallas seguidas): se notifica, se aborta el aviso y **no se apaga**.
- **Apagado bloqueado:** con el daemon, se fuerza a los 90 s. Sin el daemon (modo local), si 2 minutos después la Mac sigue encendida, se vuelve a avisar.

### Historial

- **Dónde vive:** lo registra `MonitorCore`, así que el daemon lo guarda aunque no haya sesión. Se guarda en `HistoryStore` (`UPSKit/History.swift`), un archivo **JSONL de solo agregar**:
  - con el daemon: `/Library/Application Support/UPSForza/history.jsonl`,
  - en modo local: `~/Library/Application Support/UPSForza/history.jsonl`.
- **Por qué no SwiftData:** el dueño es el daemon root, y la app no puede abrir de forma segura una base SQLite que otro proceso escribe. La app pide el historial por XPC (`history(days:)`).
- **Cuándo escribe:** al empezar y terminar cada episodio, al ordenar el apagado (antes del `shutdown`, para que el corte quede cerrado aunque la Mac se apague) y cada 10 min durante episodios en curso.
- **Mantenimiento:** al cargar se compacta (la última versión de cada episodio gana) y se descarta lo de más de 365 días.
- **Episodios sin cerrar** (el monitor se detuvo a mitad de un corte): se muestran "sin cierre".
- **Importación:** `LogImporter` reconstruye cortes (de "CORTE"/"VOLVIÓ"/"APAGANDO"), AVR (del bit b5 de las lecturas) y voltaje diario a partir de `ups-forza.log`. El daemon importa su registro y los de la app de cada usuario.

### Alarma sonora

La UPS solo tiene `Q`, que **alterna** la alarma. Para fijar un estado, `setBeeper` hace esto:

1. Lee el bit b0.
2. Envía `Q` solo si el bit no coincide con el ajuste.
3. Vuelve a leer para verificar.

**Cuándo se aplica el ajuste:**
- Al iniciar la app.
- Al reconectar la UPS.
- Al cambiar el ajuste.
- Si la UPS vuelve a otro estado por su cuenta.

Tras 3 intentos fallidos deja de insistir hasta el próximo cambio o reconexión, para no quedar alternando.

## 3. Alcance por fases

### Fase 1 — MVP: monitoreo y protección
- [x] Plan de tecnología y alcance (este documento)
- [x] `UPSKit`: parser portado con tests contra la trama real
- [x] `UPSKit`: transporte HID con IOKit y comandos
- [x] `UPSKit`: `ShutdownEngine` con tests
- [x] CLI `upsctl` para validar el transporte contra el equipo real
- [x] Proyecto Xcode con `UPSKit` como paquete local; builds Debug y Release separadas
- [x] App de barra de menús: ícono con estado y %, popover con métricas
- [x] Consumo con watts estimados
- [x] Aviso de apagado con cuenta regresiva (*Apagar ahora* / *Posponer*)
- [x] Notificaciones: corte, retorno, aviso y pérdida de comunicación, más una notificación de prueba desde Ajustes
- [x] Ajustes: umbrales, intervalo y abrir al iniciar sesión (el modo simulación se usó para las pruebas y se quitó)
- [x] Log de eventos y lecturas
- [x] Alarma sonora configurable desde Ajustes y desde el control del popover (`Q` probado en el equipo)
- [x] Script de empaquetado e instalación en `/Applications`
- [x] Ícono de la app generado desde `Support/forza-logo.svg`
- [x] Prueba en el equipo real: `upsctl` (estado y protocolo `T` OK) y la app leyendo la UPS
- [x] Prueba de corte real: detección, notificaciones y retorno de la luz (2026-10-12)
- [x] Verificar el ícono en las notificaciones de la versión instalada
- [x] Prueba de apagado real (2026-10-13): aviso a los 2 min sin luz, apagado a los 60 s y la Mac se apagó correctamente

### Fase 2 — App completa
- [x] Daemon root (`SMAppService.daemon` + XPC): monitoreo con privilegios, apagado forzado y funcionamiento sin sesión abierta (2026-10-13)
- [x] Prueba del apagado forzado (2026-10-13): con una app bloqueando el apagado ordenado, el daemon apagó la Mac a los 90 s. El registro ahora se vacía antes del `shutdown`, porque la línea del apagado forzado se perdía
- [ ] Prueba sin sesión: cerrar sesión, cortar la luz y verificar que el daemon apague
- [x] Panel en vivo (2026-10-13). La ventana **UPS Forza** tiene dos pestañas, *Panel* e *Historial*, y se abre desde el módulo *Panel* del popover:
  - **Serie temporal** (`UPSKit/Series.swift`, en `MonitorCore`, la registra el daemon):
    - cada lectura de la última hora;
    - agregados por minuto de las últimas 24 h (mín/prom/máx), guardados en `series.json` cada 5 min para sobrevivir a reinicios.
    - Por XPC: `series(minutes:)`.
  - **Vista:**
    - valores actuales;
    - tres gráficos separados (voltaje de red con entrada/salida, batería, consumo en W) para 1 h / 6 h / 24 h;
    - cortes sombreados; la entrada se corta durante el corte (no se grafican los ~8,5 V residuales);
    - línea vertical con tooltip, compartida por los tres gráficos;
    - par de colores entrada/salida validado (azul/rosa, también con daltonismo).
  - Se actualiza cada 5 s (1 h) o cada minuto (6 h y 24 h).
- [x] Historial de eventos de la red (2026-10-13), con exportación a CSV:
  - **Cortes de luz:** inicio, fin, voltaje y % mínimos de batería, consumo máximo y, si terminó con la Mac apagada, el motivo.
  - **Activaciones del AVR:** inicio, fin, tipo (*reducción* si la salida es menor que la entrada, *elevación* si es mayor) y voltajes de entrada y salida.
  - **Voltaje de la red por día:** mínimo, promedio y máximo de la entrada (solo con luz).
  - **Ventana Historial** (popover → *Historial...*):
    - resumen del período (7 / 30 / 90 días),
    - gráficos de tiempo sin luz y de activaciones del AVR por día,
    - lista de episodios y tabla por día,
    - exportación a CSV de episodios o resumen diario.
  - **Borrar datos** (Historial → *Borrar…*, o Ajustes → Sistema), con confirmación: solo el historial, o el historial y los registros de texto. Después no se vuelve a importar.
  - **Importación inicial:** al crearse, el historial se reconstruye a partir de los registros de texto existentes. Los episodios importados se marcan "del registro" porque son aproximados.
- [x] Recuperación tras un corte (2026-10-13): **Encender la Mac al volver la luz** (`pmset autorestart`, lo lee y cambia el daemon root). Quedó activado en la Mac mini.
  - Se implementó y probó el apagado programado de la salida (`S<n>`), pero **la NT-2402PRO lo rechaza** (responde `N` con luz y en batería; ver spec.md §3.4). Se quitó de la app.
  - Por eso la Mac arranca sola solo si el corte agota la batería de la UPS; si la luz vuelve antes, queda apagada. Se descartó el encendido programado (`pmset schedule poweron`).
- [ ] Prueba de recuperación con `autorestart`: verificar que, tras agotarse la batería, la UPS restablece la salida al volver la luz y la Mac arranca sola
- [x] Validación del test de batería (`T`) en la UPS real (2026-10-13, `upsctl battery-test`): funciona, marca b2 ~6 s, **no activa b7** y la batería cae a ~26,0 V con ~6 % de consumo (ver spec.md §3.4)
- [x] Test de batería en la app (2026-10-13):
  - **Ajustes → UPS → Test de batería:** botón *Probar ahora…* que abre una hoja (explicación → progreso → resultado con voltajes, caída, consumo y comparación con la referencia); la fila muestra el último resultado. No está en el popover, por decisión de diseño.
  - **Núcleo** (`MonitorCore.runBatteryTest`): envía `T`, sigue b2 cada 1 s, mide el voltaje mínimo y el consumo, y detecta batería baja o falla. Solo con luz, comunicación y fase normal.
  - **Salud:** el primer test superado es la **referencia**. Un test posterior con consumo parecido (±5 puntos) y voltaje mínimo 0,4 V por debajo de la referencia se marca **desgaste**; batería baja o falla durante el test es **falla**.
  - **Historial:** cada test queda guardado (no se descarta por antigüedad, porque la referencia puede tener años). Aparece en la lista de episodios y en el CSV.
  - **Automático** (Ajustes → UPS → *Test de batería automático*: desactivado, cada semana o cada mes): solo con 10 min de luz estable. Notifica solo si hay falla, desgaste o la UPS no inició el test.
- [x] Primer test desde la app (2026-10-13, en modo local): referencia **26,00 V** (caída 1,29 V, consumo 6 %); el segundo dio OK
- [x] Fusión del historial local al activar el daemon: la app envía su `history.jsonl` (`mergeHistory` por XPC), se fusiona sin duplicar por id y se renombra a `history.merged.jsonl`
- [x] Un solo historial visible en los dos modos:
  - **Al pasar a modo local**, la app arranca con una copia del historial del daemon. El archivo es legible por los usuarios, así que funciona aunque el servicio se desactive desde Ajustes del Sistema.
  - **Los registros de texto** solo se importan si no existe ningún historial (local, fusionado o del daemon); así se evitan duplicados con ids nuevos.
  - **Estadística diaria al fusionar:** gana la versión con más muestras, no la suma.
- [x] Microcortes (2026-10-13): lecturas en batería que no llegaron a confirmarse como corte (vuelve la luz antes de la 2.ª lectura). Se registran en el historial (lista, tabla por día, CSV y "+ N microcortes" en el resumen), sin notificar ni afectar el apagado

### Fase 3 — Extras
- [ ] Estimación de autonomía por la pendiente del voltaje
- [ ] Asistente para la prueba de descarga y la calibración de la curva
- [ ] Widget (escritorio o Centro de Control)

**Fuera de alcance:** SNMP o red, varias UPS, servidor NUT y App Store.

## 4. Cómo compilar y correr

```bash
open UPSForza.xcodeproj             # desarrollar: Run (⌘R) = "UPS Forza Dev", tests (⌘U)
scripts/build-app.sh                # arma build/UPSForza.app (Release)
scripts/build-app.sh --install      # la copia a /Applications y la abre
swift scripts/make-app-icon.swift Support/forza-logo.svg UPSForza/Assets.xcassets/AppIcon.appiconset [blue|light]
cd UPSKit && swift test             # tests sin Xcode
cd UPSKit && swift run upsctl       # estado de la UPS (también --json, --loop N, raw CMD, beeper on|off)
```

Antes de usar `upsctl`, conviene cerrar la app y desactivar el servicio, para que no compitan por el USB.

**Daemon:**

```bash
sudo launchctl print system/com.xreq403.UPSForza.daemon   # estado en launchd
tail -f /Library/Logs/UPSForza/ups-forza.log               # registro del daemon
```

### Problemas conocidos

- **Aislamiento en `UPSForzaDaemon/main.swift`:** en Swift 6, el código de nivel superior está aislado al MainActor. Un closure de ahí que se ejecuta en otra cola (p. ej. un `DispatchSource` en `.global()`) aborta el proceso con `dispatch_assert_queue_fail`. Pasó el 2026-10-13 y el daemon se reiniciaba cada 60 s. Los temporizadores van en `.main`, y las funciones que llama `MonitorCore` se declaran `nonisolated`.
- **"Operation not permitted" al activar el servicio:** es la respuesta normal de `register()` antes de la aprobación. Al aprobarlo queda *Activo*.
- **Ícono gris en las notificaciones:** macOS asocia las notificaciones con la copia de la app que registró primero el bundle id.
  - El build script saca del registro las copias intermedias de DerivedData.
  - Si persiste, reiniciar el servicio con `killall usernoted NotificationCenter`.
  - Último recurso: cambiar el bundle id de la Release, lo que obliga a volver a dar permiso de notificaciones.

## 5. Decisiones

| Tema | Valor | Estado |
|---|---|---|
| Umbrales por defecto (código) | batería baja UPS · < 30 % · 10 min sin luz | Tomada |
| Umbrales configurados (equipo actual) | batería baja UPS · < 10 % · minutos sin luz desactivado | Elegidos por el usuario en Ajustes |
| Aviso previo | 60 s | Tomada |
| Intervalo de consulta | 5 s | Tomada |
| Alarma sonora | Configurable; actualmente silenciada | Tomada |
| Modo simulación | Quitado tras las pruebas | Tomada |
| macOS mínimo | 14 | Tomada |
| Variante del ícono | Azul con la F blanca | Tomada |
| Apagar la UPS con `S<n>` | No (Fase 2, tras probar los comandos) | Pendiente |
| Modelo de Mac | Mac mini M4 Pro (escritorio) → daemon root primero | Tomada |
| Arquitectura del daemon | Dueño del monitoreo; la app es la UI | Tomada |
| Firma | Apple Development, equipo `L77R5X2WV6` | Tomada |
| Margen antes de forzar el apagado | 90 s | Tomada |
| Calibración de la curva | Curva del spec | Pendiente: prueba de descarga de 10–15 min |
