WEB_DIR := web

.PHONY: web web-dev build test vet clean
web:
	cd $(WEB_DIR) && npm ci && npm run build

web-dev:
	cd $(WEB_DIR) && npm run dev

build: web
	go build -o bin/medina ./cmd/medina

test:
	go test ./...

vet:
	go vet ./...

clean:
	rm -rf bin internal/httpapi/webdist/assets internal/httpapi/webdist/index.html internal/httpapi/webdist/swagger-ui-bundle.js internal/httpapi/webdist/swagger-ui.css
