package fast

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	printer "mikkelam/fast-cli/utils"
	"net/http"
	"regexp"
)

// UseHTTPS sets if HTTPS is used
var UseHTTPS = true

// GetUrls returns a list of urls to the fast api downloads
func GetUrls(urlCount uint64) (urls []string, err error) {
	token, err := getFastToken()
	if err != nil {
		return nil, err
	}

	httpProtocol := "https"
	if !UseHTTPS {
		httpProtocol = "http"
	}

	url := fmt.Sprintf("%s://api.fast.com/netflix/speedtest?https=%t&token=%s&urlCount=%d",
		httpProtocol, UseHTTPS, token, urlCount)
	printer.Debugln(fmt.Sprintf("getting download urls from %s", url))

	jsonData, _ := getPage(url)

	re := regexp.MustCompile("(?U)\"url\":\"(.*)\"")
	reUrls := re.FindAllStringSubmatch(jsonData, -1)

	printer.Debugln("urls:")
	for _, arr := range reUrls {
		urls = append(urls, arr[1])
		printer.Debugln(fmt.Sprintf(" - %s", arr[1]))
	}

	return
}

// GetDefaultURL returns the fallback download URL
func GetDefaultURL() (url string) {
	httpProtocol := "https"
	if !UseHTTPS {
		httpProtocol = "http"
	}
	url = fmt.Sprintf("%s://api.fast.com/netflix/speedtest", httpProtocol)
	return
}

func getFastToken() (token string, err error) {
	baseURL := "https://fast.com"
	if !UseHTTPS {
		baseURL = "http://fast.com"
	}
	fastBody, _ := getPage(baseURL)

	// Extract the app script url
	re := regexp.MustCompile(`app-.*\.js`)
	scriptNames := re.FindAllString(fastBody, 1)

	scriptURL := fmt.Sprintf("%s/%s", baseURL, scriptNames[0])
	printer.Debugln(fmt.Sprintf("trying to get fast api token from %s", scriptURL))

	// Extract the token
	scriptBody, _ := getPage(scriptURL)

	re = regexp.MustCompile("token:\"[[:alpha:]]*\"")
	tokens := re.FindAllString(scriptBody, 1)

	if len(tokens) > 0 {
		token = tokens[0][7 : len(tokens[0])-1]
		printer.Debugln(fmt.Sprintf("found token %s", token))
	} else {
		err := errors.New("could not find fast api token")
		printer.Debugln(err)

	}
	return token, err
}

func getPage(url string) (contents string, err error) {
	// Create the string buffer
	buffer := bytes.NewBuffer(nil)

	// Get the data
	resp, err := http.Get(url)
	if err != nil {
		return contents, err
	}
	defer resp.Body.Close()

	// Writer the body to file
	_, err = io.Copy(buffer, resp.Body)
	if err != nil {
		return contents, err
	}
	contents = buffer.String()

	return
}
