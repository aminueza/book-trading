package health

import (
	"encoding/json"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/rs/zerolog/log"
)

type Checker struct {
	redis *redis.Client
	ready atomic.Bool
}

type HealthResponse struct {
	Status    string            `json:"status"`
	Checks    map[string]string `json:"checks,omitempty"`
	Timestamp time.Time         `json:"timestamp"`
}

func NewChecker(rdb *redis.Client) *Checker {
	c := &Checker{redis: rdb}
	c.ready.Store(true)
	return c
}

func (c *Checker) SetReady(ready bool) {
	c.ready.Store(ready)
}

func (c *Checker) Liveness(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(HealthResponse{
		Status:    "ok",
		Timestamp: time.Now().UTC(),
	}); err != nil {
		log.Error().Err(err).Msg("encode liveness")
	}
}

func (c *Checker) Readiness(w http.ResponseWriter, r *http.Request) {
	checks := make(map[string]string)
	status := "ok"
	httpStatus := http.StatusOK

	if !c.ready.Load() {
		checks["app"] = "not_ready"
		status = "degraded"
		httpStatus = http.StatusServiceUnavailable
	} else {
		checks["app"] = "ok"
	}

	ctx := r.Context()
	if err := c.redis.Ping(ctx).Err(); err != nil {
		checks["redis"] = "unavailable"
		if status == "ok" {
			status = "degraded"
		}
	} else {
		checks["redis"] = "ok"
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(httpStatus)
	if err := json.NewEncoder(w).Encode(HealthResponse{
		Status:    status,
		Checks:    checks,
		Timestamp: time.Now().UTC(),
	}); err != nil {
		log.Error().Err(err).Msg("encode readiness")
	}
}
