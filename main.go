package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"mikkelam/fast-cli/fast"
	"mikkelam/fast-cli/utils"

	"github.com/urfave/cli/v2"
)

type Speed struct {
	Speed float64 `json:"speed"`
	Unit  string  `json:"unit"`
}
type SpeedResults struct {
	Download Speed `json:"download"`
	Upload   Speed `json:"upload,omitempty"`
}

var (
	version        = "dev"
	commit         = "dirty"
	date           = "unknown"
	displayVersion string
	notHTTPS       bool
	simpleProgress bool
	checkUpload    bool
	maxDuration    time.Duration
	jsonOutput     bool
	debugOutput    bool
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
				Name:        "upload",
				Aliases:     []string{"u"},
				Usage:       "Test upload speed as well",
				Destination: &checkUpload,
			},
			&cli.DurationFlag{
				Name:        "max-duration",
				Aliases:     []string{"d"},
				DefaultText: "6s",
				Value:       time.Second * 6,
				Usage:       "Maximum duration for the speed test (e.g., 30s, 1m)",
				Destination: &maxDuration,
			},
			&cli.BoolFlag{
				Name:        "json",
				Usage:       "Output in JSON format",
				Destination: &jsonOutput,
			},
			&cli.BoolFlag{
				Name:        "debug",
				Aliases:     []string{"D"},
				Usage:       "Write debug messages to console",
				Destination: &debugOutput,
				Hidden:      true,
			},
		},
		Action: run,
	}

	if err := app.Run(os.Args); err != nil {
		utils.Println(err)
		os.Exit(1)
	}
}

func initApputils() {
	utils.AppConfig.Debug = debugOutput
	utils.AppConfig.JsonOutput = jsonOutput

	if debugOutput {
		utils.Debugln("Debug logging enabled")
	}

	utils.Debugln("Using HTTPS")
	if notHTTPS {
		utils.Debugln("Not using HTTPS")
	}
}

func run(c *cli.Context) error {
	initApputils()

	fast.UseHTTPS = !notHTTPS
	urls, err := fast.GetUrls(4)
	if err != nil {
		utils.Errorf("Error getting urls from fast.com service: %v\n", err)
		return err
	}

	utils.Debugf("Got %d urls from fast.com service\n", len(urls))

	if len(urls) == 0 {
		utils.Println("Using fallback endpoint")
		urls = append(urls, fast.GetDefaultURL())
	}

	downloadSpeed, err := measureDownloadSpeed(urls)
	if err != nil {
		utils.Fprintf(os.Stderr, "Error measuring download speed: %v\n", err)
		return err
	}

	var uploadSpeed Speed
	if checkUpload {
		uploadSpeed, err = measureUploadSpeed(urls)
		if err != nil {
			utils.Fprintf(os.Stderr, "Error measuring upload speed: %v\n", err)
			return err
		}
	}

	printFinalSpeeds(&downloadSpeed, &uploadSpeed, checkUpload)

	return nil
}

func toJSON(v interface{}) string {
	bytes, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(bytes)
}

func printFinalSpeeds(downloadSpeed *Speed, uploadSpeed *Speed, checkUpload bool) {
	if jsonOutput {
		results := SpeedResults{
			Download: *downloadSpeed,
			Upload:   *uploadSpeed,
		}
		utils.PrintJSON("%s\n", toJSON(results))
	} else {
		utils.Printf("\n🚀 Final estimated speeds:\n")
		utils.Printf("   Download: %.2f %s\n", downloadSpeed.Speed, downloadSpeed.Unit)
		if checkUpload && uploadSpeed != nil {
			utils.Printf("   Upload:    %.2f %s\n", uploadSpeed.Speed, uploadSpeed.Unit)
		}
	}
}

func measureDownloadSpeed(urls []string) (Speed, error) {
	client := &http.Client{}
	count := uint64(len(urls))
	primaryBandwidthMeter := utils.BandwidthMeter{}
	completed := make(chan bool)

	primaryBandwidthMeter.Start()
	if !simpleProgress {
		utils.Println("⬇️ Estimating download speed...")
	}

	for _, url := range urls {
		go func(url string) {
			defer func() { completed <- true }() // Ensure completion signal

			request, err := http.NewRequest("GET", url, nil)
			if err != nil {
				utils.Errorln("Failed to create request", "error", err)
				return
			}
			request.Header.Set("User-Agent", displayVersion)

			response, err := client.Do(request)
			if err != nil {
				utils.Errorln("Failed to perform request", "error", err)
				return
			}
			defer response.Body.Close()

			tapMeter := io.TeeReader(response.Body, &primaryBandwidthMeter)
			_, err = io.Copy(io.Discard, tapMeter)
			if err != nil {
				utils.Errorln("Failed to copy response body", "error", err)
				return
			}
		}(url)
	}

	monitorProgress(&primaryBandwidthMeter, uint64(count*26214400), completed, count)

	speed, unit := utils.BitsPerSecWithUnit(primaryBandwidthMeter.Bandwidth())
	return Speed{Speed: speed, Unit: unit}, nil
}

func measureUploadSpeed(urls []string) (Speed, error) {
	client := &http.Client{}
	uploadData := make([]byte, 26214400) // 25 MB
	chunkSize := 1024 * 1024             // 1 MB chunk
	count := uint64(len(urls))

	primaryBandwidthMeter := utils.BandwidthMeter{}
	completed := make(chan bool)

	primaryBandwidthMeter.Start()
	if !simpleProgress {
		utils.Println("\n⬆️ Estimating upload speed...")
	}
	for _, url := range urls {
		go func(url string) {
			defer func() { completed <- true }() // Ensure completion signal

			for offset := 0; offset < len(uploadData); offset += chunkSize {
				tapMeter := bytes.NewReader(uploadData[offset:min(offset+chunkSize, len(uploadData))])

				request, err := http.NewRequest("POST", url, tapMeter)
				if err != nil {
					utils.Errorln("Failed to create request", "error", err)
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
					utils.Errorln("Failed to copy request body", "error", err)
					return
				}
				request.Body = io.NopCloser(buffer)
				resp, err := client.Do(request)
				if err != nil {
					utils.Errorln("Failed to perform request", "error", err)
					return
				}
				resp.Body.Close()
				if err != nil {
					utils.Errorln("Failed to close response body", "error", err)
					return
				}
			}
		}(url)
	}

	monitorProgress(&primaryBandwidthMeter, uint64(count*26214400), completed, count)

	speed, unit := utils.BitsPerSecWithUnit(primaryBandwidthMeter.Bandwidth())
	return Speed{Speed: speed, Unit: unit}, nil
}
func monitorProgress(bandwidthMeter *utils.BandwidthMeter, bytesToRead uint64, completed chan bool, total uint64) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	timeout := time.After(maxDuration)
	var completeCount uint64

	for {
		select {
		case <-timeout:
			if !simpleProgress {
				printProgress(bandwidthMeter, bytesToRead)
				// utils.Println("\n🕒 Max duration reached, terminating the test.")
			}
			return

		case <-ticker.C:
			if !simpleProgress {
				printProgress(bandwidthMeter, bytesToRead)
			}

		case <-completed:
			completeCount++
			if completeCount == total {
				printProgress(bandwidthMeter, bytesToRead)
				return
			}
		}
	}
}

func printProgress(bandwidthMeter *utils.BandwidthMeter, bytesToRead uint64) {
	if !simpleProgress {
		// Cycle through spinner states
		spinner := spinnerStates[spinnerIndex]
		spinnerIndex = (spinnerIndex + 1) % len(spinnerStates)

		utils.Printf("\r%s %s - %s completed",
			spinner,
			utils.BitsPerSec(bandwidthMeter.Bandwidth()),
			utils.Percent(bandwidthMeter.BytesRead(), bytesToRead))
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
