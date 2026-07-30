# RTimeServer

A cross-platform gPTP (IEEE 802.1AS) debugging tool built with [Racket](https://racket-lang.org/). It provides a GUI for configuring PTP parameters, monitoring time synchronization status, capturing and analyzing PTP packets, and viewing runtime logs with sync accuracy statistics.

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

## Features

- **Parameter Configuration** — transport mode (IEEE 802.3 / UDP IPv4), profile (gPTP / PTPv2), domain number, Announce/Sync intervals
- **Sync Monitoring** — real-time Master-Slave sync status, clock offset, path delay, neighbor rate ratio
- **Packet Analysis** — capture and parse PTP packets (Sync, Follow_Up, Announce, PDelay, Signalling) with per-field display
- **Logs & Statistics** — runtime logging, sliding-window sync accuracy statistics (mean / min / max / stddev)
- **Bilingual UI** — Chinese and English interface

## Architecture

```
+-------------------------------------------+
|              GUI (Racket/gui)              |
|  Config  |  Monitor  |  Capture  |  Log   |
+-------------------------------------------+
|              Core Engine                  |
|  State  |  Timer  |  Stats  |  i18n      |
+---------------------+---------------------+
|     Protocol        |      Network        |
|  Types / Parser     |  Socket / Capture   |
|  Constants          |  Interface / Sender  |
+---------------------+---------------------+
```

See [docs/architecture.md](docs/architecture.md) for detailed design.

## Project Structure

```
rtimeserver/
├── main.rkt                 Application entry point
├── info.rkt                 Package metadata
├── rtimeserver/
│   ├── config.rkt           Global configuration
│   ├── i18n.rkt             Internationalization (zh/en)
│   ├── gui/
│   │   ├── main-frame.rkt   Main window
│   │   ├── config-panel.rkt PTP parameter settings
│   │   ├── monitor-panel.rkt Sync monitoring
│   │   ├── capture-panel.rkt Packet capture
│   │   ├── log-panel.rkt    Log viewer
│   │   ├── nav-panel.rkt    Navigation
│   │   └── settings-panel.rkt App settings
│   ├── protocol/
│   │   ├── constants.rkt    IEEE 1588 / 802.1AS constants
│   │   ├── types.rkt        PTP data types and timestamps
│   │   ├── header.rkt       Common header parsing
│   │   ├── parser.rkt       Packet parser dispatcher
│   │   ├── sync.rkt         Sync message
│   │   ├── follow-up.rkt    Follow_Up message
│   │   ├── announce.rkt     Announce message
│   │   ├── pdelay.rkt       PDelay messages
│   │   └── signalling.rkt   Signalling message
│   ├── network/
│   │   ├── socket.rkt       Raw socket abstraction
│   │   ├── capture.rkt      Packet capture (libpcap/Npcap)
│   │   ├── interface.rkt    Network interface detection
│   │   └── sender.rkt       PTP packet sender
│   └── core/
│       ├── engine.rkt       PTP engine (config, state, start)
│       ├── state.rkt        Global state management
│       ├── timer.rkt        PTP timing
│       └── stats.rkt        Sync accuracy statistics
├── tests/
│   ├── test-config.rkt
│   ├── test-i18n.rkt
│   └── test-protocol.rkt
└── docs/
    ├── architecture.md
    ├── development.md
    ├── protocol-reference.md
    └── roadmap.md
```

## Requirements

| Dependency | Purpose |
|------------|---------|
| [Racket](https://download.racket-lang.org/) 8.x | Language runtime / build toolchain |
| **Windows**: [Npcap](https://npcap.com/) | Packet capture |
| **Linux**: `libpcap-dev` (`sudo apt install libpcap-dev`) | Packet capture |
| **macOS**: libpcap (built-in) | Packet capture |

## Quick Start

### 1. Clone

```bash
git clone https://github.com/turinglambdaai/rtimeserver.git
cd rtimeserver
```

### 2. Run

```bash
racket main.rkt
```

### Install as a Racket Package

```bash
raco pkg install ./rtimeserver
```

### Run Tests

```bash
raco test tests/
```

## Development

See [docs/development.md](docs/development.md) for setup, module interface specs, and contribution guidelines.

## Roadmap

See [docs/roadmap.md](docs/roadmap.md).

## License

Licensed under the [Apache License 2.0](LICENSE).
