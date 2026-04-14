# Request Manager — Basys 3 FPGA Implementation

## Overview

This wraps the `request_manager_top` + `age_arbiter` design for the
**Digilent Basys 3** (Artix-7 XC7A35T) board. The original design had
324 I/O ports; this wrapper internalises all inter-module wiring and
exposes only physical board pins (clock, UART, LEDs, button).

Communication with a laptop uses **USB-UART at 115200 baud** through the
Basys 3's built-in FTDI bridge — no extra hardware needed.

## Files

| File | Purpose |
|---|---|
| `fpga_top.sv` | Top-level wrapper: UART, command processor, BUFGCE clock gating, design instantiation |
| `uart_rx.sv` | UART receiver (115200, 8N1) |
| `uart_tx.sv` | UART transmitter (115200, 8N1) |
| `multi_request_manager_top.sv` | Original request manager (unchanged) |
| `multi_age_arbiter.sv` | Original age-based arbiter (unchanged) |
| `basys3.xdc` | Xilinx constraints (pin assignments, clocks) |
| `host_comm.py` | Python host script for laptop-side communication |

## How It Works

### Clock Gating (Single-Step Control)

The design runs on a **gated clock** produced by a Xilinx `BUFGCE`
primitive. The clock only advances when you send a **TICK** command
from the laptop. This lets you step through the pipeline one cycle at a
time and observe every intermediate state — insertion, aging, granting,
and clearing.

### Pipeline Reminder

```
Cycle N   : Requests inserted. grant_reg = 0 (no previous grant).
Cycle N+1 : Entries visible. Arbiter grants. grant_reg captures.
Cycle N+2 : grant_reg applied. Entries cleared. granted_valid pulses.
```

Minimum entry lifetime: **2 ticks** after insertion.

### Staged Requests

Requests are **staged** first (SUBMIT command), then **committed** on
the next TICK. This lets you set up multiple source requests before
stepping, enabling simultaneous multi-source insertion.

## Vivado Project Setup

1. **Create a new RTL project** targeting the `xc7a35tcpg236-1` part.

2. **Add all `.sv` source files:**
   - `fpga_top.sv`
   - `uart_rx.sv`
   - `uart_tx.sv`
   - `multi_request_manager_top.sv` (your original file)
   - `multi_age_arbiter.sv` (your original file)

3. **Add the constraints file:**
   - `basys3.xdc`

4. **Set `fpga_top` as the top module.**

5. **Run Synthesis, Implementation, and Generate Bitstream.**

   You may see warnings about the BUFGCE-generated clock — these are
   expected and safe for this design.

6. **Program the board** via Hardware Manager.

## Laptop Setup

### Requirements

```bash
pip install pyserial
```

### Running the Host Script

```bash
# Auto-detect serial port:
python host_comm.py

# Or specify explicitly:
python host_comm.py COM4          # Windows
python host_comm.py /dev/ttyUSB1  # Linux
python host_comm.py /dev/cu.usbserial-XXXXX  # macOS
```

### Interactive Commands

```
fpga> reset              # Reset the design
fpga> submit 0 1 42      # Stage: source 0 → dest 1, data=42
fpga> submit 1 3 99      # Stage: source 1 → dest 3, data=99
fpga> tick               # Step — both requests inserted simultaneously
fpga> dump               # View the request table
fpga> tick               # Step — arbiter grants, entries age
fpga> tick               # Step — grants applied, entries cleared
fpga> dump               # Table empty
fpga> query              # Check status without stepping
```

### Walkthrough: Two Simultaneous Requests

```
fpga> reset
  Design reset OK.

fpga> submit 1 2 100
  Staged: src=1 → dst=2, data=100

fpga> submit 0 3 200
  Staged: src=0 → dst=3, data=200

fpga> tick                          # Cycle 0: both inserted
  Tick result:
    Active entries : 2
    Grant vector   : 00000011       # arbiter grants both (different dests)
    Granted valid  : 00000000       # not yet — pipeline delay
    ...

fpga> dump
  Slot | Valid | Src | Dst | Age | Data
    0  |   1   |  0  |  3  |  0  | 200 ◄
    1  |   1   |  1  |  2  |  0  | 100 ◄
    ...

fpga> tick                          # Cycle 1: entries age, grant_reg captured
fpga> tick                          # Cycle 2: entries cleared, granted_valid pulses
  Tick result:
    Active entries : 0
    Granted valid  : 00000011       # both granted simultaneously!

fpga> dump
  Slot | Valid | Src | Dst | Age | Data
    0  |   0   |  0  |  0  |  0  |   0
    ...                              # table empty — both cleared
```

## LED Map (Board Status at a Glance)

| LED | Signal |
|-----|--------|
| 3:0 | `num_active_reqs` (binary count of active table entries) |
| 4 | `table_full` |
| 5 | `age_overflow` (an entry has hit MAX_AGE) |
| 7:6 | unused (off) |
| 15:8 | `granted_valid` (one LED per table slot, lights on grant) |

## Physical Controls

| Control | Function |
|---------|----------|
| Centre button (btnC) | System reset (resets UART + design) |

## UART Protocol Reference

All communication is binary, 115200 baud, 8N1.

### Commands (PC → FPGA)

| Cmd | Hex | Extra Bytes | Description |
|-----|-----|-------------|-------------|
| RESET | `01` | — | Reset design |
| TICK | `02` | — | Step one design cycle |
| SUBMIT | `03` | SD, DD | Stage request (SD={0,0,src[1:0],dst[1:0]}, DD=data[7:0]) |
| QUERY | `04` | — | Read status without stepping |
| DUMP | `05` | — | Read full request table |
| CLEAR | `06` | — | Clear all staged requests |

### Responses (FPGA → PC)

| For | Ack | Data Bytes |
|-----|-----|------------|
| RESET | `A1` | — |
| TICK | `A2` | NUM, GRANT_VEC, GRANTED_VALID, EXPIRED_VALID, FLAGS |
| SUBMIT | `A3` | READY_MASK |
| QUERY | `A4` | NUM, GRANT_VEC, GRANTED_VALID, EXPIRED_VALID, FLAGS |
| DUMP | `A5` | 8 × {VSD, DATA} = 16 bytes |
| CLEAR | `A6` | — |

Where:
- `VSD = {valid, src[1:0], dst[1:0], age[2:0]}`
- `FLAGS = {6'b0, table_full, age_overflow}`
