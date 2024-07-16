package main

import (
	"fmt"
	"io"
	"mikkelam/fast-cli/fast"
	"mikkelam/fast-cli/format"
	"mikkelam/fast-cli/meters"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/urfave/cli/v2"
)

var (
	version = "dev"
	commit  = "dirty"
	date    = "unknown"
)
var displayVersion string

var logDebug bool
var notHTTPS bool
var simpleProgress bool

func main() {
	displayVersion = fmt.Sprintf("%s-%s (built %s)", version, commit, date)
	app := &cli.App{
		Name:    "fast-cli",
		Usage:   "Estimate connection speed using fast.com", // homebrew test expects this string
		Version: displayVersion,
		Flags: []cli.Flag{
			&cli.BoolFlag{
				Name:        "no-https",
				Aliases:     []string{"n"},
				Usage:       "Do not use HTTPS when connecting",
				Destination: &notHTTPS,
			},
			&cli.BoolFlag{
				Name:        "simple",
				Aliases:     []string{"s"},
				Usage:       "Only display the result, no dynamic progress bar",
				Destination: &simpleProgress,
			},
			&cli.BoolFlag{
				Name:        "debug",
				Aliases:     []string{"D"},
				Usage:       "Write debug messages to console",
				Destination: &logDebug,
				Hidden:      true,
			},
		},
		Action: run,
	}

	err := app.Run(os.Args)
	if err != nil {
		fmt.Println(err)
		os.Exit(-1)
	}
}

func initLog() {
	if logDebug {
		fmt.Println("Debug mode enabled")
	}
	if notHTTPS {
		fmt.Println("Not using HTTPS")
	} else {
		fmt.Println("Using HTTPS")
	}
}

func run(c *cli.Context) error {
	initLog()

	count := uint64(3)
	fast.UseHTTPS = !notHTTPS
	urls := fast.GetDlUrls(count)
	fmt.Printf("Got %d from fast service\n", len(urls))

	if len(urls) == 0 {
		fmt.Println("Using fallback endpoint")
		urls = append(urls, fast.GetDefaultURL())
	}

	err := calculateBandwidth(urls)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
	}

	return nil
}

func calculateBandwidth(urls []string) error {
	client := &http.Client{}
	count := uint64(len(urls))

	primaryBandwidthReader := meters.BandwidthMeter{}
	bandwidthMeter := meters.BandwidthMeter{}
	ch := make(chan *copyResults, 1)
	bytesToRead := uint64(0)
	completed := uint64(0)

	for i := uint64(0); i < count; i++ {
		// Create the HTTP request
		request, err := http.NewRequest("GET", urls[i], nil)
		if err != nil {
			return err
		}
		request.Header.Set("User-Agent", displayVersion)

		// Get the HTTP Response
		response, err := client.Do(request)
		if err != nil {
			return err
		}
		defer response.Body.Close()

		// Set information for the leading index
		if i == 0 {
			// Try to get content length
			contentLength := response.Header.Get("Content-Length")
			calculatedLength, err := strconv.Atoi(contentLength)
			if err != nil {
				calculatedLength = 26214400
			}
			bytesToRead = uint64(calculatedLength)
			fmt.Printf("Download Size=%d\n", bytesToRead)

			tapMeter := io.TeeReader(response.Body, &primaryBandwidthReader)
			go asyncCopy(i, ch, &bandwidthMeter, tapMeter)
		} else {
			// Start reading
			go asyncCopy(i, ch, &bandwidthMeter, response.Body)
		}
	}

	if !simpleProgress {
		fmt.Println("Estimating current download speed")
	}
	for {
		select {
		case results := <-ch:
			if results.err != nil {
				fmt.Fprintf(os.Stdout, "\n%v\n", results.err)
				return results.err
			}

			completed++
			if !simpleProgress {
				fmt.Printf("\r%s - %s",
					format.BitsPerSec(bandwidthMeter.Bandwidth()),
					format.Percent(primaryBandwidthReader.BytesRead(), bytesToRead))
				fmt.Printf("  \n")
				fmt.Printf("Completed in %.1f seconds\n", bandwidthMeter.Duration().Seconds())
			} else {
				fmt.Printf("%s\n", format.BitsPerSec(bandwidthMeter.Bandwidth()))
			}
			return nil
		case <-time.After(100 * time.Millisecond):
			if !simpleProgress {
				fmt.Printf("\r%s - %s",
					format.BitsPerSec(bandwidthMeter.Bandwidth()),
					format.Percent(primaryBandwidthReader.BytesRead(), bytesToRead))
			}
		}
	}
}

type copyResults struct {
	index        uint64
	bytesWritten uint64
	err          error
}

func asyncCopy(index uint64, channel chan *copyResults, writer io.Writer, reader io.Reader) {
	bytesWritten, err := io.Copy(writer, reader)
	channel <- &copyResults{index, uint64(bytesWritten), err}
}

func sumArr(array []uint64) (sum uint64) {
	for i := 0; i < len(array); i++ {
		sum = sum + array[i]
	}
	return
}
