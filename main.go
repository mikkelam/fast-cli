package main

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"mikkelam/fast-cli/fast"
	"mikkelam/fast-cli/format"
	"mikkelam/fast-cli/meters"
	"net/http"
	"os"
	"time"

	"github.com/urfave/cli/v2"
)

var (
	version        = "dev"
	commit         = "dirty"
	date           = "unknown"
	displayVersion string
	logDebug       bool
	notHTTPS       bool
	simpleProgress bool
	checkUpload    bool
)
var spinnerStates = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
var spinnerIndex = 0

func main() {
	displayVersion = fmt.Sprintf("%s-%s (built %s)", version, commit, date)
	app := &cli.App{
		Name:    "fast-cli",
		Usage:   "Estimate connection speed using fast.com",
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
			&cli.BoolFlag{
				Name:        "upload",
				Aliases:     []string{"u"},
				Usage:       "Test upload speed as well",
				Destination: &checkUpload,
			},
		},
		Action: run,
	}

	if err := app.Run(os.Args); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func initLog() {
	if logDebug {
		slog.SetLogLoggerLevel(slog.LevelDebug)
		slog.Debug("Debug logging enabled")
	}

	slog.Debug("Using HTTPS")
	if notHTTPS {
		slog.Debug("Not using HTTPS")
	}
}

func run(c *cli.Context) error {
	initLog()

	fast.UseHTTPS = !notHTTPS
	urls := fast.GetUrls(4)

	slog.Debug("Got %d urls from fast.com service\n", len(urls))

	if len(urls) == 0 {
		fmt.Println("Using fallback endpoint")
		urls = append(urls, fast.GetDefaultURL())
	}

	downloadSpeed, err := measureDownloadSpeed(urls)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error measuring download speed: %v\n", err)
		return err
	}

	var uploadSpeed string
	if checkUpload {
		uploadSpeed, err = measureUploadSpeed(urls)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error measuring upload speed: %v\n", err)
			return err
		}
	}

	printFinalSpeeds(downloadSpeed, uploadSpeed, checkUpload)

	return nil
}

func printFinalSpeeds(downloadSpeed, uploadSpeed string, checkUpload bool) {
	fmt.Println("\n🚀 Final estimated speeds:")
	fmt.Printf("   Download: %s\n", downloadSpeed)
	if checkUpload {
		fmt.Printf("   Upload:   %s\n", uploadSpeed)
	}
}

func measureDownloadSpeed(urls []string) (string, error) {
	client := &http.Client{}
	count := uint64(len(urls))
	primaryBandwidthMeter := meters.BandwidthMeter{}
	completed := make(chan bool)

	primaryBandwidthMeter.Start()
	fmt.Println("⬇️ Estimating download speed...")

	for _, url := range urls {
		go func(url string) {
			defer func() { completed <- true }() // Ensure completion signal

			request, err := http.NewRequest("GET", url, nil)
			if err != nil {
				slog.Error("Failed to create request", "error", err)
				return
			}
			request.Header.Set("User-Agent", displayVersion)

			response, err := client.Do(request)
			if err != nil {
				slog.Error("Failed to perform request", "error", err)
				return
			}
			defer response.Body.Close()

			tapMeter := io.TeeReader(response.Body, &primaryBandwidthMeter)
			_, err = io.Copy(io.Discard, tapMeter)
			if err != nil {
				slog.Error("Failed to copy response body", "error", err)
				return
			}
		}(url)
	}

	monitorProgress(&primaryBandwidthMeter, uint64(count*26214400), completed, count)

	finalSpeed := format.BitsPerSec(primaryBandwidthMeter.Bandwidth())
	return finalSpeed, nil
}

func measureUploadSpeed(urls []string) (string, error) {
	client := &http.Client{}
	uploadData := make([]byte, 26214400) // 25 MB
	chunkSize := 1024 * 1024             // 1 MB chunk
	count := uint64(len(urls))

	primaryBandwidthMeter := meters.BandwidthMeter{}
	completed := make(chan bool)

	primaryBandwidthMeter.Start()
	fmt.Println("\n⬆️ Estimating upload speed...")

	for _, url := range urls {
		go func(url string) {
			defer func() { completed <- true }() // Ensure completion signal

			for offset := 0; offset < len(uploadData); offset += chunkSize {
				tapMeter := bytes.NewReader(uploadData[offset:min(offset+chunkSize, len(uploadData))])

				request, err := http.NewRequest("POST", url, tapMeter)
				if err != nil {
					slog.Error("Failed to create request", "error", err)
					return
				}
				request.Header.Set("User-Agent", displayVersion)
				request.Header.Set("Content-Type", "application/octet-stream")
				request.Header.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d",
					offset, min(offset+chunkSize-1, len(uploadData)-1), len(uploadData)))

				tapReadMeter := io.TeeReader(tapMeter, &primaryBandwidthMeter)
				buffer := &bytes.Buffer{}
				_, err = io.Copy(buffer, tapReadMeter)
				if err != nil {
					slog.Error("Failed to copy request body", "error", err)
					return
				}
				request.Body = io.NopCloser(buffer)
				resp, err := client.Do(request)
				if err != nil {
					slog.Error("Failed to perform request", "error", err)
					return
				}
				resp.Body.Close()
				if err != nil {
					slog.Error("Failed to close response body", "error", err)
					return
				}
			}
		}(url)
	}

	monitorProgress(&primaryBandwidthMeter, uint64(count*26214400), completed, count)

	finalSpeed := format.BitsPerSec(primaryBandwidthMeter.Bandwidth())
	return finalSpeed, nil
}

func monitorProgress(bandwidthMeter *meters.BandwidthMeter, bytesToRead uint64, completed chan bool, total uint64) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	var completeCount uint64

	for range ticker.C {
		if !simpleProgress {
			printProgress(bandwidthMeter, bytesToRead, completeCount, total)
		}

		select {
		case <-completed:
			completeCount++
			if completeCount == total {
				printProgress(bandwidthMeter, bytesToRead, completeCount, total)
				return
			}
		default:
		}
	}
}

func printProgress(bandwidthMeter *meters.BandwidthMeter, bytesToRead, completed, count uint64) {
	if !simpleProgress {
		// Cycle through spinner states
		spinner := spinnerStates[spinnerIndex]
		spinnerIndex = (spinnerIndex + 1) % len(spinnerStates)

		fmt.Printf("\r%s %s - %s completed",
			spinner,
			format.BitsPerSec(bandwidthMeter.Bandwidth()),
			format.Percent(bandwidthMeter.BytesRead(), bytesToRead))
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
