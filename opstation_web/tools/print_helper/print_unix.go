//go:build !windows

package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

func printRaw(printer, job string, data []byte) error {
	cmd := exec.Command("lp", "-d", printer, "-t", job, "-o", "raw")
	cmd.Stdin = bytes.NewReader(data)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func listPrinters() ([]string, error) {
	out, err := exec.Command("lpstat", "-e").Output()
	if err != nil {
		return []string{}, nil
	}
	var list []string
	for _, l := range strings.Split(string(out), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			list = append(list, l)
		}
	}
	return list, nil
}
