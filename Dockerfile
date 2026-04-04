FROM golang:1.24-bookworm AS builder

WORKDIR /build

ENV GOTOOLCHAIN=auto

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev
ARG TARGETARCH=amd64

RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION}" \
    -tags=netgo \
    -o /book-trading \
    ./application/cmd/orderbook

FROM gcr.io/distroless/static-debian12:nonroot

LABEL maintainer="reliability-engineering"
LABEL org.opencontainers.image.source="internal"
LABEL org.opencontainers.image.description="Book trading API"

COPY --from=builder /book-trading /book-trading

EXPOSE 8080 9090

USER nonroot:nonroot

ENTRYPOINT ["/book-trading"]
