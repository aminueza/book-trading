package orderbook

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
)

type Side string

const (
	Buy  Side = "buy"
	Sell Side = "sell"
)

type OrderStatus string

const (
	StatusOpen      OrderStatus = "open"
	StatusFilled    OrderStatus = "filled"
	StatusPartial   OrderStatus = "partial"
	StatusCancelled OrderStatus = "cancelled"
)

type Order struct {
	ID        string      `json:"id"`
	Pair      string      `json:"pair"`
	Side      Side        `json:"side"`
	Price     float64     `json:"price"`
	Quantity  float64     `json:"quantity"`
	Remaining float64     `json:"remaining"`
	Status    OrderStatus `json:"status"`
	CreatedAt time.Time   `json:"created_at"`
}

type Trade struct {
	ID        string    `json:"id"`
	Pair      string    `json:"pair"`
	Price     float64   `json:"price"`
	Quantity  float64   `json:"quantity"`
	MakerID   string    `json:"maker_id"`
	TakerID   string    `json:"taker_id"`
	Timestamp time.Time `json:"timestamp"`
}

type Level struct {
	Price    float64 `json:"price"`
	Quantity float64 `json:"quantity"`
	Count    int     `json:"count"`
}

type BookSnapshot struct {
	Pair      string    `json:"pair"`
	Bids      []Level   `json:"bids"`
	Asks      []Level   `json:"asks"`
	Timestamp time.Time `json:"timestamp"`
}

type Engine struct {
	mu    sync.RWMutex
	books map[string]*book
}

type book struct {
	mu     sync.Mutex
	bids   []*Order
	asks   []*Order
	trades []Trade
}

func NewEngine() *Engine {
	return &Engine{
		books: make(map[string]*book),
	}
}

func (e *Engine) getOrCreateBook(pair string) *book {
	e.mu.RLock()
	b, ok := e.books[pair]
	e.mu.RUnlock()
	if ok {
		return b
	}

	e.mu.Lock()
	defer e.mu.Unlock()
	if b, ok = e.books[pair]; ok {
		return b
	}
	b = &book{}
	e.books[pair] = b
	return b
}

func (e *Engine) PlaceOrder(pair string, side Side, price, quantity float64) (*Order, []Trade, []*Order) {
	order := &Order{
		ID:        uuid.New().String(),
		Pair:      pair,
		Side:      side,
		Price:     price,
		Quantity:  quantity,
		Remaining: quantity,
		Status:    StatusOpen,
		CreatedAt: time.Now().UTC(),
	}

	b := e.getOrCreateBook(pair)
	b.mu.Lock()
	defer b.mu.Unlock()

	trades, touchedMakers := b.match(order)

	if order.Remaining > 0 {
		if order.Side == Buy {
			b.bids = append(b.bids, order)
			sort.Slice(b.bids, func(i, j int) bool {
				if b.bids[i].Price != b.bids[j].Price {
					return b.bids[i].Price > b.bids[j].Price
				}
				return b.bids[i].CreatedAt.Before(b.bids[j].CreatedAt)
			})
		} else {
			b.asks = append(b.asks, order)
			sort.Slice(b.asks, func(i, j int) bool {
				if b.asks[i].Price != b.asks[j].Price {
					return b.asks[i].Price < b.asks[j].Price
				}
				return b.asks[i].CreatedAt.Before(b.asks[j].CreatedAt)
			})
		}
	}

	seen := make(map[string]*Order, 1+len(touchedMakers))
	seen[order.ID] = order
	for _, o := range touchedMakers {
		if o != nil {
			seen[o.ID] = o
		}
	}
	out := make([]*Order, 0, len(seen))
	for _, o := range seen {
		out = append(out, o)
	}
	return order, trades, out
}

func (b *book) match(taker *Order) ([]Trade, []*Order) {
	var trades []Trade
	var touched []*Order
	var opposing *[]*Order

	if taker.Side == Buy {
		opposing = &b.asks
	} else {
		opposing = &b.bids
	}

	i := 0
	for i < len(*opposing) && taker.Remaining > 0 {
		maker := (*opposing)[i]

		if taker.Side == Buy && taker.Price < maker.Price {
			break
		}
		if taker.Side == Sell && taker.Price > maker.Price {
			break
		}

		fillQty := min(taker.Remaining, maker.Remaining)

		trade := Trade{
			ID:        uuid.New().String(),
			Pair:      taker.Pair,
			Price:     maker.Price,
			Quantity:  fillQty,
			MakerID:   maker.ID,
			TakerID:   taker.ID,
			Timestamp: time.Now().UTC(),
		}
		trades = append(trades, trade)
		b.trades = append(b.trades, trade)

		if len(b.trades) > 10000 {
			b.trades = b.trades[len(b.trades)-5000:]
		}

		taker.Remaining -= fillQty
		maker.Remaining -= fillQty

		if maker.Remaining <= 0 {
			maker.Status = StatusFilled
			touched = append(touched, maker)
			i++
		} else {
			maker.Status = StatusPartial
			touched = append(touched, maker)
		}

		if taker.Remaining <= 0 {
			taker.Status = StatusFilled
		} else {
			taker.Status = StatusPartial
		}
	}

	*opposing = (*opposing)[i:]

	return trades, touched
}

func (e *Engine) CancelOrder(pair, orderID string) error {
	b := e.getOrCreateBook(pair)
	b.mu.Lock()
	defer b.mu.Unlock()

	for i, o := range b.bids {
		if o.ID == orderID {
			o.Status = StatusCancelled
			b.bids = append(b.bids[:i], b.bids[i+1:]...)
			return nil
		}
	}
	for i, o := range b.asks {
		if o.ID == orderID {
			o.Status = StatusCancelled
			b.asks = append(b.asks[:i], b.asks[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("order %s not found in pair %s", orderID, pair)
}

func (e *Engine) RestoreOpenOrder(o *Order) error {
	if o == nil || o.Pair == "" || o.ID == "" {
		return fmt.Errorf("invalid order")
	}
	if o.Remaining <= 0 {
		return fmt.Errorf("nothing to restore")
	}
	if o.Status != StatusOpen && o.Status != StatusPartial {
		return fmt.Errorf("status %s not restorable", o.Status)
	}

	b := e.getOrCreateBook(o.Pair)
	b.mu.Lock()
	defer b.mu.Unlock()

	rest := *o
	restored := &rest

	if restored.Side == Buy {
		b.bids = append(b.bids, restored)
		sort.Slice(b.bids, func(i, j int) bool {
			if b.bids[i].Price != b.bids[j].Price {
				return b.bids[i].Price > b.bids[j].Price
			}
			return b.bids[i].CreatedAt.Before(b.bids[j].CreatedAt)
		})
	} else {
		b.asks = append(b.asks, restored)
		sort.Slice(b.asks, func(i, j int) bool {
			if b.asks[i].Price != b.asks[j].Price {
				return b.asks[i].Price < b.asks[j].Price
			}
			return b.asks[i].CreatedAt.Before(b.asks[j].CreatedAt)
		})
	}
	return nil
}

func (e *Engine) Snapshot(pair string, depth int) BookSnapshot {
	b := e.getOrCreateBook(pair)
	b.mu.Lock()
	defer b.mu.Unlock()

	snap := BookSnapshot{
		Pair:      pair,
		Timestamp: time.Now().UTC(),
	}

	snap.Bids = aggregateLevels(b.bids, depth)
	snap.Asks = aggregateLevels(b.asks, depth)

	return snap
}

func (e *Engine) RecentTrades(pair string, limit int) []Trade {
	b := e.getOrCreateBook(pair)
	b.mu.Lock()
	defer b.mu.Unlock()

	if limit > len(b.trades) {
		limit = len(b.trades)
	}
	result := make([]Trade, limit)
	copy(result, b.trades[len(b.trades)-limit:])
	return result
}

func aggregateLevels(orders []*Order, depth int) []Level {
	levelMap := make(map[float64]*Level)
	var prices []float64

	for _, o := range orders {
		if l, ok := levelMap[o.Price]; ok {
			l.Quantity += o.Remaining
			l.Count++
		} else {
			levelMap[o.Price] = &Level{
				Price:    o.Price,
				Quantity: o.Remaining,
				Count:    1,
			}
			prices = append(prices, o.Price)
		}
	}

	sort.Float64s(prices)
	var levels []Level
	for _, p := range prices {
		levels = append(levels, *levelMap[p])
		if len(levels) >= depth {
			break
		}
	}
	return levels
}
