package tests

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	h, mr, rdb := testRouter(t)
	t.Cleanup(func() { _ = rdb.Close(); mr.Close() })

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != "ok" {
		t.Fatalf("expected status ok, got %v", body["status"])
	}
}

func TestReadyz(t *testing.T) {
	h, mr, rdb := testRouter(t)
	t.Cleanup(func() { _ = rdb.Close(); mr.Close() })

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body.String())
	}
}

func TestPlaceOrderValidation(t *testing.T) {
	h, mr, rdb := testRouter(t)
	t.Cleanup(func() { _ = rdb.Close(); mr.Close() })

	req := httptest.NewRequest(http.MethodPost, "/api/v1/orders", bytes.NewBufferString(`{"pair":"","side":"buy","price":1,"quantity":1}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d %s", rec.Code, rec.Body.String())
	}
}

func TestPlaceOrderAndOrderbook(t *testing.T) {
	h, mr, rdb := testRouter(t)
	t.Cleanup(func() { _ = rdb.Close(); mr.Close() })

	pair := "TEST-USD"

	sell := httptest.NewRequest(http.MethodPost, "/api/v1/orders", 	bytes.NewBufferString(
		`{"pair":"`+pair+`","side":"sell","price":100,"quantity":2}`,
	))
	sell.Header.Set("Content-Type", "application/json")
	recSell := httptest.NewRecorder()
	h.ServeHTTP(recSell, sell)
	if recSell.Code != http.StatusCreated {
		t.Fatalf("sell: %d %s", recSell.Code, recSell.Body.String())
	}

	buy := httptest.NewRequest(http.MethodPost, "/api/v1/orders", 	bytes.NewBufferString(
		`{"pair":"`+pair+`","side":"buy","price":100,"quantity":0.5}`,
	))
	buy.Header.Set("Content-Type", "application/json")
	recBuy := httptest.NewRecorder()
	h.ServeHTTP(recBuy, buy)
	if recBuy.Code != http.StatusCreated {
		t.Fatalf("buy: %d %s", recBuy.Code, recBuy.Body.String())
	}

	ob := httptest.NewRequest(http.MethodGet, "/api/v1/orderbook/"+pair+"?depth=5", nil)
	recOB := httptest.NewRecorder()
	h.ServeHTTP(recOB, ob)
	if recOB.Code != http.StatusOK {
		t.Fatalf("orderbook: %d %s", recOB.Code, recOB.Body.String())
	}
	var wrap struct {
		Success bool                   `json:"success"`
		Data    map[string]interface{} `json:"data"`
	}
	if err := json.Unmarshal(recOB.Body.Bytes(), &wrap); err != nil {
		t.Fatal(err)
	}
	if !wrap.Success {
		t.Fatalf("orderbook success false: %s", recOB.Body.String())
	}
}

func TestCancelOrder(t *testing.T) {
	h, mr, rdb := testRouter(t)
	t.Cleanup(func() { _ = rdb.Close(); mr.Close() })

	pair := "CAN-USD"
	place := httptest.NewRequest(http.MethodPost, "/api/v1/orders", 	bytes.NewBufferString(
		`{"pair":"`+pair+`","side":"buy","price":10,"quantity":1}`,
	))
	place.Header.Set("Content-Type", "application/json")
	recP := httptest.NewRecorder()
	h.ServeHTTP(recP, place)
	if recP.Code != http.StatusCreated {
		t.Fatalf("place: %d %s", recP.Code, recP.Body.String())
	}
	var wrap struct {
		Data struct {
			Order struct {
				ID string `json:"id"`
			} `json:"order"`
		} `json:"data"`
	}
	if err := json.Unmarshal(recP.Body.Bytes(), &wrap); err != nil {
		t.Fatal(err)
	}
	id := wrap.Data.Order.ID
	if id == "" {
		t.Fatal("missing order id")
	}

	del := httptest.NewRequest(http.MethodDelete, "/api/v1/orders/"+id+"?pair="+pair, nil)
	recD := httptest.NewRecorder()
	h.ServeHTTP(recD, del)
	if recD.Code != http.StatusOK {
		t.Fatalf("cancel: %d %s", recD.Code, recD.Body.String())
	}
}

func TestTradesEndpoint(t *testing.T) {
	h, mr, rdb := testRouter(t)
	t.Cleanup(func() { _ = rdb.Close(); mr.Close() })

	pair := "TRD-USD"
	sell := httptest.NewRequest(http.MethodPost, "/api/v1/orders", 	bytes.NewBufferString(
		`{"pair":"`+pair+`","side":"sell","price":50,"quantity":1}`,
	))
	sell.Header.Set("Content-Type", "application/json")
	h.ServeHTTP(httptest.NewRecorder(), sell)

	buy := httptest.NewRequest(http.MethodPost, "/api/v1/orders", 	bytes.NewBufferString(
		`{"pair":"`+pair+`","side":"buy","price":50,"quantity":1}`,
	))
	buy.Header.Set("Content-Type", "application/json")
	h.ServeHTTP(httptest.NewRecorder(), buy)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/trades/"+pair+"?limit=10", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("trades: %d %s", rec.Code, rec.Body.String())
	}
}
