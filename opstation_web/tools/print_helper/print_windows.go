//go:build windows

package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

var (
	winspool          = syscall.NewLazyDLL("winspool.drv")
	pOpenPrinter      = winspool.NewProc("OpenPrinterW")
	pClosePrinter     = winspool.NewProc("ClosePrinter")
	pStartDocPrinter  = winspool.NewProc("StartDocPrinterW")
	pEndDocPrinter    = winspool.NewProc("EndDocPrinter")
	pStartPagePrinter = winspool.NewProc("StartPagePrinter")
	pEndPagePrinter   = winspool.NewProc("EndPagePrinter")
	pWritePrinter     = winspool.NewProc("WritePrinter")
	pEnumPrinters     = winspool.NewProc("EnumPrintersW")
)

type docInfo1 struct {
	DocName    *uint16
	OutputFile *uint16
	Datatype   *uint16
}

type printerInfo4 struct {
	PrinterName *uint16
	ServerName  *uint16
	Attributes  uint32
}

func printRaw(printer, job string, data []byte) error {
	name, _ := syscall.UTF16PtrFromString(printer)
	var h syscall.Handle
	if r, _, e := pOpenPrinter.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&h)), 0); r == 0 {
		return fmt.Errorf("printer %q not found or not available (%v)", printer, e)
	}
	defer pClosePrinter.Call(uintptr(h))

	docName, _ := syscall.UTF16PtrFromString(job)
	dt, _ := syscall.UTF16PtrFromString("RAW")
	di := docInfo1{DocName: docName, Datatype: dt}
	if r, _, e := pStartDocPrinter.Call(uintptr(h), 1, uintptr(unsafe.Pointer(&di))); r == 0 {
		return fmt.Errorf("could not start the print job (%v)", e)
	}
	defer pEndDocPrinter.Call(uintptr(h))
	if r, _, e := pStartPagePrinter.Call(uintptr(h)); r == 0 {
		return fmt.Errorf("could not start the page (%v)", e)
	}
	defer pEndPagePrinter.Call(uintptr(h))

	var written uint32
	if r, _, e := pWritePrinter.Call(uintptr(h), uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)), uintptr(unsafe.Pointer(&written))); r == 0 {
		return fmt.Errorf("could not send to the printer (%v)", e)
	}
	if int(written) != len(data) {
		return fmt.Errorf("only %d of %d bytes were sent", written, len(data))
	}
	return nil
}

func listPrinters() ([]string, error) {
	const flags = 0x2 | 0x4 // PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS
	var needed, returned uint32
	pEnumPrinters.Call(flags, 0, 4, 0, 0, uintptr(unsafe.Pointer(&needed)), uintptr(unsafe.Pointer(&returned)))
	if needed == 0 {
		return []string{}, nil
	}
	buf := make([]byte, needed)
	if r, _, e := pEnumPrinters.Call(flags, 0, 4, uintptr(unsafe.Pointer(&buf[0])), uintptr(needed),
		uintptr(unsafe.Pointer(&needed)), uintptr(unsafe.Pointer(&returned))); r == 0 {
		return nil, fmt.Errorf("could not list printers (%v)", e)
	}
	out := make([]string, 0, returned)
	size := unsafe.Sizeof(printerInfo4{})
	for i := uint32(0); i < returned; i++ {
		pi := (*printerInfo4)(unsafe.Pointer(&buf[uintptr(i)*size]))
		out = append(out, utf16PtrToString(pi.PrinterName))
	}
	return out, nil
}

func utf16PtrToString(p *uint16) string {
	if p == nil {
		return ""
	}
	var s []uint16
	for ptr := unsafe.Pointer(p); ; ptr = unsafe.Pointer(uintptr(ptr) + 2) {
		c := *(*uint16)(ptr)
		if c == 0 {
			break
		}
		s = append(s, c)
	}
	return syscall.UTF16ToString(s)
}
