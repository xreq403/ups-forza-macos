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
- **Sin App Sandbox** y fuera del App Store. Firma *ad-hoc* (*Sign to Run Locally*), o con Apple ID de desarrollador eligiendo el *Team* en Xcode.
- **Apagado de la Mac:**
  - Fase 1: AppleEvent `kAEShutDown` a `loginwindow`, que es un apagado ordenado. Si falla, usa `osascript` a System Events.
  - Requiere el entitlement `com.apple.security.automation.apple-events`, por el runtime endurecido.
  - Fase 2: daemon root vía `SMAppService` para el apagado forzado.
- **Arranque automático:** ítem de inicio de sesión con `SMAppService.mainApp`, activable en Ajustes. Reemplaza el `LaunchAgent` del spec.
- **Ajustes:** en `UserDefaults` y editables desde la UI. Reemplaza el `config.toml` del spec.
- **Notificaciones:** `UNUserNotificationCenter`. El aviso de apagado es *time sensitive*.
- **Registro:** `~/Library/Logs/ups-forza.log` con los eventos y las lecturas.
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

```
UPSForza.xcodeproj          proyecto de la app (esquemas UPSForza, UPSKit, upsctl)
UPSForza/                   app de barra de menús, SwiftUI (carpeta sincronizada)
├── UPSForzaApp.swift          MenuBarExtra + Settings + ícono de la barra
├── UPSMonitor.swift           polling, eventos, alarma sonora, acciones
├── AppSettings.swift          claves y valores por defecto
├── Assets.xcassets            AppIcon
├── Views/                     popover, ajustes, aviso de apagado
└── System/                    notificaciones, apagado, log
UPSKit/                     paquete local Swift (sin UI, testeable)
├── Package.swift
├── Sources/UPSKit/
│   ├── UPSStatus.swift        modelo de estado + consumo estimado en W
│   ├── QSParser.swift         port de _tokenize / parse_qs
│   ├── BatteryEstimator.swift curva de plomo-ácido 24 V
│   ├── HIDTransport.swift     IOHIDManager, reports de 8 bytes
│   ├── ForzaUPS.swift         comandos M, QS, Q, T, C, S<n> + setBeeper
│   └── ShutdownEngine.swift   máquina de estados de la política de apagado
├── Sources/upsctl/         CLI equivalente a forza_ups.py, para probar el hardware
└── Tests/UPSKitTests/      parser, curva, consumo y política (27 tests)
Support/UPSForza.entitlements  automation.apple-events (runtime endurecido)
Support/forza-logo.svg      logo fuente del ícono
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
- **Apagado bloqueado:** si 2 minutos después de ordenar el apagado la Mac sigue encendida (alguna app lo bloqueó), se vuelve a avisar.

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
- [ ] Ventana principal con dashboard y gráficos en vivo (Swift Charts)
- [ ] Historial de eventos de la red (SwiftData), con exportación a CSV:
  - **Cortes de luz:** inicio, duración y voltaje mínimo de batería.
  - **Activaciones del AVR:** inicio, duración, tipo (*buck* si la salida es menor que la entrada, *boost* si es mayor) y voltajes de entrada y salida. Mide qué tan estable es la red.
  - **Resumen por día y semana:** cantidad de cortes, tiempo total sin luz, cantidad de activaciones del AVR, tiempo total con AVR y rango de voltaje de entrada (mín. y máx.).
- [ ] Controles: test de batería (`T`), cancelar apagado (`C`) y apagar la UPS con `S<n>`, con confirmación
- [ ] Helper daemon root (`SMAppService.daemon` + XPC): apagado forzado y funcionamiento sin sesión abierta

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

Antes de usar `upsctl`, conviene cerrar la app, para que no compitan por el USB.

### Problemas conocidos

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
| Modelo de Mac (portátil o escritorio) | — | Pendiente: si es de escritorio, adelantar el daemon root |
| Calibración de la curva | Curva del spec | Pendiente: prueba de descarga de 10–15 min |
