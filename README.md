<p align="center">
  <img src="UPSForza/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="UPS Forza">
</p>

<h1 align="center">UPS Forza para macOS</h1>

<p align="center">
  Monitor y apagado automático para la UPS <b>Forza NT-2402PRO</b>, nativo en Swift y SwiftUI.
</p>

---

La Forza NT-2402PRO se conecta por USB, pero **macOS no la reconoce como UPS**: usa un chip HID genérico con un protocolo propio (Voltronic-QS-Hex). Por eso no aparece en Ajustes → Batería y el sistema no apaga la Mac cuando se agota la batería.

Esta app habla directamente con la UPS. Muestra su estado en la barra de menús, avisa cuando se corta o vuelve la luz y **apaga la Mac de forma ordenada** antes de que se agote la batería.

## Funciones

- **Barra de menús:** el ícono muestra un enchufe cuando hay luz y la batería con su % durante un corte.
- **Panel de estado:** batería (voltaje y tiempo sin luz), voltaje de entrada y salida, consumo (en % y W estimados) y frecuencia.
- **Apagado automático:** se dispara con lo primero que ocurra:
  - la UPS indica batería baja,
  - la batería baja de un % mínimo,
  - pasan N minutos sin luz.

  Cada umbral se puede desactivar.
- **Aviso previo:** muestra un panel con cuenta regresiva, *Apagar ahora* y *Posponer 5 min*.
- **Notificaciones:** al cortarse y al volver la luz, en el aviso de apagado y al perder la comunicación con la UPS.
- **Desconexión segura:** si se pierde la comunicación, por ejemplo al desconectar el dock, avisa pero **no apaga la Mac**.
- **Alarma sonora:** se activa o silencia desde el panel o desde Ajustes, y se vuelve a aplicar cada vez que la app inicia o la UPS se reconecta.
- **Arranque automático** al iniciar sesión.
- **Test de batería:** comprueba que las baterías sostienen la carga (~6 s en batería), con referencia de salud, aviso de desgaste y test automático opcional.
- **Historial de la red:** cortes de luz y activaciones del AVR, voltaje de la red por día, gráficos y exportación a CSV.
- **Servicio en segundo plano (daemon root):** vigila la UPS aunque no haya sesión abierta y fuerza el apagado si una app lo bloquea.
- **Registro** de eventos y lecturas en `/Library/Logs/UPSForza/ups-forza.log` (con el servicio) o `~/Library/Logs/ups-forza.log` (sin él).
- **`upsctl`:** herramienta de línea de comandos para consultar la UPS y enviarle comandos.

## Requisitos

| | |
|---|---|
| macOS | 14 Sonoma o posterior |
| Xcode | 16 o posterior (Swift 6) |
| UPS | Forza NT-2402PRO por USB (VID `0x0665`, PID `0x5161`) |

No necesita drivers ni permisos especiales para leer la UPS.

## Instalación

```bash
git clone git@github.com:xreq403/ups-forza-macos.git
cd ups-forza-macos
scripts/build-app.sh --install
```

El script compila la versión Release, la copia a `/Applications/UPSForza.app` y la abre. Después:

1. Aceptá el permiso de **notificaciones**.
2. En **Ajustes → Sistema**, activá **Abrir al iniciar sesión**.
3. Revisá los umbrales en **Ajustes → Apagar la Mac**.
4. La primera vez que la app apague la Mac, macOS puede pedir permiso para controlar el sistema. Aceptalo.

La app se firma *ad-hoc* para uso personal. Para firmar con tu cuenta de desarrollador:

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build-app.sh --install
```

## Uso de `upsctl`

```bash
cd UPSKit
swift run upsctl                 # estado actual
swift run upsctl --loop 3        # refresca cada 3 s
swift run upsctl --json --loop 10 | tee descarga.jsonl   # registro con hora
swift run upsctl beeper off      # silencia la alarma (on para activarla)
swift run upsctl raw M           # envía un comando y muestra la respuesta cruda
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

Cerrá la app antes de usar `upsctl`, para que no compitan por el USB.

## Cómo funciona

```
UPS ──USB HID──▶ HIDTransport ──▶ QSParser ──▶ ShutdownEngine ──▶ UPSMonitor ──▶ UI · notificaciones · apagado
                 (IOKit)          (QS → estado)   (política)        (app)
```

- **Transporte:** cada comando ASCII terminado en `\r` se parte en bloques de 8 bytes y se envía como *output report*. La respuesta llega en *input reports* de 8 bytes hasta el `\r`.
- **Protocolo:** la UPS responde a `QS` con una trama binaria. Su formato coincide con el subdriver `voltronic-qs-hex` de [NUT](https://networkupstools.org): voltajes, consumo, frecuencia, batería y bits de estado.
- **Batería:** el % se estima con una curva de plomo-ácido para el banco de 24 V. Es orientativo, así que el apagado prioriza la señal de batería baja de la propia UPS.
- **Política de apagado:**
  - Un corte se confirma con dos lecturas seguidas.
  - Si vuelve la luz, se cancela el aviso.
  - Si macOS no completa el apagado, por ejemplo porque una app con cambios sin guardar lo bloquea, vuelve a avisar a los 2 minutos.

El protocolo y las pruebas con el equipo real están documentados en [spec.md](spec.md).

## Estructura del proyecto

```
UPSForza.xcodeproj      proyecto de la app
UPSForza/               app de barra de menús (SwiftUI)
UPSKit/                 paquete Swift: protocolo, HID, política de apagado, upsctl y tests
Support/                entitlements y logo fuente
scripts/                build e instalación, generador del ícono
discovery/              scripts Python usados para descubrir el protocolo
spec.md                 hallazgos técnicos del hardware y el protocolo
PLAN.md                 tecnología, arquitectura, alcance y avance
```

## Desarrollo

```bash
open UPSForza.xcodeproj          # ⌘R corre "UPS Forza Dev", ⌘U corre los tests
cd UPSKit && swift test          # tests sin Xcode
```

- **Debug y Release separadas:** la build Debug usa otro identificador (`com.xreq403.UPSForza.debug`), así no se mezcla con la versión instalada. No corras las dos a la vez, porque ambas consultan la UPS por USB.
- **Ajustes de la Debug:** para que la build Debug use tus ajustes, copiálos una vez:
  ```bash
  defaults export com.xreq403.UPSForza - | defaults import com.xreq403.UPSForza.debug -
  ```
- **Ícono:** para regenerarlo desde el logo:
  ```bash
  swift scripts/make-app-icon.swift Support/forza-logo.svg UPSForza/Assets.xcassets/AppIcon.appiconset
  ```

## Solución de problemas

| Problema | Solución |
|---|---|
| "UPS no detectada" | Revisá el cable USB y el dock. Con `swift run upsctl` podés confirmar si la Mac ve la UPS |
| Ícono gris en las notificaciones | macOS guardó el ícono de una copia vieja. Ejecutá `killall usernoted NotificationCenter` |
| La Mac no se apagó | Revisá el registro. Con el servicio activo, el apagado se fuerza a los 90 s; sin él, una app con cambios sin guardar puede bloquearlo y la app vuelve a avisar a los 2 min |
| Lecturas raras | Verificá que no haya dos instancias corriendo (la instalada y la de Xcode) |

## Hoja de ruta

- **Fase 1 — Monitoreo y protección:** completa y probada, incluido el apagado real.
- **Fase 2 — App completa:**
  - ✅ daemon root con apagado forzado,
  - ✅ historial de cortes y AVR,
  - dashboard con gráficos en vivo,
  - controles de test de batería y apagado de la UPS.
- **Fase 3 — Extras:**
  - estimación de autonomía,
  - asistente de calibración de la batería,
  - widget.

El detalle está en [PLAN.md](PLAN.md).

## Créditos

- [Network UPS Tools](https://github.com/networkupstools/nut): subdriver `nutdrv_qx_voltronic-qs-hex`, del que se tomaron las fórmulas de decodificación.
- [saper-2/py-upshid-voltqs](https://github.com/saper-2/py-upshid-voltqs): scripts Voltronic-QS de referencia.

Proyecto independiente, sin relación con Forza Power Technologies.

## Licencia

[MIT](LICENSE) © 2026 Eduardo Torres
