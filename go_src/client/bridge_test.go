package client

import (
	"context"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"

	"www.bamsoftware.com/git/dnstt.git/dns"
	"www.bamsoftware.com/git/dnstt.git/internal/testresolver"
)

func dnsQuery(t *testing.T, id uint16, name string) []byte {
	t.Helper()
	msg := &dns.Message{
		ID:       id,
		Flags:    0x0100,
		Question: []dns.Question{{Name: mustParseName(t, name), Type: dns.RRTypeTXT, Class: dns.ClassIN}},
	}
	buf, err := msg.WireFormat()
	if err != nil {
		t.Fatal(err)
	}
	return buf
}

// dnsAnswer answers a query with an empty NOERROR response, or nil if p is
// not a query.
func dnsAnswer(p []byte) []byte {
	msg, err := dns.MessageFromWireFormat(p)
	if err != nil || msg.Flags&0x8000 != 0 {
		return nil
	}
	resp := &dns.Message{ID: msg.ID, Flags: 0x8180, Question: msg.Question}
	buf, err := resp.WireFormat()
	if err != nil {
		return nil
	}
	return buf
}

// reorderingResolver starts a UDP DNS server that holds queries until it has
// batch of them and answers them in reverse order. It returns its port.
func reorderingResolver(t *testing.T, batch int) int {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	go func() {
		type held struct {
			p    []byte
			addr net.Addr
		}
		var queue []held
		buf := make([]byte, 65536)
		for {
			n, addr, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			queue = append(queue, held{append([]byte(nil), buf[:n]...), addr})
			if len(queue) < batch {
				continue
			}
			for i := len(queue) - 1; i >= 0; i-- {
				if answer := dnsAnswer(queue[i].p); answer != nil {
					conn.WriteTo(answer, queue[i].addr)
				}
			}
			queue = nil
		}
	}()
	return conn.LocalAddr().(*net.UDPAddr).Port
}

func TestBridge(t *testing.T) {
	cert, pool := testresolver.Cert(t)
	dohPort := testresolver.DoH(t, cert, dnsAnswer)
	const clients, perClient = 2, 4
	for _, spec := range []string{
		fmt.Sprintf("127.0.0.1:%d", reorderingResolver(t, clients*perClient)),
		fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort),
	} {
		t.Run(spec, func(t *testing.T) {
			r, _ := ParseResolver(spec)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			b, err := NewBridge(ctx, r, Options{RootCAs: pool})
			if err != nil {
				t.Fatal(err)
			}
			defer b.Close()
			if !b.Addr().IP.IsLoopback() {
				t.Errorf("bridge listens on %v", b.Addr())
			}

			var wg sync.WaitGroup
			for c := 0; c < clients; c++ {
				conn, err := net.DialUDP("udp", nil, b.Addr())
				if err != nil {
					t.Fatal(err)
				}
				defer conn.Close()
				// Both clients use the same IDs: the names tell the
				// queries apart.
				want := map[string]bool{}
				for i := 0; i < perClient; i++ {
					name := fmt.Sprintf("q%d.c%d.T.example.com", i, c)
					want[fmt.Sprintf("%d %s", 100+i, name)] = true
					if _, err := conn.Write(dnsQuery(t, uint16(100+i), name)); err != nil {
						t.Fatal(err)
					}
				}
				wg.Add(1)
				go func() {
					defer wg.Done()
					conn.SetReadDeadline(time.Now().Add(5 * time.Second))
					buf := make([]byte, 65536)
					for len(want) > 0 {
						n, err := conn.Read(buf)
						if err != nil {
							t.Errorf("client %d: %v, missing %v", c, err, want)
							return
						}
						msg, err := dns.MessageFromWireFormat(buf[:n])
						if err != nil {
							t.Errorf("client %d: %v", c, err)
							return
						}
						key := fmt.Sprintf("%d %s", msg.ID, msg.Question[0].Name)
						if !want[key] {
							t.Errorf("client %d: unexpected answer %s", c, key)
							return
						}
						delete(want, key)
					}
				}()
			}
			wg.Wait()
		})
	}
}

func TestBridgeIgnoresStrangers(t *testing.T) {
	port := reorderingResolver(t, 1)
	r, _ := ParseResolver(fmt.Sprintf("127.0.0.1:%d", port))
	b, err := NewBridge(context.Background(), r, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	conn, err := net.DialUDP("udp", nil, b.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Garbage and answers are dropped; a query still works after them.
	conn.Write([]byte("not dns"))
	conn.Write(dnsAnswer(dnsQuery(t, 1, "x.example.com")))
	conn.Write(dnsQuery(t, 7, "y.example.com"))
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 65536)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	msg, err := dns.MessageFromWireFormat(buf[:n])
	if err != nil || msg.ID != 7 {
		t.Fatalf("got %+v, %v", msg, err)
	}
}

// TestBridgeRestoresID checks answers from a resolver that changes DNS IDs.
func TestBridgeRestoresID(t *testing.T) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	go func() {
		buf := make([]byte, 65536)
		for {
			n, addr, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			if answer := dnsAnswer(buf[:n]); answer != nil {
				answer[0], answer[1] = 0, 0
				conn.WriteTo(answer, addr)
			}
		}
	}()
	r, _ := ParseResolver(conn.LocalAddr().String())
	b, err := NewBridge(context.Background(), r, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	client, err := net.DialUDP("udp", nil, b.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	client.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 65536)
	for i, name := range []string{"a.example.com", "b.example.com", "a.example.com"} {
		id := uint16(500 + i)
		if _, err := client.Write(dnsQuery(t, id, name)); err != nil {
			t.Fatal(err)
		}
		n, err := client.Read(buf)
		if err != nil {
			t.Fatal(err)
		}
		msg, err := dns.MessageFromWireFormat(buf[:n])
		if err != nil {
			t.Fatal(err)
		}
		if msg.ID != id || msg.Question[0].Name.String() != name {
			t.Errorf("query %d %s: got answer %d %s", id, name, msg.ID, msg.Question[0].Name)
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.pending) != 0 || len(b.latestID) != 0 {
		t.Errorf("left %d pending queries, %d IDs", len(b.pending), len(b.latestID))
	}
}
