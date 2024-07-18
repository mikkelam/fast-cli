# fast-cli
Originally made by github.com/gesquive/fast-cli, this is a fork of the original project with some minor changes to update it to the latest version of go and to add some additional features. All credits go to the original author.

fast-cli estimates your current internet download speed by performing a series of downloads from Netflix's fast.com servers.

![Demo](imgs/fast-cli.svg)

## Installing

### Downloading a Prebuilt Binary

1. Visit the [latest releases page](https://github.com/mikkelam/fast-cli/releases/latest) of the `fast-cli` repository.
2. Download the appropriate binary for your platform.
3. Extract the downloaded file.
4. Move the binary to a directory included in your `PATH` (e.g., `/usr/local/bin`).

For example on an apple silicon mac:
```console
curl -L https://github.com/mikkelam/fast-cli/releases/latest/download/fast-cli_Darwin_arm64.tar.gz | tar xz

# Move the binary to /usr/local/bin
sudo mv fast-cli /usr/local/bin
```


### Compiling

If you have go installed, you can compile the binary yourself by running the following command in the root of the project:

```console
make build
```

## Usage

```console
fast-cli estimates your current internet download speed by performing a series of downloads from Netflix's fast.com servers.

Usage:
  fast-cli [flags]

Flags:
  -h, --help       help for fast-cli
  -u, --upload     Measure upload speed along with download speed
  -n, --no-https   Do not use HTTPS when connecting
  -s, --simple     Only display the result, no dynamic progress bar
      --version    Display the version number and exit
```
Optionally, a hidden debug flag is available in case you need additional output.
```console
Hidden Flags:
  -D, --debug                  Include debug statements in log output
```

# Making a release
The project uses goreleaser and theres's github action to cross compile and create binaries for linux and darwin. To create a new release, you can create a new tag and push it to the repository. The github action will take care of the rest.

## License

This package is made available under an MIT-style license. See LICENSE.

## Contributing

PRs are always welcome!
