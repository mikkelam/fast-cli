# fast-cli

`fast-cli` estimates your current internet download/upload speed by performing a series of requests to fast.com servers.

Originally forked from [gesquive/fast-cli](https://github.com/gesquive/fast-cli), which appears to be abandoned. All credits go to the original author.

![Demo](imgs/fast-cli.svg)

## Installing

### Downloading a Prebuilt Binary

1. Visit the [latest releases page](https://github.com/mikkelam/fast-cli/releases/latest).
2. Download the appropriate binary for your platform.
3. Extract the downloaded file.
4. Move the binary to a directory included in your `PATH` (e.g., `/usr/local/bin`).

For example, on an Apple Silicon Mac:
```console
curl -L https://github.com/mikkelam/fast-cli/releases/latest/download/fast-cli_Darwin_arm64.tar.gz | tar xz
sudo mv fast-cli /usr/local/bin
```

### Compiling from Source

If you have Go installed, you can compile the binary yourself by running the following command in the root of the project:

```console
make build
```

## Usage

```console
fast-cli [flags]

Flags:
  -h, --help       Help for fast-cli
  -u, --upload     Measure upload speed along with download speed
  -n, --no-https   Do not use HTTPS when connecting
  -s, --simple     Only display the result, no dynamic progress bar
  -d, --duration   Duration download and upload tests should run (default 6s)
      --version    Display the version number and exit
```
Optionally, a hidden debug flag is available in case you need additional output.
```console
Hidden Flags:
  -D, --debug   Include debug statements in log output
```

## Making a Release

The project uses `goreleaser` with a GitHub action to cross-compile and create binaries for Linux and Darwin. To create a new release, create a new tag and push it to the repository. The GitHub action will handle the rest.

## License

This package is made available under an MIT-style license. See [LICENSE](./LICENSE).

## Contributing

PRs are always welcome!
