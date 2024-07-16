# fast-cli
Originally made by gesquive/fast-cli, this is a fork of the original project with some minor changes to update it to the latest version of go and to add some additional features.

fast-cli estimates your current internet download speed by performing a series of downloads from Netflix's fast.com servers.


## Installing

### Compile

If you have go installed, you can compile and install the latest version of fast-cli with the following command:
```console
go get -u github.com/mikkelam/fast-cli
```

## Usage

```console
fast-cli estimates your current internet download speed by performing a series of downloads from Netflix's fast.com servers.

Usage:
  fast-cli [flags]

Flags:
  -h, --help       help for fast-cli
  -n, --no-https   Do not use HTTPS when connecting
  -s, --simple     Only display the result, no dynamic progress bar
      --version    Display the version number and exit
```
Optionally, a hidden debug flag is available in case you need additional output.
```console
Hidden Flags:
  -D, --debug                  Include debug statements in log output
```

## Documentation

This documentation can be found at github.com/mikkelam/fast-cli

## License

This package is made available under an MIT-style license. See LICENSE.

## Contributing

PRs are always welcome!
