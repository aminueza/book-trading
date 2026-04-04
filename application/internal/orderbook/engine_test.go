package orderbook

import (
	"sync"
	"testing"
)

func TestPlaceOrder_BasicMatching(t *testing.T) {
	engine := NewEngine()

	sell, _, _ := engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	if sell.Status != StatusOpen {
		t.Fatalf("expected open, got %s", sell.Status)
	}

	buy, trades, _ := engine.PlaceOrder("BTC-USD", Buy, 50000.0, 0.5)
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

	_, _, _ = engine.PlaceOrder("ETH-USD", Sell, 3000.0, 1.0)
	_, _, _ = engine.PlaceOrder("ETH-USD", Sell, 2900.0, 1.0)

	_, trades, _ := engine.PlaceOrder("ETH-USD", Buy, 3000.0, 0.5)
	if len(trades) != 1 {
		t.Fatalf("expected 1 trade, got %d", len(trades))
	}
	if trades[0].Price != 2900.0 {
		t.Fatalf("expected trade at 2900 (best ask), got %f", trades[0].Price)
	}
}

func TestPlaceOrder_NoMatch(t *testing.T) {
	engine := NewEngine()

	_, _, _ = engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	_, trades, _ := engine.PlaceOrder("BTC-USD", Buy, 49000.0, 1.0)
	if len(trades) != 0 {
		t.Fatalf("expected no trades, got %d", len(trades))
	}
}

func TestCancelOrder(t *testing.T) {
	engine := NewEngine()

	order, _, _ := engine.PlaceOrder("BTC-USD", Buy, 50000.0, 1.0)
	err := engine.CancelOrder("BTC-USD", order.ID)
	if err != nil {
		t.Fatalf("cancel failed: %v", err)
	}

	_, trades, _ := engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	if len(trades) != 0 {
		t.Fatalf("expected no trades after cancel, got %d", len(trades))
	}
}

func TestSnapshot(t *testing.T) {
	engine := NewEngine()

	_, _, _ = engine.PlaceOrder("BTC-USD", Buy, 49000.0, 1.0)
	_, _, _ = engine.PlaceOrder("BTC-USD", Buy, 49000.0, 0.5)
	_, _, _ = engine.PlaceOrder("BTC-USD", Sell, 51000.0, 2.0)

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

func TestPlaceOrder_MultiLevelSweep(t *testing.T) {
	engine := NewEngine()

	// Place asks at three price levels.
	engine.PlaceOrder("BTC-USD", Sell, 100.0, 1.0)
	engine.PlaceOrder("BTC-USD", Sell, 101.0, 1.0)
	engine.PlaceOrder("BTC-USD", Sell, 102.0, 1.0)

	// A large buy should sweep through all three levels.
	order, trades, _ := engine.PlaceOrder("BTC-USD", Buy, 102.0, 2.5)
	if len(trades) != 3 {
		t.Fatalf("expected 3 trades (sweep), got %d", len(trades))
	}
	if trades[0].Price != 100.0 || trades[1].Price != 101.0 || trades[2].Price != 102.0 {
		t.Fatalf("expected trades at 100, 101, 102; got %f, %f, %f", trades[0].Price, trades[1].Price, trades[2].Price)
	}
	// 2.5 total: 1.0 + 1.0 + 0.5 from the third level.
	if trades[2].Quantity != 0.5 {
		t.Fatalf("expected partial fill of 0.5 on third level, got %f", trades[2].Quantity)
	}
	if order.Status != StatusFilled {
		t.Fatalf("expected taker filled, got %s", order.Status)
	}
}

func TestPlaceOrder_ExactFill(t *testing.T) {
	engine := NewEngine()

	sell, _, _ := engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	buy, trades, touched := engine.PlaceOrder("BTC-USD", Buy, 50000.0, 1.0)

	if len(trades) != 1 {
		t.Fatalf("expected 1 trade, got %d", len(trades))
	}
	if buy.Status != StatusFilled {
		t.Fatalf("expected buyer filled, got %s", buy.Status)
	}
	// Verify the maker is also filled in the touched slice.
	found := false
	for _, o := range touched {
		if o.ID == sell.ID && o.Status == StatusFilled {
			found = true
		}
	}
	if !found {
		t.Fatal("expected seller to be filled in touched orders")
	}

	// Book should be empty.
	snap := engine.Snapshot("BTC-USD", 10)
	if len(snap.Bids) != 0 || len(snap.Asks) != 0 {
		t.Fatalf("expected empty book after exact fill, got %d bids, %d asks", len(snap.Bids), len(snap.Asks))
	}
}

func TestPlaceOrder_MultiplePairs(t *testing.T) {
	engine := NewEngine()

	engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	_, trades, _ := engine.PlaceOrder("ETH-USD", Buy, 50000.0, 1.0)

	if len(trades) != 0 {
		t.Fatalf("expected no cross-pair matching, got %d trades", len(trades))
	}
}

func TestCancelOrder_NotFound(t *testing.T) {
	engine := NewEngine()

	engine.PlaceOrder("BTC-USD", Buy, 50000.0, 1.0)
	err := engine.CancelOrder("BTC-USD", "nonexistent-id")
	if err == nil {
		t.Fatal("expected error when cancelling nonexistent order")
	}
}

func TestSnapshot_EmptyBook(t *testing.T) {
	engine := NewEngine()
	snap := engine.Snapshot("UNKNOWN-PAIR", 10)

	if snap.Pair != "UNKNOWN-PAIR" {
		t.Fatalf("expected pair UNKNOWN-PAIR, got %s", snap.Pair)
	}
	if len(snap.Bids) != 0 || len(snap.Asks) != 0 {
		t.Fatalf("expected empty snapshot, got %d bids, %d asks", len(snap.Bids), len(snap.Asks))
	}
}

func TestSnapshot_Depth(t *testing.T) {
	engine := NewEngine()

	// Create 5 distinct bid price levels.
	for i := 0; i < 5; i++ {
		engine.PlaceOrder("BTC-USD", Buy, float64(100-i), 1.0)
	}

	snap := engine.Snapshot("BTC-USD", 3)
	if len(snap.Bids) != 3 {
		t.Fatalf("expected 3 bid levels (depth limit), got %d", len(snap.Bids))
	}
}

func TestRecentTrades_Limit(t *testing.T) {
	engine := NewEngine()

	// Generate 10 trades.
	for i := 0; i < 10; i++ {
		engine.PlaceOrder("BTC-USD", Sell, 100.0, 1.0)
		engine.PlaceOrder("BTC-USD", Buy, 100.0, 1.0)
	}

	trades := engine.RecentTrades("BTC-USD", 5)
	if len(trades) != 5 {
		t.Fatalf("expected 5 trades (limit), got %d", len(trades))
	}

	allTrades := engine.RecentTrades("BTC-USD", 100)
	if len(allTrades) != 10 {
		t.Fatalf("expected 10 total trades, got %d", len(allTrades))
	}
}

func TestRestoreOpenOrder(t *testing.T) {
	engine := NewEngine()

	// Restore a buy order, then match it with a sell.
	order := &Order{
		ID:        "restored-1",
		Pair:      "BTC-USD",
		Side:      Buy,
		Price:     50000.0,
		Quantity:  1.0,
		Remaining: 1.0,
		Status:    StatusOpen,
	}
	if err := engine.RestoreOpenOrder(order); err != nil {
		t.Fatalf("restore failed: %v", err)
	}

	_, trades, _ := engine.PlaceOrder("BTC-USD", Sell, 50000.0, 1.0)
	if len(trades) != 1 {
		t.Fatalf("expected restored order to match, got %d trades", len(trades))
	}
	if trades[0].MakerID != "restored-1" {
		t.Fatalf("expected maker to be restored order, got %s", trades[0].MakerID)
	}
}

func TestRestoreOpenOrder_InvalidCases(t *testing.T) {
	engine := NewEngine()

	// Nil order.
	if err := engine.RestoreOpenOrder(nil); err == nil {
		t.Fatal("expected error for nil order")
	}

	// Filled order (nothing to restore).
	filled := &Order{ID: "f1", Pair: "BTC-USD", Side: Buy, Price: 100, Remaining: 0, Status: StatusFilled}
	if err := engine.RestoreOpenOrder(filled); err == nil {
		t.Fatal("expected error for zero remaining")
	}

	// Cancelled order.
	cancelled := &Order{ID: "c1", Pair: "BTC-USD", Side: Sell, Price: 100, Remaining: 1.0, Status: StatusCancelled}
	if err := engine.RestoreOpenOrder(cancelled); err == nil {
		t.Fatal("expected error for cancelled status")
	}
}

func TestConcurrentOrders(t *testing.T) {
	engine := NewEngine()
	var wg sync.WaitGroup

	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, _, _ = engine.PlaceOrder("BTC-USD", Buy, 50000.0, 0.01)
		}()
		go func() {
			defer wg.Done()
			_, _, _ = engine.PlaceOrder("BTC-USD", Sell, 50000.0, 0.01)
		}()
	}
	wg.Wait()

	trades := engine.RecentTrades("BTC-USD", 200)
	if len(trades) == 0 {
		t.Fatal("expected some trades from concurrent matching")
	}
}

func BenchmarkPlaceOrder_NoMatch(b *testing.B) {
	engine := NewEngine()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		engine.PlaceOrder("BTC-USD", Buy, 49000.0, 0.01)
	}
}

func BenchmarkPlaceOrder_ImmediateFill(b *testing.B) {
	engine := NewEngine()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		engine.PlaceOrder("BTC-USD", Sell, 100.0, 1.0)
		engine.PlaceOrder("BTC-USD", Buy, 100.0, 1.0)
	}
}

func BenchmarkSnapshot(b *testing.B) {
	engine := NewEngine()
	// Build a book with 500 price levels.
	for i := 0; i < 500; i++ {
		engine.PlaceOrder("BTC-USD", Buy, float64(50000-i), 1.0)
		engine.PlaceOrder("BTC-USD", Sell, float64(50001+i), 1.0)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		engine.Snapshot("BTC-USD", 20)
	}
}
