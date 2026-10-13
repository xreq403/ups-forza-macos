#!/usr/bin/env python3
"""
Diagnóstico de bajo nivel para la UPS INNO TECH (VID 0x0665).
Prueba distintos métodos de envío y comandos, y muestra los bytes crudos.

Uso:
    ./venv/bin/python ups_debug.py
"""
import sys
import time

import hid

VID = 0x0665


def hexdump(b):
    return " ".join(f"{x:02x}" for x in b) + "   |" + "".join(
        chr(x) if 32 <= x < 127 else "." for x in b) + "|"


def leer_todo(dev, segundos=2.5):
    """Lee todos los reportes que lleguen durante N segundos."""
    total = b""
    fin = time.time() + segundos
    while time.time() < fin:
        r = dev.read(64, 200)
        if r:
            print("      <-", hexdump(bytes(r)))
            total += bytes(r)
    return total


def vaciar(dev):
    while dev.read(64, 100):
        pass


def main():
    devs = [d for d in hid.enumerate() if d["vendor_id"] == VID]
    if not devs:
        sys.exit("No se encontró el dispositivo.")
    for d in devs:
        print("Dispositivo:")
        for k in ("path", "product_id", "usage_page", "usage", "interface_number",
                  "manufacturer_string", "product_string", "serial_number"):
            print(f"  {k}: {d.get(k)}")
    print()

    dev = hid.device()
    dev.open_path(devs[0]["path"])

    # Descriptor de reportes (si la versión de hidapi lo soporta)
    try:
        desc = dev.get_report_descriptor()
        print("Descriptor de reportes:", hexdump(bytes(desc)), "\n")
    except Exception as e:
        print(f"(No se pudo leer el descriptor: {e})\n")

    print("Bytes que llegan sin enviar nada:")
    leer_todo(dev, 1.5)
    print()

    comandos = ["Q1", "QS", "QGS", "M", "QPI", "F", "I"]
    metodos = {
        "write (output report, ID 0)": lambda d, blk: d.write(b"\x00" + blk),
        "send_feature_report (ID 0)": lambda d, blk: d.send_feature_report(b"\x00" + blk),
    }

    for nombre_m, enviar in metodos.items():
        print("=" * 60)
        print("Método:", nombre_m)
        print("=" * 60)
        for cmd in comandos:
            vaciar(dev)
            datos = (cmd + "\r").encode()
            print(f"  Comando {cmd!r}")
            ok = True
            for i in range(0, len(datos), 8):
                blk = datos[i:i + 8].ljust(8, b"\x00")
                try:
                    n = enviar(dev, blk)
                except Exception as e:
                    n = f"excepción: {e}"
                print(f"      -> {hexdump(blk)}  resultado={n}")
                if not isinstance(n, int) or n < 0:
                    ok = False
                    try:
                        print("         error:", dev.error())
                    except Exception:
                        pass
            if ok:
                resp = leer_todo(dev)
                txt = resp.replace(b"\x00", b"").decode("ascii", "replace")
                print(f"      respuesta: {txt!r}")
            print()

    dev.close()


if __name__ == "__main__":
    main()
