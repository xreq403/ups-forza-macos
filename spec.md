# UPS Forza NT-2402PRO — Monitor y apagado automático para macOS

> Especificación de hallazgos y objetivo del proyecto. Las decisiones de tecnología, la arquitectura y el avance están en [PLAN.md](PLAN.md).
> Carpeta del proyecto: `/Users/etorres/develop/claude/ups-forza`
> Última actualización: 2026-10-12

---

## 1. Objetivo

Construir un programa propio para macOS que:

1. Se comunique con la UPS **Forza NT-2402PRO** por USB, conectada a través del dock.
2. Monitoree en tiempo real el estado de la UPS: red eléctrica, batería, carga y voltajes.
3. **Apague la Mac de forma ordenada** antes de que la batería de la UPS se agote.
4. Avise al usuario con notificaciones de macOS cuando se corte o vuelva la luz.
5. Corra en segundo plano sin intervención manual. Se implementó como app de barra de menús con ítem de inicio de sesión.

**Fuera de alcance por ahora:** monitoreo por red (SNMP), múltiples equipos o integración con NUT como servidor.

---

## 2. Hardware

| Elemento | Detalle |
|---|---|
| UPS | Forza NT-2402PRO, line interactive, 2400 VA / 1200 W, onda senoidal modificada |
| Baterías | 2 × 12 V / 9 Ah en serie, banco de **24 V** |
| Salida nominal | 220 V / 50 Hz |
| Pantalla | No tiene; solo LEDs y alarma sonora |
| Comunicación | **USB**: cable incluido en la caja |
| Puertos RJ-45/RJ-11 | **Solo protección contra picos** para la línea de datos. No transmiten información de la UPS |
| Dock | CORSAIR TBT100 (Thunderbolt) |

### 2.1 Comportamiento del firmware (LEDs)

En modo batería, los LEDs indican: LED5 > 25 V, LED4 > 23 V, LED3 > 22 V, LED2 > 21 V. Si el LED1 parpadea cada segundo, significa **batería baja**. Esto da una referencia de los umbrales internos de la UPS: la batería se considera casi vacía alrededor de 21 V.

---

## 3. Hallazgos técnicos

### 3.1 Identificación USB

| Campo | Valor |
|---|---|
| Fabricante (USB) | `INNO TECH` |
| Producto (USB) | `USB to Serial` |
| Vendor ID | `0x0665` (1637) |
| Product ID | `0x5161` (20833) |
| Clase | HID, *usage page* `0xFF00` (definida por el fabricante), usage `0x01` |

**No es un USB HID Power Device estándar.** macOS no la reconoce como UPS: no aparece en Ajustes → Batería ni la apaga de forma nativa. Por eso hace falta un controlador propio.

### 3.2 Descriptor de reportes HID

```
06 00 ff 09 01 a1 01 09 02 15 00 26 ff 00 75 08 95 08 81 82 09 02 95 08 91 82 c0
```

- Input report: 8 bytes.
- Output report: 8 bytes.
- Sin report IDs, así que en `hidapi` se antepone el byte `0x00`.

### 3.3 Transporte

- **Envío:** el comando ASCII terminado en `\r` se parte en bloques de 8 bytes, rellenados con `0x00`, y cada bloque se envía como *output report* (`hid.write(b"\x00" + bloque)`). Que funcione con `send_feature_report` también es indiferente.
- **Recepción:** se leen *input reports* de 8 bytes hasta encontrar `\r`.
- **Librería (diagnóstico en Python):** `hidapi` (paquete pip `hidapi`) en un entorno virtual (`discovery/venv/`). En macOS funciona sin permisos especiales ni drivers adicionales.
- **Implementación en Swift:** IOKit nativo (`IOHIDManager`).
  - Cada bloque se envía con `IOHIDDeviceSetReport(…, kIOHIDReportTypeOutput, reportID 0, bloque, 8)`, sin anteponer `0x00`, porque eso es propio de hidapi.
  - Las respuestas llegan por el callback de *input reports*.

### 3.4 Protocolo: Voltronic-QS-Hex

Esta conclusión salió de un diagnóstico enviando distintos comandos:

| Comando | Respuesta | Significado |
|---|---|---|
| `Q1`, `F`, `I`, `QGS`, `QPI` | `N\r` | No soportado (no es Megatec/Q1 clásico) |
| `M` | `T\r` | Variante de protocolo **"T"** |
| `QS` | `#…\r` binario | Estado en formato **Voltronic-QS-Hex** |

El formato coincide exactamente con el subdriver de NUT `nutdrv_qx_voltronic-qs-hex.c`, del que se tomaron las fórmulas.

#### Formato de la respuesta a `QS`

```
'#' campo1 SP campo2 SP … campo11 '\r'
```

- Los campos están separados por `0x20` (espacio).
- **Escapes:** el byte `0x28` seguido de un código representa un byte reservado:
  `28 00`→`0D`, `28 01`→`11`, `28 02`→`13`, `28 03`→`0A`, `28 04`→`20`.
- Hay que **separar los campos primero y desescapar después**, porque un `28 04` dentro de un campo es un `0x20` de datos, no un separador.
- La variante "T" devuelve 11 campos. La variante "P" devuelve 10, porque no incluye el byte de valores nominales.

#### Decodificación (enteros big-endian)

| # | Campo | Fórmula |
|---|---|---|
| 1–2 | Voltaje de entrada | `(c1 × c2 // 51) / 256` |
| 3–4 | Voltaje de salida | `(c3 × c4 // 51) / 256` |
| 5 | Carga (consumo) | `c5`, en % de la potencia nominal. La app lo muestra como **Consumo** con un estimado en W: `c5 × 1200 / 100` |
| 6–7 | Frecuencia | `c7 / c6` (máximo 99,9) |
| 8–9 | Voltaje de batería | `(c8 × c9) / 510` |
| 10 | Bits de estado | ver tabla |
| 11 | Valores nominales | ver tabla (solo variante "T") |

**Bits de estado (campo 10, de b7 a b0):**

| Bit | Significado |
|---|---|
| b7 | Corte de luz (en batería) |
| b6 | **Batería baja** |
| b5 | AVR boost/buck activo |
| b4 | Falla de la UPS |
| b3 | Tipo line interactive |
| b2 | Test de batería en curso |
| b1 | Apagado programado activo |
| b0 | Alarma sonora activada |

**Valores nominales (campo 11, de b7 a b0):**

- b7 indica la frecuencia: `0` = 50 Hz, `1` = 60 Hz.
- b6–b5 indican la batería: `00` = 12 V, `01` = 24 V, `10` = 36 V, `11` = 48 V.
- b2–b0 indican el voltaje de salida: `000` = 110 V, `001` = 120 V, `010` = 220 V, `011` = 230 V, `100` = 240 V.

**Ejemplo real decodificado:**

```
raw : 23 6d 01 20 6c 20 6d 01 20 6c 20 04 20 60 28 03 20 12 c0 00 20 e9 20 3c 20 09 20 22 0d
→ 230,8 V entrada/salida · 4 % carga · 50,0 Hz · 27,41 V batería
  estado 00001001 (en red, line interactive, alarma activada)
  nominales 00100010 (50 Hz, 24 V, 220 V)
```

#### Comandos de control (según NUT)

| Comando | Acción |
|---|---|
| `Q` | Alterna la alarma sonora (sin respuesta). **Probado el 2026-10-12:** cambia el bit b0 del estado. No hay comandos separados para activar y desactivar: para fijar un estado hay que leer b0 y alternar solo si no coincide |
| `T` | Test rápido de batería |
| `C` | Cancela un apagado programado / enciende la salida |
| `S<n>` | Apaga la salida tras `n` minutos (`.2`–`.9` o `01`–`09`) y la reenciende al volver la luz |
| `S<n>R0000` | Apaga la salida tras `n` minutos y **no** la reenciende |

NUT acepta para el retardo de apagado un rango de 12 a 540 segundos.

### 3.5 Comportamiento de la batería (prueba de corte)

Prueba hecha el 2026-10-12, desenchufando la UPS de la red con una carga del 4–7 %:

| Momento | Voltaje batería |
|---|---|
| Con luz (flotación) | 27,29 V |
| Corte, muestra 1 | 26,12 V |
| Muestra 2 | 25,76 V |
| Muestra 3 | 25,41 V |
| Muestra 4 | 25,29 V |
| Muestra 5 | 25,18 V |
| Vuelve la luz | 25,76 V → sube gradualmente hasta ~27,1 V |

**Conclusiones:**

- La caída inicial (~2 V) es normal: desaparece el voltaje de flotación del cargador y se suma la caída por consumo. **No indica descarga real.** Las baterías se ven sanas.
- **Con luz, el voltaje no refleja la carga:** lo impone el cargador.
- Con la luz cortada, la carga sube del 4 % al 6–7 % por las pérdidas del inversor.
- Un cálculo lineal del porcentaje (20,8–26,0 V) daba lecturas falsas, como 84 % con la batería llena. Se reemplazó por una curva de plomo-ácido.

**Pruebas de corte con la app (2026-10-12):** varios cortes de 16 a 22 s desenchufando la UPS. La detección, el antirrebote, las notificaciones y el retorno de la luz funcionaron.

Lecturas durante el corte:

```
ent=8.5V sal=224.4V carga=6% bat=25.18–25.29V bits=10001000
```

- **La entrada no baja a 0 V con la luz cortada:** marca ~8,5 V residuales. Para detectar el corte hay que usar el bit b7, no el voltaje de entrada.
- La salida en batería es ~224 V, contra 235–239 V con luz.

### 3.6 Estimación del % de batería

Curva actual, interpolada linealmente y válida para carga ligera (< 20 %):

| Voltaje | % |
|---|---|
| ≥ 25,2 V | 100 |
| 24,9 V | 90 |
| 24,6 V | 75 |
| 24,3 V | 60 |
| 24,0 V | 45 |
| 23,6 V | 30 |
| 23,0 V | 15 |
| 22,0 V | 5 |
| ≤ 21,0 V | 0 |

- Con luz se informa 100 %. Si el voltaje está por debajo de 26,8 V, se marca como "recargando".
- **Es solo orientativa.** Hace falta una prueba de descarga más larga, de 10 a 15 minutos, para calibrarla y estimar la autonomía real.

---

## 4. Estado actual del código

La implementación es una app nativa en Swift. El detalle de la arquitectura está en [PLAN.md](PLAN.md).

| Ubicación | Propósito |
|---|---|
| `UPSKit/` | Paquete Swift: transporte HID (IOKit), decodificación de `QS`, curva de batería, comandos y política de apagado, con tests |
| `UPSKit/Sources/upsctl` | CLI equivalente a `forza_ups.py` (`--json`, `--loop N`, `raw CMD`, `beeper on\|off`) |
| `UPSForza/` + `UPSForza.xcodeproj` | App de barra de menús (SwiftUI) |
| `discovery/` | Scripts Python de diagnóstico, conservados como referencia |

**Scripts Python (`discovery/`):**

| Archivo | Propósito |
|---|---|
| `ups_probe.py` | Primer intento con protocolo Megatec Q1 (descartado) |
| `ups_debug.py` | Diagnóstico de bajo nivel: descriptor HID, métodos de envío y bytes crudos |
| `forza_ups.py` | Controlador de referencia: transporte HID, decodificación de `QS`, comandos de control y CLI |
| `venv/` | Entorno virtual con `hidapi` (no versionar) |

```bash
cd discovery
./venv/bin/python forza_ups.py --json --loop 10 | tee descarga.jsonl   # registro con hora
```

---

## 5. Requisitos del servicio de apagado (implementados en la Fase 1)

### 5.1 Lógica de decisión

El servicio consulta `QS` cada **N segundos** (propuesta: 5). Al detectar un corte (b7 = 1), registra la hora de inicio y notifica. **Inicia el apagado de la Mac cuando ocurra lo primero de esto:**

1. La UPS reporta **batería baja** (b6 = 1).
2. La batería estimada baja de **X %** (por defecto: 30 %).
3. Pasan **Y minutos** seguidos sin luz (por defecto: 10 min).

Cada umbral se puede desactivar en Ajustes.

Además:

- **Antirrebote:** un corte se confirma solo tras 2 lecturas consecutivas, para no reaccionar a microcortes.
- **Cancelación:** si vuelve la luz antes de alcanzar el umbral, se cancela el conteo y se notifica.
- **Aviso previo:** se notifica y se muestra un panel con cuenta regresiva 60 s antes de apagar, configurable. Ofrece *Apagar ahora* y *Posponer 5 min*; si la UPS indica batería baja, no se puede posponer.
- **Sin comunicación:** si se pierde el contacto con la UPS, por ejemplo al desconectar el dock, se notifica pero **no** se apaga.

### 5.2 Apagado de la UPS (opcional, a decidir)

Después de ordenar el apagado de la Mac, se puede enviar `S<n>` a la UPS. Así la UPS corta su salida tras `n` minutos y la reenciende sola al volver la luz. Si se combina con *Ajustes → Energía → Arrancar automáticamente tras un corte de luz* (`sudo pmset autorestart 1`), la Mac se recupera sin intervención.

### 5.3 Integración con macOS

| Tema | Propuesta original | Implementado |
|---|---|---|
| Ejecución | `LaunchAgent` o `LaunchDaemon` | App de barra de menús (`LSUIElement`) con ítem de inicio de sesión (`SMAppService.mainApp`). Daemon root en la Fase 2 |
| Apagado | `osascript` a System Events o `shutdown -h now` como root | AppleEvent `kAEShutDown` a `loginwindow` (ordenado), con `osascript` de respaldo |
| Notificaciones | `osascript` o `terminal-notifier` | `UNUserNotificationCenter` nativo, con el ícono de la app |
| Registro | `~/Library/Logs/ups-forza.log` | Igual: eventos y lecturas (cada 60 s con luz, en cada consulta durante un corte) |
| Configuración | `config.toml` | Ajustes en la app (`UserDefaults`) |

- **Apagado ordenado:** alguna app con cambios sin guardar puede bloquearlo. Si 2 minutos después la Mac sigue encendida, se vuelve a avisar.
- **Alarma sonora:** configurable. Se aplica a la UPS al iniciar, al reconectar y al cambiar el ajuste.

### 5.4 Ideas futuras

- Estimar la autonomía restante a partir de la pendiente del voltaje.
- Historial de cortes de luz.

El ícono en la barra de menús con el estado y el % ya está implementado.

---

## 6. Decisiones

- [x] Umbrales de apagado. Por defecto: batería baja de la UPS · < 30 % · 10 min sin luz. Configurados actualmente: batería baja de la UPS · < 10 % · sin límite de minutos.
- [x] LaunchAgent o LaunchDaemon: ítem de inicio de sesión ahora; daemon root en la Fase 2 para el apagado forzado.
- [x] Notificaciones: `UNUserNotificationCenter` nativo.
- [x] Alarma sonora: configurable desde la app (`Q` probado).
- [ ] ¿Apagar también la UPS tras apagar la Mac (`S<n>`)? ¿Con qué retardo?
- [ ] Probar el apagado real de la Mac desde la app.
- [ ] Hacer una prueba de descarga de 10 a 15 minutos para calibrar la curva y medir la autonomía.
- [ ] Probar en el equipo real los comandos de control `T`, `C` y `S`.
- [ ] Modelo de Mac: si es portátil, tiene batería propia y eso cambia la urgencia del apagado.

---

## 7. Referencias

- NUT, subdriver Voltronic-QS-Hex: <https://github.com/networkupstools/nut/blob/master/drivers/nutdrv_qx_voltronic-qs-hex.c>
- NUT, manual de `nutdrv_qx`: <https://www.networkupstools.org/docs/man/nutdrv_qx.html>
- Scripts Voltronic-QS de saper-2: <https://github.com/saper-2/py-upshid-voltqs>
- Especificaciones de la NT-2402PRO (Pana Compu): <https://www.panacompu.com/peru/en/product-information/forza-nt-2402pro-ups-220v-outlets-10x-nema-5-15r-rj-4511-2400va1200w-12v9ah2-battery-1000j>
