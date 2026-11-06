# Agent Instructions

## Rebuild and Verification on Implementation Completion

When completing any implementation, fix, or feature in this repository, always rebuild and verify the affected parts of the application before finishing:

### 1. Web Frontend & Embedded Server Assets
The Go server embeds the compiled frontend from `internal/httpapi/webdist/` (`//go:embed webdist/*`).
- Whenever changes touch `web/` (such as `web/src/` or `web/index.html`):
  ```sh
  cd web && npm run build
  ```
- Or run `make web` (runs `npm ci && npm run build`).
- Verify that updated bundle artifacts in `internal/httpapi/webdist/` are staged and committed alongside frontend source changes.

### 2. Go Backend
- Run Go tests and static analysis:
  ```sh
  make test
  make vet
  ```
- Build the binary if testing a local build:
  ```sh
  make build   # builds web assets then compiles bin/medina
  ```

### 3. Native macOS Application
- Run Swift package tests:
  ```sh
  make macos-test
  ```
- When modifying Xcode project configurations, app code in `native/macos/`, or Swift packages:
  ```sh
  make macos-build   # regenerates Xcode project and runs xcodebuild
  ```

### 4. Full Quality Gate
Before completing and committing changes:
```sh
make test && make vet && make macos-test
```
