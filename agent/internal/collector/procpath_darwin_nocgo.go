//go:build darwin && !cgo

package collector

import "fmt"

func processPath(pid int) (string, error) {
	return "", fmt.Errorf("%w for pid %d; rebuild with cgo enabled", errProcessPathUnsupported, pid)
}
