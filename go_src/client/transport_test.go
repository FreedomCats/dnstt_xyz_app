package client

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"runtime"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"www.bamsoftware.com/git/dnstt.git/internal/testresolver"
)

// echo answers a message with "a:" and the message.
func echo(query []byte) []byte {
	return append([]byte("a:"), query...)
}

// udpEcho starts a UDP server that answers like echo and returns its port.
func udpEcho(t *testing.T) int {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	go func() {
		buf := make([]byte, 65536)
		for {
			n, addr, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			conn.WriteTo(echo(buf[:n]), addr)
		}
	}()
	return conn.LocalAddr().(*net.UDPAddr).Port
}

// exchange writes n messages through pconn and checks that the n answers come
// back, in any order.
func exchange(t *testing.T, pconn net.PacketConn, addr net.Addr, n int) {
	t.Helper()
	var want []string
	for i := 0; i < n; i++ {
		msg := []byte(fmt.Sprintf("message %d", i))
		want = append(want, string(echo(msg)))
		if _, err := pconn.WriteTo(msg, addr); err != nil {
			t.Fatal(err)
		}
	}
	got := readN(t, pconn, n, 10*time.Second)
	sort.Strings(want)
	sort.Strings(got)
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// readN reads n messages from pconn, failing after timeout.
func readN(t *testing.T, pconn net.PacketConn, n int, timeout time.Duration) []string {
	t.Helper()
	ch := make(chan string, n)
	go func() {
		buf := make([]byte, 65536)
		for i := 0; i < n; i++ {
			m, _, err := pconn.ReadFrom(buf)
			if err != nil {
				return
			}
			ch <- string(buf[:m])
		}
	}()
	var got []string
	deadline := time.After(timeout)
	for len(got) < n {
		select {
		case m := <-ch:
			got = append(got, m)
		case <-deadline:
			t.Fatalf("got %d of %d answers: %q", len(got), n, got)
		}
	}
	return got
}

func TestTransports(t *testing.T) {
	cert, pool := testresolver.Cert(t)
	dohPort := testresolver.DoH(t, cert, echo)
	dotPort := testresolver.DoT(t, cert, 0, echo)
	udpPort := udpEcho(t)

	for _, test := range []struct {
		spec, bootstrap, fingerprint string
	}{
		{fmt.Sprintf("127.0.0.1:%d", udpPort), "", ""},
		{fmt.Sprintf("udp://%s:%d", testresolver.Name, udpPort), "127.0.0.1", ""},
		{fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort), "", "none"},
		{fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort), "", "Chrome"},
		{fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort), "", "Firefox"},
		{fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort), "", ""},
		{fmt.Sprintf("https://%s:%d/dns-query", testresolver.Name, dohPort), "127.0.0.1", "none"},
		{fmt.Sprintf("https://%s:%d", testresolver.Name, dohPort), "127.0.0.1", "Safari"},
		{fmt.Sprintf("tls://127.0.0.1:%d", dotPort), "", "none"},
		{fmt.Sprintf("tls://127.0.0.1:%d", dotPort), "", "Chrome"},
		{fmt.Sprintf("tls://%s:%d", testresolver.Name, dotPort), "127.0.0.1", "none"},
		{fmt.Sprintf("tls://%s:%d", testresolver.Name, dotPort), "127.0.0.1", "iOS"},
	} {
		name := fmt.Sprintf("%s bootstrap=%q fingerprint=%q", test.spec, test.bootstrap, test.fingerprint)
		t.Run(name, func(t *testing.T) {
			r, err := ParseResolver(test.spec)
			if err != nil {
				t.Fatal(err)
			}
			var protected atomic.Int32
			opts := Options{
				Bootstrap:      test.bootstrap,
				TLSFingerprint: test.fingerprint,
				RootCAs:        pool,
				Protect: func(fd int) bool {
					protected.Add(1)
					return fd >= 0
				},
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			pconn, addr, err := Open(ctx, r, opts)
			if err != nil {
				t.Fatal(err)
			}
			defer pconn.Close()
			exchange(t, pconn, addr, 20)
			if protected.Load() == 0 {
				t.Errorf("protect hook not called")
			}
		})
	}
}

func TestOpenErrors(t *testing.T) {
	cert, _ := testresolver.Cert(t)
	dotPort := testresolver.DoT(t, cert, 0, echo)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// The test certificate is not trusted without RootCAs.
	r, _ := ParseResolver(fmt.Sprintf("tls://127.0.0.1:%d", dotPort))
	if _, _, err := Open(ctx, r, Options{TLSFingerprint: "none"}); err == nil {
		t.Errorf("untrusted certificate accepted")
	}
	if _, _, err := Open(ctx, r, Options{Bootstrap: "dns.example"}); err == nil {
		t.Errorf("invalid bootstrap accepted")
	}
	if _, _, err := Open(ctx, r, Options{TLSFingerprint: "Netscape"}); err == nil {
		t.Errorf("unknown fingerprint accepted")
	}
	_, pool := testresolver.Cert(t)
	r.Port = 1 // nothing listens there
	if _, _, err := Open(ctx, r, Options{RootCAs: pool}); err == nil {
		t.Errorf("dial to a closed port succeeded")
	}
	// A refused protect fails the connection.
	r.Port = dotPort
	if _, _, err := Open(ctx, r, Options{Protect: func(int) bool { return false }}); err == nil {
		t.Errorf("connection made although protect failed")
	}
}

// shortenTLSTimers makes DoT redial and liveness checks fast for a test.
func shortenTLSTimers(t *testing.T) {
	saved := []time.Duration{redialMinDelay, redialMaxDelay, responseTimeout}
	redialMinDelay, redialMaxDelay, responseTimeout = 50*time.Millisecond, 200*time.Millisecond, 500*time.Millisecond
	t.Cleanup(func() {
		redialMinDelay, redialMaxDelay, responseTimeout = saved[0], saved[1], saved[2]
	})
}

func TestTLSRedial(t *testing.T) {
	shortenTLSTimers(t)
	cert, pool := testresolver.Cert(t)
	// The server drops each connection after two messages.
	var conns atomic.Int32
	dotPort := testresolver.DoT(t, cert, 2, func(q []byte) []byte {
		return echo(q)
	})
	r, _ := ParseResolver(fmt.Sprintf("tls://127.0.0.1:%d", dotPort))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pconn, addr, err := Open(ctx, r, Options{RootCAs: pool, Protect: func(int) bool { conns.Add(1); return true }})
	if err != nil {
		t.Fatal(err)
	}
	defer pconn.Close()
	answers := reader(pconn)
	for i := 0; i < 6; i++ {
		msg := []byte(fmt.Sprintf("message %d", i))
		// Messages written while the connection is down may be lost
		// (DNSTT retransmits); repeat until the answer comes.
		for attempt := 0; ; attempt++ {
			if attempt == 50 {
				t.Fatalf("no answer to %q", msg)
			}
			pconn.WriteTo(msg, addr)
			got := readWithin(answers, 200*time.Millisecond)
			if got == string(echo(msg)) {
				break
			}
		}
	}
	if conns.Load() < 3 {
		t.Errorf("%d connections, want at least 3", conns.Load())
	}
}

// reader reads all messages from pconn into a channel, so that a test can wait
// for a message with a timeout without leaving a read behind.
func reader(pconn net.PacketConn) <-chan string {
	ch := make(chan string, 64)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, _, err := pconn.ReadFrom(buf)
			if err != nil {
				return
			}
			ch <- string(buf[:n])
		}
	}()
	return ch
}

// readWithin returns the next message from ch, or "" after timeout.
func readWithin(ch <-chan string, timeout time.Duration) string {
	select {
	case m := <-ch:
		return m
	case <-time.After(timeout):
		return ""
	}
}

func TestTLSLiveness(t *testing.T) {
	shortenTLSTimers(t)
	cert, pool := testresolver.Cert(t)
	// The server stops answering after the first message on each
	// connection, like a connection that died with a network change.
	var answered atomic.Int32
	dotPort := testresolver.DoT(t, cert, 0, func(q []byte) []byte {
		if bytes.HasPrefix(q, []byte("first")) {
			answered.Add(1)
			return echo(q)
		}
		return nil
	})
	r, _ := ParseResolver(fmt.Sprintf("tls://127.0.0.1:%d", dotPort))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var conns atomic.Int32
	pconn, addr, err := Open(ctx, r, Options{RootCAs: pool, Protect: func(int) bool { conns.Add(1); return true }})
	if err != nil {
		t.Fatal(err)
	}
	defer pconn.Close()
	answers := reader(pconn)
	pconn.WriteTo([]byte("lost"), addr)
	// After responseTimeout without an answer the conn redials.
	deadline := time.Now().Add(5 * time.Second)
	for conns.Load() < 2 {
		if time.Now().After(deadline) {
			t.Fatal("no redial after the server stopped answering")
		}
		time.Sleep(20 * time.Millisecond)
	}
	for attempt := 0; ; attempt++ {
		if attempt == 50 {
			t.Fatal("no answer on the new connection")
		}
		pconn.WriteTo([]byte("first"), addr)
		if readWithin(answers, 200*time.Millisecond) == "a:first" {
			break
		}
	}
}

func TestCloseStopsGoroutines(t *testing.T) {
	cert, pool := testresolver.Cert(t)
	dohPort := testresolver.DoH(t, cert, echo)
	dotPort := testresolver.DoT(t, cert, 0, echo)
	udpPort := udpEcho(t)
	specs := []string{
		fmt.Sprintf("127.0.0.1:%d", udpPort),
		fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort),
		fmt.Sprintf("tls://127.0.0.1:%d", dotPort),
	}
	// Let the servers settle before counting.
	time.Sleep(100 * time.Millisecond)
	before := runtime.NumGoroutine()

	for _, fingerprint := range []string{"none", "Chrome"} {
		for _, spec := range specs {
			r, _ := ParseResolver(spec)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			pconn, addr, err := Open(ctx, r, Options{RootCAs: pool, TLSFingerprint: fingerprint})
			cancel()
			if err != nil {
				t.Fatal(err)
			}
			exchange(t, pconn, addr, 5)
			// The DNSTT encoder on top, as in a tunnel.
			dnsConn := NewDNSPacketConn(pconn, addr, mustParseName(t, "t.example.com"))
			time.Sleep(50 * time.Millisecond)
			dnsConn.Close()
		}
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		n := runtime.NumGoroutine()
		if n <= before {
			break
		}
		if time.Now().After(deadline) {
			buf := make([]byte, 1<<20)
			t.Fatalf("%d goroutines before, %d after close:\n%s", before, n, buf[:runtime.Stack(buf, true)])
		}
		time.Sleep(50 * time.Millisecond)
	}
}
