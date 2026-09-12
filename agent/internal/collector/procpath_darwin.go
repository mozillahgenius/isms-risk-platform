//go:build darwin

package collector

/*
#cgo LDFLAGS: -lproc
#include <libproc.h>
#include <stdint.h>

static int lookup_proc_path(int pid, char *buffer, uint32_t size) {
	return proc_pidpath(pid, buffer, size);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func processPath(pid int) (string, error) {
	var buffer [C.PROC_PIDPATHINFO_MAXSIZE]C.char
	length := C.lookup_proc_path(C.int(pid), &buffer[0], C.uint32_t(len(buffer)))
	if length <= 0 {
		return "", fmt.Errorf("proc_pidpath(%d) failed", pid)
	}
	return C.GoString((*C.char)(unsafe.Pointer(&buffer[0]))), nil
}
