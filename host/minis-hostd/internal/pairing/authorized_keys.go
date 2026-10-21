package pairing

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// AddAuthorizedKey appends the key to ~/.ssh/authorized_keys unless the same key is already there,
// and reports whether it wrote. sshd refuses a group- or world-writable ~/.ssh, so both are created
// private; existing modes are left as the user set them.
func AddAuthorizedKey(home string, key AuthorizedKey) (bool, error) {
	dir := filepath.Join(home, ".ssh")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return false, fmt.Errorf("creating %s: %w", dir, err)
	}
	path := filepath.Join(dir, "authorized_keys")
	existing, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return false, fmt.Errorf("reading %s: %w", path, err)
	}
	for _, line := range strings.Split(string(existing), "\n") {
		if sameKey(line, key) {
			return false, nil
		}
	}
	addition := key.Line() + "\n"
	if len(existing) > 0 && existing[len(existing)-1] != '\n' {
		addition = "\n" + addition
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return false, fmt.Errorf("opening %s: %w", path, err)
	}
	if _, err := file.WriteString(addition); err != nil {
		file.Close()
		return false, fmt.Errorf("writing %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return false, fmt.Errorf("writing %s: %w", path, err)
	}
	return true, nil
}
