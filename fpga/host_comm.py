#!/usr/bin/env python3
"""
host_comm.py — Interactive host for the request-manager FPGA design.

Communicates with fpga_top over USB-UART at 115200 baud.

Requirements:
    pip install pyserial

Usage:
    python host_comm.py              # auto-detect serial port
    python host_comm.py COM4         # Windows — specify port
    python host_comm.py /dev/ttyUSB1 # Linux   — specify port

Interactive commands:
    reset              Reset the design
    tick  / t          Step one design cycle
    submit S D [DATA]  Submit request from source S to dest D with optional data
                       e.g.  submit 1 2 100
    query / q          Query status (without stepping)
    dump  / d          Dump full request table
    clear / c          Clear staged (pending) requests
    run S D [DATA]     Shortcut: submit + tick  (submit then step)
    multi              Interactive multi-source submit
    help / h           Show this help
    quit / exit        Exit
"""

import sys
import time
import struct
import serial
import serial.tools.list_ports


# ── Protocol constants ──────────────────────────────────────────────
CMD_RESET  = 0x01
CMD_TICK   = 0x02
CMD_SUBMIT = 0x03
CMD_QUERY  = 0x04
CMD_DUMP   = 0x05
CMD_CLEAR  = 0x06

ACK_RESET  = 0xA1
ACK_TICK   = 0xA2
ACK_SUBMIT = 0xA3
ACK_QUERY  = 0xA4
ACK_DUMP   = 0xA5
ACK_CLEAR  = 0xA6


def find_serial_port():
    """Auto-detect a likely FPGA serial port."""
    ports = serial.tools.list_ports.comports()
    for p in ports:
        desc = (p.description or "").lower()
        if any(kw in desc for kw in ["uart", "usb", "serial", "ftdi", "digilent"]):
            return p.device
    # Fallback: return the first port found
    if ports:
        return ports[0].device
    return None


class FPGAHost:
    def __init__(self, port, baud=115200, timeout=2.0):
        self.ser = serial.Serial(port, baud, timeout=timeout)
        time.sleep(0.1)  # let the port settle
        self.ser.reset_input_buffer()
        print(f"Connected to {port} at {baud} baud.\n")

    def close(self):
        self.ser.close()

    def _send(self, data: bytes):
        self.ser.write(data)

    def _recv(self, n: int) -> bytes:
        b = self.ser.read(n)
        if len(b) < n:
            print(f"  [warn] Expected {n} bytes, got {len(b)}")
        return b

    # ── Commands ─────────────────────────────────────────────────

    def reset(self):
        """Send RESET command."""
        self._send(bytes([CMD_RESET]))
        resp = self._recv(1)
        if resp and resp[0] == ACK_RESET:
            print("  Design reset OK.")
        else:
            print(f"  Reset: unexpected response {resp.hex() if resp else 'none'}")

    def tick(self):
        """Send TICK command and display results."""
        self._send(bytes([CMD_TICK]))
        resp = self._recv(6)
        if not resp or len(resp) < 6 or resp[0] != ACK_TICK:
            print(f"  Tick: unexpected response {resp.hex() if resp else 'none'}")
            return
        num_active    = resp[1]
        grant_vec     = resp[2]
        granted_valid = resp[3]
        expired_valid = resp[4]
        flags         = resp[5]
        table_full    = bool(flags & 0x02)
        age_overflow  = bool(flags & 0x01)

        print(f"  Tick result:")
        print(f"    Active entries : {num_active}")
        print(f"    Grant vector   : {grant_vec:08b}")
        print(f"    Granted valid  : {granted_valid:08b}")
        print(f"    Expired valid  : {expired_valid:08b}")
        print(f"    Table full     : {table_full}")
        print(f"    Age overflow   : {age_overflow}")

    def submit(self, src: int, dst: int, data: int = 0):
        """Stage a request for source→dest with data."""
        sd_byte = ((src & 0x3) << 2) | (dst & 0x3)
        d_byte  = data & 0xFF
        self._send(bytes([CMD_SUBMIT, sd_byte, d_byte]))
        resp = self._recv(2)
        if not resp or len(resp) < 2 or resp[0] != ACK_SUBMIT:
            print(f"  Submit: unexpected response {resp.hex() if resp else 'none'}")
            return
        ready = resp[1] & 0x0F
        print(f"  Staged: src={src} → dst={dst}, data={data}")
        print(f"    Ready mask: {ready:04b}  (reflects current table availability)")

    def query(self):
        """Query current status without stepping."""
        self._send(bytes([CMD_QUERY]))
        resp = self._recv(6)
        if not resp or len(resp) < 6 or resp[0] != ACK_QUERY:
            print(f"  Query: unexpected response {resp.hex() if resp else 'none'}")
            return
        num_active    = resp[1]
        grant_vec     = resp[2]
        granted_valid = resp[3]
        expired_valid = resp[4]
        flags         = resp[5]

        print(f"  Status:")
        print(f"    Active entries : {num_active}")
        print(f"    Grant vector   : {grant_vec:08b}")
        print(f"    Granted valid  : {granted_valid:08b}")
        print(f"    Expired valid  : {expired_valid:08b}")
        print(f"    Table full     : {bool(flags & 0x02)}")
        print(f"    Age overflow   : {bool(flags & 0x01)}")

    def dump(self):
        """Dump full request table."""
        self._send(bytes([CMD_DUMP]))
        resp = self._recv(17)
        if not resp or len(resp) < 17 or resp[0] != ACK_DUMP:
            print(f"  Dump: unexpected response {resp.hex() if resp else 'none'}")
            return
        print("  Request Table:")
        print("  Slot | Valid | Src | Dst | Age | Data")
        print("  -----|-------|-----|-----|-----|-----")
        for i in range(8):
            vsd  = resp[1 + i * 2]
            data = resp[2 + i * 2]
            valid = (vsd >> 7) & 1
            src   = (vsd >> 5) & 0x3
            dst   = (vsd >> 3) & 0x3
            age   = vsd & 0x7
            marker = " ◄" if valid else ""
            print(f"    {i}  |   {valid}   |  {src}  |  {dst}  |  {age}  | {data:3d}{marker}")

    def clear(self):
        """Clear staged requests."""
        self._send(bytes([CMD_CLEAR]))
        resp = self._recv(1)
        if resp and resp[0] == ACK_CLEAR:
            print("  Staged requests cleared.")
        else:
            print(f"  Clear: unexpected response {resp.hex() if resp else 'none'}")


def print_help():
    print("""
  Commands:
    reset              Reset the design
    tick  / t          Step one design cycle
    submit S D [DATA]  Stage a request (src=S, dst=D, data=DATA)
    query / q          Query current status
    dump  / d          Dump request table
    clear / c          Clear staged requests
    run S D [DATA]     Submit + tick in one step
    multi              Multi-source submit (interactive)
    help / h           Show this help
    quit / exit        Exit

  Workflow example:
    > submit 0 1 42     # stage: source 0 → dest 1, data=42
    > submit 1 3 99     # stage: source 1 → dest 3, data=99
    > tick              # step the design — both requests inserted
    > dump              # see them in the table
    > tick              # age them / apply grants
    > tick              # grants applied, entries cleared
    > dump              # table empty
""")


def main():
    # Determine serial port
    if len(sys.argv) > 1:
        port = sys.argv[1]
    else:
        port = find_serial_port()
        if not port:
            print("No serial port found. Specify one: python host_comm.py <PORT>")
            sys.exit(1)
        print(f"Auto-detected port: {port}")

    host = FPGAHost(port)

    print("Type 'help' for available commands.\n")

    try:
        while True:
            try:
                line = input("fpga> ").strip()
            except EOFError:
                break

            if not line:
                continue

            parts = line.split()
            cmd = parts[0].lower()

            if cmd in ("quit", "exit"):
                break
            elif cmd in ("help", "h"):
                print_help()
            elif cmd == "reset":
                host.reset()
            elif cmd in ("tick", "t"):
                host.tick()
            elif cmd == "submit":
                if len(parts) < 3:
                    print("  Usage: submit <src> <dst> [data]")
                    continue
                src  = int(parts[1])
                dst  = int(parts[2])
                data = int(parts[3]) if len(parts) > 3 else 0
                if not (0 <= src <= 3 and 0 <= dst <= 3):
                    print("  src and dst must be 0-3")
                    continue
                host.submit(src, dst, data)
            elif cmd == "run":
                if len(parts) < 3:
                    print("  Usage: run <src> <dst> [data]")
                    continue
                src  = int(parts[1])
                dst  = int(parts[2])
                data = int(parts[3]) if len(parts) > 3 else 0
                if not (0 <= src <= 3 and 0 <= dst <= 3):
                    print("  src and dst must be 0-3")
                    continue
                host.submit(src, dst, data)
                host.tick()
            elif cmd in ("query", "q"):
                host.query()
            elif cmd in ("dump", "d"):
                host.dump()
            elif cmd in ("clear", "c"):
                host.clear()
            elif cmd == "multi":
                print("  Enter requests (src dst data). Empty line to finish:")
                while True:
                    sub = input("    src dst data> ").strip()
                    if not sub:
                        break
                    sp = sub.split()
                    if len(sp) < 2:
                        print("    Need at least src and dst")
                        continue
                    s = int(sp[0])
                    d = int(sp[1])
                    dd = int(sp[2]) if len(sp) > 2 else 0
                    host.submit(s, d, dd)
                print("  Now 'tick' to commit them.")
            else:
                print(f"  Unknown command: {cmd}. Type 'help' for options.")

    except KeyboardInterrupt:
        print()

    host.close()
    print("Disconnected.")


if __name__ == "__main__":
    main()
