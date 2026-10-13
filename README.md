<p align="center">
  <img src="UPSForza/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="UPS Forza">
</p>

<h1 align="center">UPS Forza para macOS</h1>

<p align="center">
  Monitor y apagado automático para la UPS <b>Forza NT-2402PRO</b>, nativo en Swift y SwiftUI.
</p>

---

La Forza NT-2402PRO se conecta por USB, pero **macOS no la reconoce como UPS**: usa un chip HID genérico con un protocolo propio (Voltronic-QS-Hex). Por eso no aparece en Ajustes → Batería y el sistema no apaga la Mac cuando se agota la batería.

Esta app habla directamente con la UPS. Muestra su estado en la barra de menús, avisa cuando se corta o vuelve la luz y **apaga la Mac de forma ordenada** antes de que se agote la batería, incluso sin sesión abierta.

## Funciones

**Monitoreo y protección**
- **Barra de menús:** el ícono muestra un enchufe cuando hay luz y la batería con su % durante un corte.
- **Popover:** batería (voltaje, tiempo sin luz, autonomía estimada o recarga), voltaje de entrada y salida, consumo (en % y W estimados) y frecuencia.
- **Apagado automático:** se dispara con lo primero que ocurra:
  - la UPS indica batería baja,
  - la batería baja de un % mínimo,
  - pasan N minutos sin luz.

  Cada umbral se puede desactivar.
- **Aviso previo:** panel con cuenta regresiva, *Apagar ahora* y *Posponer 5 min*.
- **Servicio en segundo plano (daemon root):** vigila la UPS aunque no haya sesión abierta y fuerza el apagado si una app lo bloquea.
- **Encender la Mac al volver la luz:** activa `pmset autorestart` desde Ajustes (la Mac arranca sola si el corte agotó la batería de la UPS).
- **Notificaciones:** al cortarse y al volver la luz (con la autonomía estimada), en el aviso de apagado y al perder la comunicación con la UPS.
- **Desconexión segura:** si se pierde la comunicación, por ejemplo al desconectar el cable USB, avisa pero **no apaga la Mac**.

**Batería**
- **Autonomía durante un corte:** "Apagado en ~N min" o "Quedan ~N min", según la última calibración y el consumo del corte.
- **Calibración de autonomía:** asistente que mide cómo baja la batería con tu consumo real, desenchufando la UPS de forma controlada.
- **Recarga:** tras un corte muestra el % estimado y el tiempo hasta la carga completa. Aprende el ritmo real del cargador con cada recarga.
- **Test de batería:** comprueba que las baterías sostienen la carga (~6 s en batería), con referencia de salud, aviso de desgaste y test automático opcional.
- **Alarma sonora:** se activa o silencia desde el popover o desde Ajustes, y se vuelve a aplicar cada vez que la UPS se reconecta.

**Datos**
- **Panel en vivo:** voltaje de la red, batería y consumo de la última hora, 6 h o 24 h, con los cortes sombreados.
- **Historial:** cortes, microcortes, activaciones del AVR, tests, calibraciones y recargas; voltaje de la red por día, gráficos y exportación a CSV.
- **Registro** de eventos y lecturas en `/Library/Logs/UPSForza/ups-forza.log` (con el servicio) o `~/Library/Logs/ups-forza.log` (sin él).
- **`upsctl`:** herramienta de línea de comandos para consultar la UPS y enviarle comandos.

## Requisitos

| | |
|---|---|
| macOS | 14 Sonoma o posterior |
| Xcode | 16 o posterior (Swift 6) |
| UPS | Forza NT-2402PRO por USB (VID `0x0665`, PID `0x5161`) |
| Firma | Certificado Apple Development (lo necesita el servicio en segundo plano) |

No necesita drivers ni permisos especiales para leer la UPS.

## Instalación

```bash
git clone git@github.com:xreq403/ups-forza-macos.git
cd ups-forza-macos
scripts/build-app.sh --install
```

El script compila la versión Release, la copia a `/Applications/UPSForza.app` y la abre. Después:

1. Acepta el permiso de **notificaciones**.
2. En **Ajustes → Servicio en segundo plano**, toca **Activar** y apruébalo en Ajustes del Sistema → General → Ítems de inicio y extensiones.
3. En **Ajustes → Sistema**, activa **Abrir al iniciar sesión**.
4. Revisa los umbrales en **Ajustes → Apagar la Mac** y, si quieres, **Encender la Mac al volver la luz**.
5. Opcional: haz una **calibración** (Ajustes → UPS → *Calibrar…*, 30 min o más) para tener la estimación de autonomía.

El proyecto firma con el equipo configurado en Xcode. Para usar otro equipo:

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build-app.sh --install
```

Al reinstalar, el servicio detecta la versión nueva y se reinicia solo en menos de un minuto.

## Uso de `upsctl`

```bash
cd UPSKit
swift run upsctl                 # estado actual
swift run upsctl --loop 3        # refresca cada 3 s
swift run upsctl --json --loop 10 | tee descarga.jsonl   # registro con hora
swift run upsctl beeper off      # silencia la alarma (on para activarla)
swift run upsctl raw M           # envía un comando y muestra la respuesta cruda
swift run upsctl battery-test    # test rápido de batería (T), con diagnóstico
swift run upsctl discharge-probe # ¿admite la UPS el test por tiempo (T01) y CT? (no: responde N)
```

```
Protocolo: T

Estado          : Red eléctrica OK
Batería         : 100%  (27.29 V)
Consumo         : 5%  (~60 W)
Entrada/Salida  : 237.2 V / 237.2 V  @ 50.0 Hz
AVR activo      : no
Falla UPS       : no
Alarma sonora   : activada
Bits de estado  : 00001001
Nominal         : 220 V / 50 Hz / batería 24 V
```

Antes de usar `upsctl`, cierra la app y desactiva el servicio en segundo plano, para que no compitan por el USB.

## Cómo funciona

```
UPS ──USB HID──▶ HIDTransport ──▶ QSParser ──▶ MonitorCore ──XPC──▶ App (UI · notificaciones · apagado ordenado)
                 (IOKit)          (QS → estado)  (daemon root: política, historial,
                                                  serie, calibración, recarga)
```

- **Transporte:** cada comando ASCII terminado en `\r` se parte en bloques de 8 bytes y se envía como *output report*. La respuesta llega en *input reports* de 8 bytes hasta el `\r`.
- **Protocolo:** la UPS responde a `QS` con una trama binaria. Su formato coincide con el subdriver `voltronic-qs-hex` de [NUT](https://networkupstools.org): voltajes, consumo, frecuencia, batería y bits de estado.
- **Daemon y app:** el daemon root es el dueño del monitoreo. La app es la interfaz: consulta el estado cada segundo por XPC y hace el apagado ordenado en la sesión del usuario. Sin el daemon, la app monitorea por su cuenta (modo local).
- **Batería:** el % se estima con una curva de plomo-ácido para el banco de 24 V. Es orientativo, así que el apagado prioriza la señal de batería baja de la propia UPS. Con luz, el voltaje lo impone el cargador: tras un corte, el % se estima por el ritmo de recarga.
- **Autonomía:** la calibración mide la pendiente del voltaje (V/min) con tu consumo; durante un corte se extrapola, escalada por el consumo del momento.
- **Política de apagado:**
  - Un corte se confirma con dos lecturas seguidas; una sola lectura en batería queda como microcorte.
  - Si vuelve la luz, se cancela el aviso.
  - Si el apagado ordenado no se completa, el daemon lo fuerza a los 90 s (sin el daemon, la app vuelve a avisar a los 2 min).

El protocolo y las pruebas con el equipo real están documentados en [spec.md](spec.md); la arquitectura y el avance, en [PLAN.md](PLAN.md).

## Estructura del proyecto

```
UPSForza.xcodeproj      proyecto de la app
UPSForza/               app de barra de menús (SwiftUI)
UPSForzaDaemon/         daemon root (XPC, apagado forzado)
UPSKit/                 paquete Swift: protocolo, HID, núcleo de monitoreo, historial, upsctl y tests
Support/                entitlements, plists de launchd y logo fuente
scripts/                build e instalación, generador del ícono
discovery/              scripts Python usados para descubrir el protocolo
spec.md                 hallazgos técnicos del hardware y el protocolo
PLAN.md                 tecnología, arquitectura, alcance y avance
```

## Desarrollo

```bash
open UPSForza.xcodeproj          # ⌘R corre "UPS Forza Dev", ⌘U corre los tests
cd UPSKit && swift test          # tests sin Xcode (79)
```

- **Debug y Release separadas:** la build Debug usa otro identificador (`com.xreq403.UPSForza.debug`) y su propio daemon, así no se mezcla con la versión instalada. Si el daemon de la Release está activo, la Debug lo usa en lugar de abrir el USB.
- **Ajustes de la Debug:** para que la build Debug use tus ajustes, cópialos una vez:
  ```bash
  defaults export com.xreq403.UPSForza - | defaults import com.xreq403.UPSForza.debug -
  ```
- **Daemon:**
  ```bash
  sudo launchctl print system/com.xreq403.UPSForza.daemon   # estado en launchd
  tail -f /Library/Logs/UPSForza/ups-forza.log               # registro
  ```
- **Ícono:** para regenerarlo desde el logo:
  ```bash
  swift scripts/make-app-icon.swift Support/forza-logo.svg UPSForza/Assets.xcassets/AppIcon.appiconset
  ```

## Solución de problemas

| Problema | Solución |
|---|---|
| "UPS no detectada" | Revisa el cable USB. Con `swift run upsctl` puedes confirmar si la Mac ve la UPS |
| El servicio queda "Requiere aprobación" | Apruébalo en Ajustes del Sistema → General → Ítems de inicio y extensiones. El "Operation not permitted" de la primera vez es esperable |
| Ícono gris en las notificaciones | macOS guardó el ícono de una copia vieja. Ejecuta `killall usernoted NotificationCenter` |
| La Mac no se apagó | Revisa el registro. Con el servicio activo, el apagado se fuerza a los 90 s; sin él, una app con cambios sin guardar puede bloquearlo y la app vuelve a avisar a los 2 min |
| No se puede iniciar la calibración | La batería tiene que estar llena: tras un corte, espera a que termine la recarga |
| Lecturas raras | Verifica que no haya dos instancias leyendo el USB (`upsctl` con el servicio activo, o la Debug en modo local junto a la Release) |

## Hoja de ruta

- **Fase 1 — Monitoreo y protección:** completa y probada, incluido el apagado real.
- **Fase 2 — App completa:** completa. Daemon root con apagado forzado, historial, panel en vivo, test de batería y encendido al volver la luz. Pendientes de verificar en uso real: el apagado sin sesión abierta y el arranque tras agotarse la batería.
- **Fase 3 — Extras:** completa. Calibración de autonomía, estimación durante un corte y recarga medida. El widget se descartó.

El detalle está en [PLAN.md](PLAN.md).

## Créditos

- [Network UPS Tools](https://github.com/networkupstools/nut): subdriver `nutdrv_qx_voltronic-qs-hex`, del que se tomaron las fórmulas de decodificación.
- [saper-2/py-upshid-voltqs](https://github.com/saper-2/py-upshid-voltqs): scripts Voltronic-QS de referencia.

Proyecto independiente, sin relación con Forza Power Technologies.

## Licencia

[MIT](LICENSE) © 2026 Eduardo Torres
