#!/usr/bin/env python3
"""Verify that the installed driver renders inside macOS CUPS, without paper."""

import os
import socket
import subprocess
import sys
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def main(ppd, document):
    queue = f"HP_P1102_SelfTest_{os.getpid()}"
    with socket.socket() as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(2)
        port = server.getsockname()[1]
        run(
            "lpadmin", "-p", queue, "-E", "-v", f"socket://127.0.0.1:{port}",
            "-P", ppd, "-o", "printer-is-shared=false",
        )
        try:
            run("lp", "-d", queue, "-o", "PageSize=A4", document)
            deadline = time.monotonic() + 30
            payload = bytearray()
            while not payload and time.monotonic() < deadline:
                server.settimeout(deadline - time.monotonic())
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(max(1, deadline - time.monotonic()))
                    while True:
                        chunk = connection.recv(65536)
                        if not chunk:
                            break
                        payload.extend(chunk)

            if len(payload) < 2000 or b"JZJZ" not in payload or b"@PJL EOJ" not in payload[-40:]:
                raise RuntimeError(
                    f"CUPS produced only {len(payload)} bytes or an incomplete P1102 job"
                )
            print(f"CUPS sandbox rendered {len(payload)} bytes of ZjStream; no paper used.")
        finally:
            subprocess.run(("lpadmin", "-x", queue), capture_output=True, text=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: verify-cups-sandbox.py PPD TEST_POSTSCRIPT")
    try:
        main(sys.argv[1], sys.argv[2])
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        raise SystemExit(f"CUPS sandbox self test failed: {error}") from error
