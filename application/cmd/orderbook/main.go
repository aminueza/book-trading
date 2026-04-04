package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/gorilla/mux"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
	otelmux "go.opentelemetry.io/contrib/instrumentation/github.com/gorilla/mux/otelmux"

	"book-trading/application/internal/handler"
	"book-trading/application/internal/health"
	"book-trading/application/internal/middleware"
	"book-trading/application/internal/orderbook"
	"book-trading/application/internal/persistence"
	"book-trading/application/internal/telemetry"
)

var version = "dev"

type Config struct {
	Port             string
	MetricsPort      string
	RedisAddr        string
	RedisPassword    string
	RedisDB          int
	SnapshotCacheTTL time.Duration
	RedisRecoverOpen bool
	ShutdownTimeout  time.Duration
	ReadTimeout      time.Duration
	WriteTimeout     time.Duration
	IdleTimeout      time.Duration
	RateLimitRPS     int
}

func loadConfig() Config {
	return Config{
		Port:             getEnv("APP_PORT", "8080"),
		MetricsPort:      getEnv("METRICS_PORT", "9090"),
		RedisAddr:        getEnv("REDIS_ADDR", "localhost:6379"),
		RedisPassword:    getEnv("REDIS_PASSWORD", ""),
		RedisDB:          0,
		SnapshotCacheTTL: getDurationEnv("ORDERBOOK_SNAPSHOT_CACHE_TTL", 100*time.Millisecond),
		RedisRecoverOpen: getBoolEnv("ORDERBOOK_REDIS_RECOVER", false),
		ShutdownTimeout:  15 * time.Second,
		ReadTimeout:      5 * time.Second,
		WriteTimeout:     10 * time.Second,
		IdleTimeout:      120 * time.Second,
		RateLimitRPS:     1000,
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getDurationEnv(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		log.Warn().Str("env", key).Str("value", v).Msg("invalid duration; using default")
	}
	return fallback
}

func getBoolEnv(key string, fallback bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return fallback
	}
	return b
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-version") {
		_, _ = fmt.Fprintln(os.Stdout, version)
		os.Exit(0)
	}

	zerolog.TimeFieldFormat = time.RFC3339Nano
	zerolog.SetGlobalLevel(zerolog.InfoLevel)
	if os.Getenv("LOG_LEVEL") == "debug" {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}

	cfg := loadConfig()

	ctx := context.Background()
	shutdownTracer, err := telemetry.InitTracing(ctx, getEnv("OTEL_SERVICE_NAME", "orderbook-service"), version)
	if err != nil {
		log.Fatal().Err(err).Msg("OpenTelemetry init failed")
	}

	rdb := redis.NewClient(&redis.Options{
		Addr:         cfg.RedisAddr,
		Password:     cfg.RedisPassword,
		DB:           cfg.RedisDB,
		DialTimeout:  2 * time.Second,
		ReadTimeout:  1 * time.Second,
		WriteTimeout: 1 * time.Second,
		PoolSize:     50,
		MinIdleConns: 10,
	})

	redisErr := rdb.Ping(ctx).Err()
	if redisErr != nil {
		log.Warn().Err(redisErr).Msg("redis unavailable at startup; operating in degraded mode")
	} else {
		log.Info().Str("addr", cfg.RedisAddr).Msg("redis connected")
	}
	redisOK := redisErr == nil

	engine := orderbook.NewEngine()
	store := persistence.NewRedisStore(rdb)
	if cfg.RedisRecoverOpen && store != nil && redisOK {
		n, err := store.RecoverOpenOrders(ctx, engine)
		if err != nil {
			log.Warn().Err(err).Msg("redis order recovery failed")
		} else if n > 0 {
			log.Info().Int("restored_orders", n).Msg("redis order recovery complete")
		}
	}
	healthChecker := health.NewChecker(rdb)
	h := handler.New(engine, rdb, cfg.SnapshotCacheTTL, store)

	appRouter := mux.NewRouter()
	appRouter.Use(otelmux.Middleware(getEnv("OTEL_SERVICE_NAME", "orderbook-service")))
	appRouter.Use(middleware.RequestID)
	appRouter.Use(middleware.Logging)
	appRouter.Use(middleware.Metrics)
	appRouter.Use(middleware.RateLimit(cfg.RateLimitRPS))
	appRouter.Use(middleware.Recovery)

	api := appRouter.PathPrefix("/api/v1").Subrouter()
	api.HandleFunc("/orders", h.PlaceOrder).Methods("POST")
	api.HandleFunc("/orders/{id}", h.CancelOrder).Methods("DELETE")
	api.HandleFunc("/orderbook/{pair}", h.GetOrderBook).Methods("GET")
	api.HandleFunc("/trades/{pair}", h.GetRecentTrades).Methods("GET")

	appRouter.HandleFunc("/healthz", healthChecker.Liveness).Methods("GET")
	appRouter.HandleFunc("/readyz", healthChecker.Readiness).Methods("GET")

	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", promhttp.Handler())

	metricsServer := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.MetricsPort),
		Handler:      metricsMux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}

	appServer := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.Port),
		Handler:      appRouter,
		ReadTimeout:  cfg.ReadTimeout,
		WriteTimeout: cfg.WriteTimeout,
		IdleTimeout:  cfg.IdleTimeout,
	}

	errCh := make(chan error, 2)

	go func() {
		log.Info().Str("port", cfg.MetricsPort).Msg("metrics server starting")
		errCh <- metricsServer.ListenAndServe()
	}()

	go func() {
		log.Info().Str("port", cfg.Port).Msg("application server starting")
		errCh <- appServer.ListenAndServe()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		log.Info().Str("signal", sig.String()).Msg("shutdown signal received")
	case err := <-errCh:
		log.Error().Err(err).Msg("server error")
	}

	shutdownCtx, cancel := context.WithTimeout(ctx, cfg.ShutdownTimeout)
	defer cancel()

	log.Info().Msg("draining connections...")
	if err := appServer.Shutdown(shutdownCtx); err != nil {
		log.Error().Err(err).Msg("app server shutdown error")
	}
	if err := metricsServer.Shutdown(shutdownCtx); err != nil {
		log.Error().Err(err).Msg("metrics server shutdown error")
	}
	if err := rdb.Close(); err != nil {
		log.Error().Err(err).Msg("redis close error")
	}

	if err := shutdownTracer(shutdownCtx); err != nil {
		log.Error().Err(err).Msg("otel tracer shutdown error")
	}

	log.Info().Msg("shutdown complete")
}
