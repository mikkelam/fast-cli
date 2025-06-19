# fast-cli

[![Zig](https://img.shields.io/badge/Zig-0.14.0+-orange.svg)](https://ziglang.org/)
[![CI](https://github.com/mikkelam/fast-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/mikkelam/fast-cli/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A blazingly fast CLI tool for testing internet speed uses fast.com v2 api. Written in Zig for maximum performance.

⚡ **1.4 MiB binary** • 🚀 **Zero runtime deps** • 📊 **Smart stability detection**

## Demo

![Fast-CLI Demo](demo/fast-cli-demo.svg)

## Why fast-cli?

- **Tiny binary**: Just 1.4 MiB, no runtime dependencies
- **Blazing fast**: Concurrent connections with adaptive chunk sizing
- **Cross-platform**: Single binary for Linux, macOS, Windows
- **Smart stopping**: Uses Coefficient of Variation (CoV) algorithm for adaptive test duration

## Installation

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
zig build --release=safe
```

## Usage
```console
❯ ./fast-cli --help
Estimate connection speed using fast.com
v0.0.1

Usage: fast-cli [options]

Flags:
 -u, --upload      Check upload speed as well [Bool] (default: false)
 -d, --duration    Maximum test duration in seconds (uses Fast.com-style stability detection by default) [Int] (default: 30)
     --https      Use https when connecting to fast.com [Bool] (default: true)
 -j, --json        Output results in JSON format [Bool] (default: false)
 -h, --help        Shows the help for a command [Bool] (default: false)

Use "fast-cli --help" for more information.
```

## Example Output

```console
$ fast-cli --upload
🏓 25ms | ⬇️ Download: 113.7 Mbps | ⬆️ Upload: 62.1 Mbps

$ fast-cli -d 15  # Quick test with 15s max duration
🏓 22ms | ⬇️ Download: 105.0 Mbps

$ fast-cli -j     # JSON output
{"download_mbps": 131.4, "ping_ms": 20.8}
```

## Development

```bash
# Debug build
zig build

# Run tests
zig build test

# Release build
zig build --release=safe
```

## License

MIT License - see [LICENSE](LICENSE) for details.

---

*Not affiliated with Netflix or Fast.com*
