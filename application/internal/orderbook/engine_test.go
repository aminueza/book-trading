package orderbook

import (
	"sync"
	"testing"
)

func TestPlaceOrder_BasicMatching(t *testing.T) {
	engine := NewEngine()

	sell, _ := engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	if sell.Status != StatusOpen {
		t.Fatalf("expected open, got %s", sell.Status)
	}

	buy, trades := engine.PlaceOrder("BTC-USD", Buy, 50000.0, 0.5)
	if len(trades) != 1 {
		t.Fatalf("expected 1 trade, got %d", len(trades))
	}
	if trades[0].Quantity != 0.5 {
		t.Fatalf("expected trade quantity 0.5, got %f", trades[0].Quantity)
	}
	if trades[0].Price != 50000.0 {
		t.Fatalf("expected trade at maker price 50000, got %f", trades[0].Price)
	}
	if buy.Status != StatusFilled {
		t.Fatalf("expected taker filled, got %s", buy.Status)
	}
}

func TestPlaceOrder_PriceTimePriority(t *testing.T) {
	engine := NewEngine()

	engine.PlaceOrder("ETH-USD", Sell, 3000.0, 1.0)
	engine.PlaceOrder("ETH-USD", Sell, 2900.0, 1.0)

	_, trades := engine.PlaceOrder("ETH-USD", Buy, 3000.0, 0.5)
	if len(trades) != 1 {
		t.Fatalf("expected 1 trade, got %d", len(trades))
	}
	if trades[0].Price != 2900.0 {
		t.Fatalf("expected trade at 2900 (best ask), got %f", trades[0].Price)
	}
}

func TestPlaceOrder_NoMatch(t *testing.T) {
	engine := NewEngine()

	engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	_, trades := engine.PlaceOrder("BTC-USD", Buy, 49000.0, 1.0)
	if len(trades) != 0 {
		t.Fatalf("expected no trades, got %d", len(trades))
	}
}

func TestCancelOrder(t *testing.T) {
	engine := NewEngine()

	order, _ := engine.PlaceOrder("BTC-USD", Buy, 50000.0, 1.0)
	err := engine.CancelOrder("BTC-USD", order.ID)
	if err != nil {
		t.Fatalf("cancel failed: %v", err)
	}

	_, trades := engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	if len(trades) != 0 {
		t.Fatalf("expected no trades after cancel, got %d", len(trades))
	}
}

func TestSnapshot(t *testing.T) {
	engine := NewEngine()

	engine.PlaceOrder("BTC-USD", Buy, 49000.0, 1.0)
	engine.PlaceOrder("BTC-USD", Buy, 49000.0, 0.5)
	engine.PlaceOrder("BTC-USD", Sell, 51000.0, 2.0)

	snap := engine.Snapshot("BTC-USD", 10)
	if len(snap.Bids) != 1 {
		t.Fatalf("expected 1 bid level, got %d", len(snap.Bids))
	}
	if snap.Bids[0].Quantity != 1.5 {
		t.Fatalf("expected aggregated bid quantity 1.5, got %f", snap.Bids[0].Quantity)
	}
	if snap.Bids[0].Count != 2 {
		t.Fatalf("expected bid count 2, got %d", snap.Bids[0].Count)
	}
}

func TestConcurrentOrders(t *testing.T) {
	engine := NewEngine()
	var wg sync.WaitGroup

	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			engine.PlaceOrder("BTC-USD", Buy, 50000.0, 0.01)
		}()
		go func() {
			defer wg.Done()
			engine.PlaceOrder("BTC-USD", Sell, 50000.0, 0.01)
		}()
	}
	wg.Wait()

	trades := engine.RecentTrades("BTC-USD", 200)
	if len(trades) == 0 {
		t.Fatal("expected some trades from concurrent matching")
	}
}
