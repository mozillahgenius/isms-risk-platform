//go:build !darwin

package collector

import "fmt"

func processPath(pid int) (string, error) {
	return "", fmt.Errorf("%w for pid %d", errProcessPathUnsupported, pid)
}
