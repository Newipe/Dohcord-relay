// Command pishcord-relayd is the background server for a Pishcord relay VPS. It
// serves the public configuration API and manages the destination policy of the
// HTTPS CONNECT proxy.
//
// The command-line surface is documented in docs/configuration.md; the
// implementation lives in internal/app, internal/api and internal/policy.
//
// The user-facing command is cmd/pishcord-relay, the management console.
package main

import "github.com/Newipe/Pishcord-relay/internal/app"

func main() {
	app.Main()
}
