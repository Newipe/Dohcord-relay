GO ?= go
DAEMON ?= dohcord-relayd
CONSOLE ?= dohcord-relay

# Release builds override VERSION with the Git tag. Local builds say "dev" so a
# development binary can never be mistaken for a published release.
VERSION ?= dev
COMMIT ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell git log -1 --format=%cI 2>/dev/null || echo unknown)
LDFLAGS := -s -w \
	-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Version=$(VERSION) \
	-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Commit=$(COMMIT) \
	-X github.com/Newipe/Dohcord-relay/internal/buildinfo.Date=$(BUILD_DATE)

.PHONY: all build daemon console test vet fmt check clean install

all: check build

# build produces both programs: the server (dohcord-relayd) and the management
# console (dohcord-relay). Servers normally install the published release
# binaries; these targets are for development and for release packaging.
build: daemon console

daemon:
	$(GO) build -trimpath -buildvcs=false -ldflags="$(LDFLAGS)" -o $(DAEMON) ./cmd/dohcord-relayd

console:
	$(GO) build -trimpath -buildvcs=false -ldflags="$(LDFLAGS)" -o $(CONSOLE) ./cmd/dohcord-relay

test:
	$(GO) test ./...

vet:
	$(GO) vet ./...

fmt:
	gofmt -w cmd internal

# The full local suite: formatting, vet, tests, shell syntax and the API port
# integration tests.
check:
	./scripts/check.sh

# Local development only. Servers install the release binaries through
# deploy/install.sh, which also configures Squid, coturn and certificates and
# installs the console script.
install: build
	install -m 0755 $(DAEMON) $(DESTDIR)/usr/local/bin/$(DAEMON)
	install -m 0755 $(CONSOLE) $(DESTDIR)/usr/local/bin/$(CONSOLE)

clean:
	rm -f $(DAEMON) $(CONSOLE)
