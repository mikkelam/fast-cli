# fast-cli-zig

[![Zig](https://img.shields.io/badge/Zig-0.14.0+-orange.svg)](https://ziglang.org/)
[![CI](https://github.com/mikkelam/fast-cli-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/mikkelam/fast-cli-zig/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A blazingly fast CLI tool for testing internet speed compatible with fast.com (api v2). Written in Zig for maximum performance.

⚡ **1.3 MiB binary** • 🚀 **Zero runtime deps** • 📊 **Real-time progress**

## Why fast-cli-zig?

- **Tiny binary**: Just 1.4 MiB, no runtime dependencies
- **Blazing fast**: Concurrent connections with adaptive chunk sizing
- **Cross-platform**: Single binary for Linux, macOS, Windows
- **Real-time feedback**: Live speed updates during tests

## Installation

### Pre-built Binaries
For example, on an Apple Silicon Mac:
```bash
curl -L https://github.com/mikkelam/fast-cli-zig/releases/latest/download/fast-cli-aarch64-macos.tar.gz -o fast-cli.tar.gz
tar -xzf fast-cli.tar.gz
chmod +x fast-cli && sudo mv fast-cli /usr/local/bin/
fast-cli --help
```

### Build from Source
```bash
git clone https://github.com/mikkelam/fast-cli-zig.git
cd fast-cli-zig
zig build --release=safe
```

## Usage
```console
❯ ./fast-cli --help
Estimate connection speed using fast.com
v0.0.1

Usage: fast-cli [options]

Flags:
     --stability-max-variance    Maximum variance percentage for stability test [String] (default: "10.0")
 -u, --upload                     Check upload speed as well [Bool] (default: false)
 -d, --duration                   Duration in seconds for each test phase - download, then upload if enabled (duration mode only) [Int] (default: 10)
     --stability-min-samples     Minimum samples for stability test [Int] (default: 5)
     --stability-max-duration    Maximum duration in seconds for stability test [Int] (default: 30)
     --https                     Use https when connecting to fast.com [Bool] (default: true)
 -j, --json                       Output results in JSON format [Bool] (default: false)
 -m, --mode                       Test mode: 'duration' or 'stability' [String] (default: "duration")
 -h, --help                       Shows the help for a command [Bool] (default: false)

Use "fast-cli --help" for more information.
```

## Performance Comparison

TODO

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--upload`, `-u` | Test upload speed | `false` |
| `--duration`, `-d` | Test duration (seconds) | `10` |
| `--json`, `-j` | JSON output | `false` |
| `--https` | Use HTTPS | `true` |

## Example Output

```console
$ fast-cli --upload
🏓 25ms | ⬇️ Download: 113.7 Mbps | ⬆️ Upload: 62.1 Mbps
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
