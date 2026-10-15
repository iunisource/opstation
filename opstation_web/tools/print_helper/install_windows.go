//go:build windows

package main

import (
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	user32          = syscall.NewLazyDLL("user32.dll")
	pMessageBox     = user32.NewProc("MessageBoxW")
	advapi32        = syscall.NewLazyDLL("advapi32.dll")
	pRegCreateKeyEx = advapi32.NewProc("RegCreateKeyExW")
	pRegSetValueEx  = advapi32.NewProc("RegSetValueExW")
	pRegDeleteValue = advapi32.NewProc("RegDeleteValueW")
	pRegCloseKey    = advapi32.NewProc("RegCloseKey")
)

const (
	hkeyCurrentUser = 0x80000001
	keySetValue     = 0x0002
	regSz           = 1
	runKey          = `Software\Microsoft\Windows\CurrentVersion\Run`
	runValue        = "OpstationPrintHelper"
)

func msgBox(title, text string, icon uint32) {
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(text)
	pMessageBox.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), uintptr(icon|0x00040000)) // MB_TOPMOST
}

func setRun(value string, remove bool) error {
	sub, _ := syscall.UTF16PtrFromString(runKey)
	var h syscall.Handle
	if r, _, e := pRegCreateKeyEx.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(sub)), 0, 0, 0, keySetValue, 0,
		uintptr(unsafe.Pointer(&h)), 0); r != 0 {
		return e
	}
	defer pRegCloseKey.Call(uintptr(h))
	name, _ := syscall.UTF16PtrFromString(runValue)
	if remove {
		pRegDeleteValue.Call(uintptr(h), uintptr(unsafe.Pointer(name)))
		return nil
	}
	data, _ := syscall.UTF16FromString(value)
	if r, _, e := pRegSetValueEx.Call(uintptr(h), uintptr(unsafe.Pointer(name)), 0, regSz,
		uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2)); r != 0 {
		return e
	}
	return nil
}

func running() bool {
	req, _ := http.NewRequest("GET", "http://"+addr+"/health", nil)
	req.Header.Set("Origin", allowedOrigins[0])
	c := http.Client{Timeout: 2 * time.Second}
	res, err := c.Do(req)
	if err != nil {
		return false
	}
	res.Body.Close()
	return res.StatusCode == 200
}

// Stop other copies of the helper — never this process itself.
func killOthers() {
	cmd := exec.Command("taskkill", "/f", "/im", "OpstationPrint.exe", "/fi", "PID ne "+strconv.Itoa(os.Getpid()))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	_ = cmd.Run()
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	out.Close()
	_ = os.Remove(dst)
	return os.Rename(tmp, dst)
}

// handleInstall returns true when this run was an install/uninstall (and the
// process should exit), false when it should serve (started with --background).
func handleInstall() bool {
	for _, a := range os.Args[1:] {
		switch strings.ToLower(a) {
		case "--background":
			return false
		case "--uninstall":
			_ = setRun("", true)
			killOthers()
			msgBox("Opstation Print Helper", "Removed. It will no longer start with Windows.", 0x40)
			return true
		}
	}

	self, _ := os.Executable()
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = appDir()
	}
	dir := filepath.Join(base, "OpstationPrint")
	_ = os.MkdirAll(dir, 0o755)
	target := filepath.Join(dir, "OpstationPrint.exe")

	if !strings.EqualFold(filepath.Clean(self), filepath.Clean(target)) {
		// Replace an older copy: stop it first so the file isn't locked.
		if running() {
			killOthers()
			time.Sleep(800 * time.Millisecond)
		}
		if err := copyFile(self, target); err != nil {
			msgBox("Opstation Print Helper",
				"Could not install: "+err.Error()+"\n\nIf your antivirus blocked it, allow OpstationPrint.exe and try again.", 0x10)
			return true
		}
	}
	_ = setRun(`"`+target+`" --background`, false)

	if !running() {
		cmd := exec.Command(target, "--background")
		cmd.Dir = dir
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		_ = cmd.Start()
		for i := 0; i < 20 && !running(); i++ {
			time.Sleep(250 * time.Millisecond)
		}
	}
	if running() {
		msgBox("Opstation Print Helper",
			"Installed and running (version "+version+").\n\nIt starts automatically with Windows.\nNow open Opstation in Chrome and print labels.", 0x40)
	} else {
		msgBox("Opstation Print Helper",
			"Installed, but it did not start.\n\nYour antivirus may have blocked OpstationPrint.exe — allow it, then double-click it again.", 0x30)
	}
	return true
}
