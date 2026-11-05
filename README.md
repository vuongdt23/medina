# Medina

A local course-library server. Medina indexes existing folders in SQLite and provides a web UI for browsing lessons, playing original media, and previewing or downloading supporting files. Your library is never modified.

## Quick start

### Docker

```sh
cp .env.example .env
docker compose up --build medina
```

Open **http://127.0.0.1:8080**. The included sample library is mounted read-only. To use your own library, set `LIBRARY_MOUNT` in `.env`, or run:

```sh
LIBRARY_MOUNT=/Volumes/Courses docker compose up --build medina
```

The index is stored in a persistent Docker volume.

For an **API-only image**, without the web UI or Swagger assets:

```sh
BUNDLE_FRONTEND=false docker compose up --build medina
# Or: docker build --build-arg BUNDLE_FRONTEND=false -t medina:api .
```

`BUNDLE_FRONTEND` defaults to `true`. API-only builds skip Node, return 404 for UI routes, and keep `/openapi.yaml` available.

### Local

Requires **Go 1.24+**, **Node.js 20+**, and npm to build. Node.js is not needed to run the resulting binary.

```sh
make build
CONTENT_ROOT=/path/to/courses ./bin/medina
```

Each folder directly under `CONTENT_ROOT` becomes a course. Nested folders with media become sections; other files and folders are supporting assets.

## Configuration

Use environment variables for local runs, or `.env` with Docker Compose.

| Variable | Default | Purpose |
|---|---|---|
| `CONTENT_ROOT` | required; `/library` in Docker | Library directory visible to the server |
| `LIBRARY_MOUNT` | `./testdata` | Host library directory, Docker only |
| `BIND_ADDRESS` | `127.0.0.1:8080` | Server listen address; Docker uses `0.0.0.0:8080` internally |
| `DATABASE_PATH` | `./data/course-media.sqlite` | Index location; Docker uses `/data/course-media.sqlite` |
| `LIBRARY_NAME` | `Courses` | Display name |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |
| `SCAN_INTERVAL` | `6h` | Periodic full scan |
| `SCAN_WATCH` | `true` | Rescan on filesystem changes |
| `SCAN_DEBOUNCE` | `2s` | Wait after a burst of changes |
| `SCAN_WORKERS` | `8` | Concurrent metadata reads, 1–64 |
| `SCAN_DIRECTORY_WORKERS` | `4` | Concurrent directory listings, 1–64 |

Medina scans at startup, watches for changes, and periodically reconciles the library. Use **Rescan** in the UI to scan manually. Keep periodic scans enabled for Docker, SMB, or NFS mounts, where filesystem events can be missed.

## Things to know

- **No authentication.** Keep Medina on loopback or a trusted network. Docker publishes the app on host loopback by default.
- **No transcoding.** Playback depends on your browser's codec support.
- **Safe previews.** Source files, common images, and PDFs can be previewed; active documents such as HTML and SVG are download-only.
- **Folder ZIPs.** Downloads use temporary storage outside the library, cleaned up afterward. Limits: 10,000 files, 2 GiB of source data, and 512 MiB compressed. Leave enough space in the OS temporary directory.

## Development

```sh
make test       # Go tests
make vet        # Go static checks
make web-dev    # Vite UI; proxies API requests to localhost:8080
```

Run the backend separately with `CONTENT_ROOT=/path/to/courses go run ./cmd/medina`. `make build` rebuilds the embedded UI and server. For a local API-only binary, use `go build -tags no_frontend -o bin/medina ./cmd/medina` (no Node build required).

API documentation: **[/swagger/](http://127.0.0.1:8080/swagger/)**. The source specification is [`api/openapi.yaml`](api/openapi.yaml).

### Optional logging stack

Run `docker compose up --build` to include Grafana, Loki, and Alloy. Grafana is at **http://127.0.0.1:3000**, with development credentials `admin` / `admin` (configurable in `.env`). In Explore, query `{service="medina"}`. Alloy needs privileged access to the Docker socket to collect container logs.
