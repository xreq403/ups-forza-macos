#!/usr/bin/env python3
"""
Controlador para la UPS Forza NT-2402PRO
(chip INNO TECH "USB to Serial", VID 0x0665 / PID 0x5161, protocolo Voltronic-QS-Hex).

Basado en el subdriver de NUT `nutdrv_qx_voltronic-qs-hex.c`.

Uso como script:
    ./venv/bin/python forza_ups.py          # muestra el estado una vez
    ./venv/bin/python forza_ups.py --json   # salida en JSON
    ./venv/bin/python forza_ups.py --loop 5 # refresca cada 5 segundos
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict, dataclass

VID = 0x0665
PID = 0x5161

# Secuencias de escape del protocolo: 0x28 seguido de un código
_ESCAPES = {0x00: 0x0D, 0x01: 0x11, 0x02: 0x13, 0x03: 0x0A, 0x04: 0x20}

# Curva aproximada de descarga para banco de plomo-ácido de 24 V (2 x 12 V)
# con carga ligera (< 20 %). Pares (voltios, %). Con más carga el voltaje cae
# más, así que el % es solo orientativo: para apagar, confiar en el bit de
# "batería baja" de la UPS y/o en el tiempo transcurrido sin luz.
BATT_CURVE = [
    (25.2, 100),
    (24.9, 90),
    (24.6, 75),
    (24.3, 60),
    (24.0, 45),
    (23.6, 30),
    (23.0, 15),
    (22.0, 5),
    (21.0, 0),
]
# Por encima de esto, con luz, el cargador está en flotación (batería llena)
BATT_V_FLOAT = 26.8


@dataclass
class UPSStatus:
    input_voltage: float
    output_voltage: float
    load_percent: int
    frequency: float
    battery_voltage: float
    battery_percent: int
    charging: bool            # con luz, recargando tras un corte
    on_battery: bool          # corte de luz
    battery_low: bool         # la UPS indica batería baja
    avr_active: bool          # regulación boost/buck activa
    ups_fault: bool
    line_interactive: bool
    test_in_progress: bool
    shutdown_active: bool
    beeper_on: bool
    nominal_frequency: int | None = None
    nominal_battery_voltage: int | None = None
    nominal_output_voltage: int | None = None


class ProtocolError(Exception):
    pass


# ---------------------------------------------------------------- decodificación

def _tokenize(raw: bytes) -> list[bytes]:
    """Separa la respuesta en campos (separados por 0x20) y quita los escapes."""
    if not raw or raw[0] != ord("#"):
        raise ProtocolError(f"Respuesta inesperada: {raw!r}")
    body = raw[1:]
    cr = body.find(b"\r")
    if cr != -1:
        body = body[:cr]

    tokens: list[bytes] = []
    cur = bytearray()
    i = 0
    while i < len(body):
        b = body[i]
        if b == 0x20:                      # separador de campos
            tokens.append(bytes(cur))
            cur = bytearray()
        elif b == 0x28 and i + 1 < len(body) and body[i + 1] in _ESCAPES:
            cur.append(_ESCAPES[body[i + 1]])
            i += 1
        else:
            cur.append(b)
        i += 1
    tokens.append(bytes(cur))
    return tokens


def _u(b: bytes) -> int:
    return int.from_bytes(b, "big")


def battery_percent(volts: float, on_battery: bool) -> int:
    """Estimación del % de batería a partir del voltaje.

    Con luz, el voltaje lo impone el cargador y no refleja la carga real,
    así que se informa 100 %. En batería se interpola sobre BATT_CURVE.
    """
    if not on_battery:
        return 100
    if volts >= BATT_CURVE[0][0]:
        return 100
    for (v_hi, p_hi), (v_lo, p_lo) in zip(BATT_CURVE, BATT_CURVE[1:]):
        if volts >= v_lo:
            return round(p_lo + (volts - v_lo) / (v_hi - v_lo) * (p_hi - p_lo))
    return 0


def parse_qs(raw: bytes) -> UPSStatus:
    t = _tokenize(raw)
    if len(t) not in (10, 11):
        raise ProtocolError(f"Número de campos inesperado ({len(t)}): {raw!r}")

    # Fórmulas tomadas de NUT (voltronic-qs-hex)
    v_in = (_u(t[0]) * _u(t[1]) // 51) / 256.0
    v_out = (_u(t[2]) * _u(t[3]) // 51) / 256.0
    load = _u(t[4])
    freq = min(_u(t[6]) / _u(t[5]), 99.9) if _u(t[5]) else 0.0
    v_bat = (_u(t[7]) * _u(t[8])) / 510.0

    bits = f"{_u(t[9]):08b}"  # b7..b0
    on_batt = bits[0] == "1"

    st = UPSStatus(
        input_voltage=round(v_in, 1),
        output_voltage=round(v_out, 1),
        load_percent=load,
        frequency=round(freq, 1),
        battery_voltage=round(v_bat, 2),
        battery_percent=battery_percent(v_bat, on_batt),
        charging=(not on_batt) and v_bat < BATT_V_FLOAT,
        on_battery=on_batt,
        battery_low=bits[1] == "1",
        avr_active=bits[2] == "1",
        ups_fault=bits[3] == "1",
        line_interactive=bits[4] == "1",
        test_in_progress=bits[5] == "1",
        shutdown_active=bits[6] == "1",
        beeper_on=bits[7] == "1",
    )

    if len(t) == 11:  # protocolo 'T': incluye valores nominales
        r = f"{_u(t[10]):08b}"
        st.nominal_frequency = 60 if r[0] == "1" else 50
        st.nominal_battery_voltage = {"00": 12, "01": 24, "10": 36, "11": 48}[r[1:3]]
        st.nominal_output_voltage = {"000": 110, "001": 120, "010": 220,
                                     "011": 230, "100": 240}.get(r[5:8])
    return st


# ---------------------------------------------------------------- comunicación USB

class ForzaUPS:
    def __init__(self):
        import hid  # importado aquí para poder probar el parser sin hidapi
        self._hid = hid
        self.dev = None

    def open(self):
        self.dev = self._hid.device()
        self.dev.open(VID, PID)
        return self

    def close(self):
        if self.dev:
            self.dev.close()
            self.dev = None

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()

    def _flush(self):
        while self.dev.read(8, 50):
            pass

    def command(self, cmd: str, timeout: float = 3.0, expect_reply: bool = True) -> bytes:
        self._flush()
        data = (cmd + "\r").encode("ascii")
        for i in range(0, len(data), 8):
            n = self.dev.write(b"\x00" + data[i:i + 8].ljust(8, b"\x00"))
            if n < 0:
                raise OSError(f"Error escribiendo en la UPS: {self.dev.error()}")
        if not expect_reply:
            return b""
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            r = self.dev.read(8, 300)
            if r:
                buf += bytes(r)
                if b"\r" in buf:
                    return buf[:buf.index(b"\r") + 1]
        raise TimeoutError(f"Sin respuesta al comando {cmd!r}")

    def protocol(self) -> str:
        return self.command("M").strip(b"\r\x00").decode()

    def status(self) -> UPSStatus:
        return parse_qs(self.command("QS"))

    # --- comandos de control (usar con cuidado) ---
    def toggle_beeper(self):
        self.command("Q", expect_reply=False)

    def battery_test(self):
        self.command("T", expect_reply=False)

    def cancel_shutdown(self):
        self.command("C", expect_reply=False)

    def shutdown_and_return(self, minutes: float = 1):
        """Apaga la salida de la UPS tras `minutes` (0.2–9) y la vuelve a encender
        cuando regrese la luz."""
        m = f".{int(minutes * 10)}" if minutes < 1 else f"{int(minutes):02d}"
        self.command(f"S{m}", expect_reply=False)


# ---------------------------------------------------------------- CLI

def _print_status(st: UPSStatus):
    estado = "EN BATERÍA (corte de luz)" if st.on_battery else "Red eléctrica OK"
    print(f"Estado          : {estado}")
    print(f"Batería         : {st.battery_percent}%  ({st.battery_voltage:.2f} V)"
          + ("  (recargando)" if st.charging else "")
          + ("  ⚠ BATERÍA BAJA" if st.battery_low else ""))
    print(f"Carga           : {st.load_percent}%")
    print(f"Entrada/Salida  : {st.input_voltage} V / {st.output_voltage} V  @ {st.frequency} Hz")
    print(f"AVR activo      : {'sí' if st.avr_active else 'no'}")
    print(f"Falla UPS       : {'SÍ' if st.ups_fault else 'no'}")
    print(f"Alarma sonora   : {'activada' if st.beeper_on else 'desactivada'}")
    if st.nominal_output_voltage:
        print(f"Nominal         : {st.nominal_output_voltage} V / "
              f"{st.nominal_frequency} Hz / batería {st.nominal_battery_voltage} V")


def main():
    ap = argparse.ArgumentParser(description="Estado de la UPS Forza NT-2402PRO")
    ap.add_argument("--json", action="store_true", help="salida en JSON")
    ap.add_argument("--loop", type=float, metavar="SEG", help="refrescar cada SEG segundos")
    args = ap.parse_args()

    try:
        with ForzaUPS() as ups:
            if not args.json:
                print(f"Protocolo: {ups.protocol()}\n")
            while True:
                st = ups.status()
                if args.json:
                    print(json.dumps({"time": time.strftime("%Y-%m-%d %H:%M:%S"),
                                      **asdict(st)}, ensure_ascii=False), flush=True)
                else:
                    _print_status(st)
                if not args.loop:
                    break
                time.sleep(args.loop)
                if not args.json:
                    print("-" * 50)
    except KeyboardInterrupt:
        pass
    except OSError as e:
        sys.exit(f"No pude comunicarme con la UPS: {e}")


if __name__ == "__main__":
    main()
