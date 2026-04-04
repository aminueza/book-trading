package persistence

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/rs/zerolog/log"

	"book-trading/application/internal/orderbook"
)

const (
	orderKeyPrefix = "persist:order:"
	journalKey     = "persist:journal"
	journalMaxLen  = 10000
)

type RedisStore struct {
	rdb *redis.Client
}

func NewRedisStore(rdb *redis.Client) *RedisStore {
	if rdb == nil {
		return nil
	}
	return &RedisStore{rdb: rdb}
}

func orderKey(id string) string {
	return orderKeyPrefix + id
}

func (s *RedisStore) RecordPlace(ctx context.Context, pair string, primary *orderbook.Order, trades []orderbook.Trade, touched []*orderbook.Order) {
	if s == nil || s.rdb == nil {
		return
	}
	entry := map[string]interface{}{
		"type":    "place",
		"pair":    pair,
		"order":   primary,
		"trades":  trades,
		"ts":      time.Now().UTC(),
		"updated": touched,
	}
	s.appendJournal(ctx, entry)

	for _, o := range touched {
		if o == nil {
			continue
		}
		s.saveOrder(ctx, o)
	}
}

func (s *RedisStore) RecordCancel(ctx context.Context, pair, orderID string) {
	if s == nil || s.rdb == nil {
		return
	}
	key := orderKey(orderID)
	raw, err := s.rdb.Get(ctx, key).Bytes()
	if err == nil {
		var o orderbook.Order
		if json.Unmarshal(raw, &o) == nil {
			o.Status = orderbook.StatusCancelled
			s.saveOrder(ctx, &o)
		}
	}
	_ = s.appendJournal(ctx, map[string]interface{}{
		"type":     "cancel",
		"pair":     pair,
		"order_id": orderID,
		"ts":       time.Now().UTC(),
	})
}

func (s *RedisStore) saveOrder(ctx context.Context, o *orderbook.Order) {
	data, err := json.Marshal(o)
	if err != nil {
		log.Debug().Err(err).Str("order_id", o.ID).Msg("persist marshal order")
		return
	}
	if err := s.rdb.Set(ctx, orderKey(o.ID), data, 0).Err(); err != nil {
		log.Debug().Err(err).Str("order_id", o.ID).Msg("persist set order")
	}
}

func (s *RedisStore) appendJournal(ctx context.Context, v interface{}) error {
	line, err := json.Marshal(v)
	if err != nil {
		return err
	}
	pipe := s.rdb.Pipeline()
	pipe.LPush(ctx, journalKey, string(line))
	pipe.LTrim(ctx, journalKey, 0, journalMaxLen-1)
	_, err = pipe.Exec(ctx)
	return err
}

func (s *RedisStore) RecoverOpenOrders(ctx context.Context, eng *orderbook.Engine) (int, error) {
	if s == nil || s.rdb == nil || eng == nil {
		return 0, nil
	}
	var n int
	iter := s.rdb.Scan(ctx, 0, orderKeyPrefix+"*", 256).Iterator()
	for iter.Next(ctx) {
		key := iter.Val()
		id := strings.TrimPrefix(key, orderKeyPrefix)
		if id == "" {
			continue
		}
		raw, err := s.rdb.Get(ctx, key).Bytes()
		if err != nil {
			continue
		}
		var o orderbook.Order
		if err := json.Unmarshal(raw, &o); err != nil {
			continue
		}
		if o.ID != id {
			continue
		}
		if o.Status == orderbook.StatusCancelled || o.Status == orderbook.StatusFilled {
			continue
		}
		if o.Remaining <= 0 {
			continue
		}
		if err := eng.RestoreOpenOrder(&o); err != nil {
			log.Warn().Err(err).Str("order_id", o.ID).Msg("skip restore order")
			continue
		}
		n++
	}
	if err := iter.Err(); err != nil {
		return n, fmt.Errorf("scan persist orders: %w", err)
	}
	if n > 0 {
		log.Info().Int("count", n).Msg("restored open orders from Redis")
	}
	return n, nil
}
