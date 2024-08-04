package utils

import (
	"fmt"
	"io"
	"os"
)

func PrintJSON(format string, a ...any) {
	if AppConfig.JsonOutput {
		fmt.Printf(format, a...)
	}
}

func Debugln(a ...any) {
	if AppConfig.Debug {
		fmt.Println(a...)
	}
}

func Debugf(format string, a ...any) {
	if AppConfig.Debug {
		fmt.Printf(format, a...)
	}
}

func Println(a ...any) {
	if !AppConfig.JsonOutput {
		fmt.Println(a...)
	}
}

func Fprintf(w io.Writer, format string, a ...any) {
	if !AppConfig.JsonOutput {
		fmt.Fprintf(w, format, a...)
	}
}

func Printf(format string, a ...any) {
	if !AppConfig.JsonOutput {
		fmt.Printf(format, a...)
	}
}

func Print(a ...any) {
	if !AppConfig.JsonOutput {
		fmt.Print(a...)
	}
}

func Errorln(a ...any) {
	fmt.Fprintln(os.Stderr, a...)
}

func Errorf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format, a...)
}
