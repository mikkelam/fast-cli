# fast-cli

[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange?logo=zig)](https://ziglang.org/)
[![CI](https://github.com/mikkelam/fast-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/mikkelam/fast-cli/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A blazingly fast CLI tool for testing internet speed uses fast.com v2 api. Written in Zig for maximum performance.

⚡ **1.2 MB binary** • 🚀 **Zero runtime deps** • 📊 **Adaptive stability-based stopping**

## Demo

![Fast-CLI Demo](demo/fast-cli-demo.svg)

## Why fast-cli?

- **Tiny binary**: Just 1.2 MB, no runtime dependencies
- **Blazing fast**: Concurrent connections with adaptive chunk sizing
- **Cross-platform**: Single binary for Linux, macOS
- **Smart stopping**: Uses a ramp + steady stability strategy and stops on stable speed or max duration

## Supported Platforms

- **Linux**: x86_64, aarch64 (ARM64)
- **macOS**: x86_64 (Intel), aarch64 (aka Apple Silicon)
- **Windows**: x86_64 (release binary zip)

## Installation

### Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/mikkelam/fast-cli/main/install.sh | bash
```

`install.sh` currently supports Linux and macOS only (not Windows yet).

### Pre-built Binaries
For example, on an Apple Silicon Mac:
```bash
curl -L https://github.com/mikkelam/fast-cli/releases/latest/download/fast-cli-aarch64-macos.tar.gz -o fast-cli.tar.gz
tar -xzf fast-cli.tar.gz
chmod +x fast-cli && sudo mv fast-cli /usr/local/bin/
fast-cli --help
```

### Build from Source
```bash
git clone https://github.com/mikkelam/fast-cli.git
cd fast-cli
zig build -Doptimize=ReleaseSafe
```

## Usage
```console
fast-cli - Estimate connection speed using fast.com

USAGE:
    fast-cli [OPTIONS]

OPTIONS:
    -h, --help                        Display this help and exit.
        --https                       Use HTTPS when connecting to fast.com (default)
        --no-https                    Use HTTP instead of HTTPS
    -u, --upload                      Check upload speed as well
    -j, --json                        Output results in JSON format
    -d, --duration <usize>            Maximum test duration in seconds (effective range: 7-30, default: 30)
```

## Example Output

```console
$ fast-cli --upload
🏓 25ms | ⬇️ Download: 114 Mbps | ⬆️ Upload: 62 Mbps

$ fast-cli -d 15  # Quick test with 15s max duration
🏓 22ms | ⬇️ Download: 105 Mbps

$ fast-cli -j     # JSON output
{"download_mbps": 131, "ping_ms": 20.8, "upload_mbps": null, "error": null}
```

## Stability Strategy

The speed test uses a two-phase strategy:

1. **Ramp phase**: increase active workers based on observed throughput.
2. **Steady phase**: lock worker count and estimate authoritative speed.

The test stops when either:

- speed is stable within a configured delta threshold over recent steady samples, or
- max duration is reached.

## Development

Optional: use `mise` to install and run the project toolchain.

```bash
mise install
mise exec -- zig build test
```

```bash
# Debug build
zig build

# Run tests
zig build test

# Release build
# Consider removing -Dcpu if you do not need a portable build
zig build -Doptimize=ReleaseFast -Dcpu=baseline
```

## License

MIT License - see [LICENSE](LICENSE) for details.

---

*Not affiliated with Netflix or Fast.com*
