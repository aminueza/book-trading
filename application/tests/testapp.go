package tests

import (
	"net/http"
	"testing"

	"github.com/go-redis/redis/v8"
	"github.com/gorilla/mux"
	"github.com/rs/zerolog"
	otelmux "go.opentelemetry.io/contrib/instrumentation/github.com/gorilla/mux/otelmux"

	"orderbook-service/application/internal/handler"
	"orderbook-service/application/internal/health"
	"orderbook-service/application/internal/middleware"
	"orderbook-service/application/internal/orderbook"

	miniredis "github.com/alicebob/miniredis/v2"
)

func testRouter(t *testing.T) (http.Handler, *miniredis.Miniredis, *redis.Client) {
	t.Helper()

	mr, err := miniredis.Run()
	if err != nil {
		t.Fatalf("miniredis: %v", err)
	}

	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	if err := rdb.Ping(t.Context()).Err(); err != nil {
		t.Fatalf("redis ping: %v", err)
	}

	engine := orderbook.NewEngine()
	h := handler.New(engine, rdb)
	hc := health.NewChecker(rdb)

	r := mux.NewRouter()
	r.Use(otelmux.Middleware("orderbook-test"))
	r.Use(middleware.RequestID)
	r.Use(middleware.Logging)
	r.Use(middleware.Metrics)
	r.Use(middleware.RateLimit(1000))
	r.Use(middleware.Recovery)

	api := r.PathPrefix("/api/v1").Subrouter()
	api.HandleFunc("/orders", h.PlaceOrder).Methods(http.MethodPost)
	api.HandleFunc("/orders/{id}", h.CancelOrder).Methods(http.MethodDelete)
	api.HandleFunc("/orderbook/{pair}", h.GetOrderBook).Methods(http.MethodGet)
	api.HandleFunc("/trades/{pair}", h.GetRecentTrades).Methods(http.MethodGet)

	r.HandleFunc("/healthz", hc.Liveness).Methods(http.MethodGet)
	r.HandleFunc("/readyz", hc.Readiness).Methods(http.MethodGet)

	return r, mr, rdb
}

func init() {
	zerolog.SetGlobalLevel(zerolog.Disabled)
}
