# syntax=docker/dockerfile:1
# Set false for an API-only image: skip Node and exclude all frontend assets.
ARG BUNDLE_FRONTEND=true

FROM node:22-alpine AS frontend-true
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build \
    && mkdir -p /frontend \
    && cp -R /src/internal/httpapi/webdist/. /frontend/

# Supply a copyable directory without installing Node or building the frontend.
FROM scratch AS frontend-false
COPY go.mod /frontend/.headless

FROM frontend-${BUNDLE_FRONTEND} AS frontend

FROM golang:1.24-alpine AS go-build
ARG BUNDLE_FRONTEND
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=frontend /frontend/ ./internal/httpapi/webdist/
RUN case "$BUNDLE_FRONTEND" in \
      true) tags="" ;; \
      false) tags="no_frontend" ;; \
      *) echo "BUNDLE_FRONTEND must be true or false" >&2; exit 1 ;; \
    esac \
    && CGO_ENABLED=0 go build -tags="$tags" -trimpath -ldflags="-s -w" -o /out/medina ./cmd/medina \
    && mkdir -p /out/data \
    && chown -R 65532:65532 /out/data

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=go-build /out/medina /medina
COPY --from=go-build --chown=nonroot:nonroot /out/data /data
ENV BIND_ADDRESS=0.0.0.0:8080 \
    CONTENT_ROOT=/library \
    DATABASE_PATH=/data/course-media.sqlite \
    LIBRARY_NAME="Development Library" \
    LOG_LEVEL=info
EXPOSE 8080
ENTRYPOINT ["/medina"]
