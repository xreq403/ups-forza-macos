#!/usr/bin/env python3
"""
Prueba de comunicación con la UPS Forza NT-2402PRO
(chip INNO TECH "USB to Serial", VID 0x0665, protocolo Megatec / Q1).

Uso:
    pip3 install hidapi
    python3 ups_probe.py
"""
import sys
import time

try:
    import hid
except ImportError:
    sys.exit("Falta la librería hidapi. Instálala con:  pip3 install hidapi")

VID = 0x0665
PID_CANDIDATOS = [0x5161]  # el más común para INNO TECH; se autodetecta si es otro


def buscar_ups():
    for info in hid.enumerate():
        if info["vendor_id"] == VID:
            return info
    return None


def abrir_ups(info):
    dev = hid.device()
    dev.open_path(info["path"])
    return dev


def consultar(dev, comando, timeout=3.0):
    """Envía un comando Megatec y devuelve la respuesta en texto."""
    datos = (comando + "\r").encode("ascii")
    # El chip recibe bloques de 8 bytes vía SET_REPORT; el primer byte es el report ID (0)
    for i in range(0, len(datos), 8):
        bloque = datos[i:i + 8].ljust(8, b"\x00")
        dev.write(b"\x00" + bloque)

    buf = b""
    limite = time.time() + timeout
    while time.time() < limite:
        r = dev.read(8, 500)
        if r:
            buf += bytes(r)
            if b"\r" in buf:
                break
    return buf.split(b"\r")[0].replace(b"\x00", b"").decode("ascii", "replace").strip()


BITS = [
    "Corte de luz (en batería)",       # b7
    "Batería baja",                    # b6
    "AVR/bypass activo",               # b5
    "Falla de la UPS",                 # b4
    "Tipo line-interactive/standby",   # b3
    "Test de batería en curso",        # b2
    "Apagado programado activo",       # b1
    "Alarma sonora activada",          # b0
]


def interpretar_q1(resp):
    campos = resp.lstrip("(").split()
    if len(campos) != 8:
        print("  (formato inesperado, revisar respuesta cruda)")
        return
    v_in, v_falla, v_out, carga, freq, v_bat, temp, bits = campos
    print(f"  Voltaje entrada : {v_in} V")
    print(f"  Voltaje salida  : {v_out} V")
    print(f"  Carga           : {int(carga)} %")
    print(f"  Frecuencia      : {freq} Hz")
    print(f"  Batería         : {v_bat} V"
          + ("  (parece por celda)" if float(v_bat) < 5 else ""))
    print(f"  Temperatura     : {temp}")
    print(f"  Bits de estado  : {bits}")
    for bit, nombre in zip(bits, BITS):
        if bit == "1":
            print(f"    • {nombre}")


def main():
    info = buscar_ups()
    if not info:
        sys.exit("No encontré ningún dispositivo con VID 0x0665. ¿Está conectado el cable USB?")

    print(f"UPS encontrada: {info['manufacturer_string']} {info['product_string']} "
          f"(VID {info['vendor_id']:04x}, PID {info['product_id']:04x})\n")

    try:
        dev = abrir_ups(info)
    except OSError as e:
        sys.exit(f"No pude abrir el dispositivo: {e}")

    try:
        for cmd, desc in [("Q1", "Estado"), ("F", "Valores nominales"), ("I", "Información")]:
            resp = consultar(dev, cmd)
            print(f"[{cmd}] {desc}: {resp!r}")
            if cmd == "Q1" and resp:
                interpretar_q1(resp)
            print()
    finally:
        dev.close()


if __name__ == "__main__":
    main()
