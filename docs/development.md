# Development Guide

## Prerequisites

- [Racket](https://download.racket-lang.org/) 8.x or later
- Platform-specific packet capture library:
  - **Windows**: [Npcap SDK](https://npcap.com/) (install with "WinPcap API-compatible Mode")
  - **Linux**: `sudo apt install libpcap-dev`
  - **macOS**: Built-in libpcap

## Getting Started

```bash
git clone https://github.com/turinglambdaai/rtimeserver.git
cd rtimeserver
racket main.rkt
```

## Running Tests

```bash
# Run all tests
raco test tests/

# Run a specific test file
raco test tests/test-protocol.rkt
```

## Project Structure

```
rtimeserver/
├── main.rkt                     # Entry point
├── info.rkt                     # Racket package metadata
├── rtimeserver/
│   ├── config.rkt               # Constants, defaults, config load/save
│   ├── i18n.rkt                 # Chinese/English string table
│   ├── gui/                     # GUI panels
│   │   ├── main-frame.rkt       # Top-level window assembly
│   │   ├── nav-panel.rkt        # Left navigation bar
│   │   ├── config-panel.rkt     # PTP parameter configuration
│   │   ├── monitor-panel.rkt    # Sync status display
│   │   ├── capture-panel.rkt    # Packet capture & analysis
│   │   ├── log-panel.rkt        # Runtime logs
│   │   └── settings-panel.rkt   # Language, NIC, preferences
│   ├── protocol/                # PTP/gPTP protocol parsing
│   │   ├── types.rkt            # Timestamp, ClockIdentity structs
│   │   ├── constants.rkt        # Message types, offsets, port states
│   │   ├── header.rkt           # Common header parse/build
│   │   ├── sync.rkt             # Sync message
│   │   ├── follow-up.rkt        # Follow_Up message
│   │   ├── announce.rkt         # Announce message
│   │   ├── pdelay.rkt           # PDelay messages
│   │   ├── signalling.rkt       # Signalling message
│   │   └── parser.rkt           # Top-level message dispatcher
│   ├── network/                 # Network I/O
│   │   ├── interface.rkt        # NIC enumeration
│   │   ├── capture.rkt          # Packet capture
│   │   ├── sender.rkt           # Packet sending
│   │   └── socket.rkt           # Raw socket (FFI)
│   └── core/                    # Business logic
│       ├── engine.rkt           # Main engine
│       ├── state.rkt            # Thread-safe runtime state
│       ├── timer.rkt            # PTP interval timers
│       └── stats.rkt            # Sync accuracy statistics
├── tests/                       # Test suite
└── docs/                        # Documentation
```

## Adding a New PTP Message Type

1. Create `rtimeserver/protocol/<message>.rkt` with struct + parse/build functions
2. Register the message type in `constants.rkt` if not already present
3. Import and dispatch in `parser.rkt`
4. Add tests in `tests/test-protocol.rkt`

## Coding Conventions

- All modules use `#lang racket` or `#lang racket/gui` (for GUI modules)
- Every module has explicit `(provide ...)` declarations
- Structs use `#:transparent` for debugging
- Stub functions throw `(error 'function-name "not implemented")`
- Keep module interfaces stable — GUI depends on protocol/core signatures, not internals

## Building a Release

```bash
# Create standalone executable
raco exe main.rkt

# Cross-platform: the resulting binary is platform-specific
# Distribute Npcap installer alongside Windows builds
```
