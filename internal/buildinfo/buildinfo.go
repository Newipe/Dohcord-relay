// Package buildinfo carries version and provenance data injected at build time.
//
// The release workflow sets these values with -ldflags:
//
//	-X github.com/Newipe/Pishcord-relay/internal/buildinfo.Version=v1.1.0
//	-X github.com/Newipe/Pishcord-relay/internal/buildinfo.Commit=<git sha>
//	-X github.com/Newipe/Pishcord-relay/internal/buildinfo.Date=<commit date>
//
// Local `go build` runs keep the defaults, so a development binary reports
// itself as dev rather than pretending to be a release.
package buildinfo

import (
	"fmt"
	"runtime"
)

var (
	// Version is the release tag, for example v1.1.0.
	Version = "dev"
	// Commit is the full Git commit the binary was built from.
	Commit = "unknown"
	// Date is the commit date in RFC 3339 form, so a rebuild of the same tag
	// produces the same value.
	Date = "unknown"
)

// String describes a binary built from this package for program name.
func String(program string) string {
	return fmt.Sprintf("%s %s (commit %s, built %s, %s/%s)",
		program, Version, Commit, Date, runtime.GOOS, runtime.GOARCH)
}
