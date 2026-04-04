package handler

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/gorilla/mux"
	"github.com/rs/zerolog/log"

	"book-trading/application/internal/middleware"
	"book-trading/application/internal/orderbook"
	"book-trading/application/internal/persistence"
)

type Handler struct {
	engine           *orderbook.Engine
	cache            *redis.Client
	snapshotCacheTTL time.Duration
	store            *persistence.RedisStore
}

func New(engine *orderbook.Engine, cache *redis.Client, snapshotCacheTTL time.Duration, store *persistence.RedisStore) *Handler {
	if snapshotCacheTTL <= 0 {
		snapshotCacheTTL = 100 * time.Millisecond
	}
	return &Handler{engine: engine, cache: cache, snapshotCacheTTL: snapshotCacheTTL, store: store}
}

type PlaceOrderRequest struct {
	Pair     string         `json:"pair"`
	Side     orderbook.Side `json:"side"`
	Price    float64        `json:"price"`
	Quantity float64        `json:"quantity"`
}

type APIResponse struct {
	Success   bool        `json:"success"`
	Data      interface{} `json:"data,omitempty"`
	Error     string      `json:"error,omitempty"`
	RequestID string      `json:"request_id"`
	Timestamp time.Time   `json:"timestamp"`
}

func (h *Handler) PlaceOrder(w http.ResponseWriter, r *http.Request) {
	reqID := middleware.GetRequestID(r.Context())

	var req PlaceOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, reqID, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Pair == "" || req.Price <= 0 || req.Quantity <= 0 {
		writeError(w, reqID, "pair, price, and quantity are required and must be positive", http.StatusBadRequest)
		return
	}
	if req.Side != orderbook.Buy && req.Side != orderbook.Sell {
		writeError(w, reqID, "side must be 'buy' or 'sell'", http.StatusBadRequest)
		return
	}

	order, trades, touched := h.engine.PlaceOrder(req.Pair, req.Side, req.Price, req.Quantity)
	if h.store != nil {
		h.store.RecordPlace(r.Context(), req.Pair, order, trades, touched)
	}

	h.cache.Del(r.Context(), "orderbook:"+req.Pair)

	writeSuccess(w, reqID, map[string]interface{}{
		"order":  order,
		"trades": trades,
	}, http.StatusCreated)
}

func (h *Handler) CancelOrder(w http.ResponseWriter, r *http.Request) {
	reqID := middleware.GetRequestID(r.Context())
	vars := mux.Vars(r)
	orderID := vars["id"]
	pair := r.URL.Query().Get("pair")

	if pair == "" {
		writeError(w, reqID, "pair query parameter is required", http.StatusBadRequest)
		return
	}

	if err := h.engine.CancelOrder(pair, orderID); err != nil {
		writeError(w, reqID, err.Error(), http.StatusNotFound)
		return
	}
	if h.store != nil {
		h.store.RecordCancel(r.Context(), pair, orderID)
	}

	h.cache.Del(r.Context(), "orderbook:"+pair)
	writeSuccess(w, reqID, map[string]string{"status": "cancelled"}, http.StatusOK)
}

func (h *Handler) GetOrderBook(w http.ResponseWriter, r *http.Request) {
	reqID := middleware.GetRequestID(r.Context())
	vars := mux.Vars(r)
	pair := vars["pair"]

	depth := 20
	if d := r.URL.Query().Get("depth"); d != "" {
		if parsed, err := strconv.Atoi(d); err == nil && parsed > 0 && parsed <= 100 {
			depth = parsed
		}
	}

	cacheKey := "orderbook:" + pair
	if cached, err := h.cache.Get(r.Context(), cacheKey).Bytes(); err == nil {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "HIT")
		w.Header().Set("X-Request-ID", reqID)
		if _, err := w.Write(cached); err != nil {
			log.Error().Err(err).Str("request_id", reqID).Msg("write cached orderbook")
		}
		return
	}

	snap := h.engine.Snapshot(pair, depth)

	if data, err := json.Marshal(APIResponse{
		Success:   true,
		Data:      snap,
		RequestID: reqID,
		Timestamp: time.Now().UTC(),
	}); err == nil {
		if err := h.cache.Set(r.Context(), cacheKey, data, h.snapshotCacheTTL).Err(); err != nil {
			log.Debug().Err(err).Msg("cache set failed")
		}
	}

	w.Header().Set("X-Cache", "MISS")
	writeSuccess(w, reqID, snap, http.StatusOK)
}

func (h *Handler) GetRecentTrades(w http.ResponseWriter, r *http.Request) {
	reqID := middleware.GetRequestID(r.Context())
	vars := mux.Vars(r)
	pair := vars["pair"]

	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 && parsed <= 500 {
			limit = parsed
		}
	}

	trades := h.engine.RecentTrades(pair, limit)
	writeSuccess(w, reqID, trades, http.StatusOK)
}

func writeSuccess(w http.ResponseWriter, reqID string, data interface{}, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Request-ID", reqID)
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(APIResponse{
		Success:   true,
		Data:      data,
		RequestID: reqID,
		Timestamp: time.Now().UTC(),
	}); err != nil {
		log.Error().Err(err).Str("request_id", reqID).Msg("encode success response")
	}
}

func writeError(w http.ResponseWriter, reqID, msg string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Request-ID", reqID)
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(APIResponse{
		Success:   false,
		Error:     msg,
		RequestID: reqID,
		Timestamp: time.Now().UTC(),
	}); err != nil {
		log.Error().Err(err).Str("request_id", reqID).Msg("encode error response")
	}
}
