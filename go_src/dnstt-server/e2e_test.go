package main

// End-to-end tests of the client package and the mobile library against this
// server, over UDP, DoH and DoT. They live here because the server is
// package main.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	"www.bamsoftware.com/git/dnstt.git/client"
	"www.bamsoftware.com/git/dnstt.git/dns"
	"www.bamsoftware.com/git/dnstt.git/internal/testresolver"
	"www.bamsoftware.com/git/dnstt.git/mobile"
	"www.bamsoftware.com/git/dnstt.git/noise"
)

const testDomain = "t.example.com"

// tcpEcho starts a TCP server that echoes what it receives and returns its
// address.
func tcpEcho(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				io.Copy(conn, conn)
			}()
		}
	}()
	return ln.Addr().String()
}

// startServer runs the DNSTT server on loopback UDP with upstream as the
// stream destination, and returns its address and public key.
func startServer(t *testing.T, upstream string) (string, []byte) {
	t.Helper()
	privkey, err := noise.GeneratePrivkey()
	if err != nil {
		t.Fatal(err)
	}
	domain, err := dns.ParseName(testDomain)
	if err != nil {
		t.Fatal(err)
	}
	dnsConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		run(privkey, domain, upstream, dnsConn)
	}()
	t.Cleanup(func() {
		dnsConn.Close()
		<-done
	})
	return dnsConn.LocalAddr().String(), noise.PubkeyFromPrivkey(privkey)
}

// checkEcho writes random data to conn and checks that it comes back.
func checkEcho(t *testing.T, conn io.ReadWriter, size int) {
	t.Helper()
	data := make([]byte, size)
	rand.Read(data)
	go conn.Write(data)
	got := make([]byte, size)
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("echoed data differs")
	}
}

type fronts struct {
	server           string
	dohPort, dotPort int
	opts             client.Options
}

func startFronts(t *testing.T, server string) fronts {
	cert, pool := testresolver.Cert(t)
	forward := testresolver.UDPForwarder(server, 5*time.Second)
	return fronts{
		server:  server,
		dohPort: testresolver.DoH(t, cert, forward),
		dotPort: testresolver.DoT(t, cert, 0, forward),
		opts:    client.Options{RootCAs: pool},
	}
}

func (f fronts) cases() []struct{ spec, bootstrap, fingerprint string } {
	return []struct{ spec, bootstrap, fingerprint string }{
		{f.server, "", ""},
		{fmt.Sprintf("https://127.0.0.1:%d/dns-query", f.dohPort), "", "none"},
		{fmt.Sprintf("https://127.0.0.1:%d/dns-query", f.dohPort), "", "Chrome"},
		{fmt.Sprintf("https://%s:%d/dns-query", testresolver.Name, f.dohPort), "127.0.0.1", ""},
		{fmt.Sprintf("tls://127.0.0.1:%d", f.dotPort), "", "none"},
		{fmt.Sprintf("tls://%s:%d", testresolver.Name, f.dotPort), "127.0.0.1", "Firefox"},
	}
}

func TestEndToEnd(t *testing.T) {
	server, pubkey := startServer(t, tcpEcho(t))
	f := startFronts(t, server)
	domain, _ := dns.ParseName(testDomain)

	for _, test := range f.cases() {
		t.Run(fmt.Sprintf("%s bootstrap=%q fingerprint=%q", test.spec, test.bootstrap, test.fingerprint), func(t *testing.T) {
			r, err := client.ParseResolver(test.spec)
			if err != nil {
				t.Fatal(err)
			}
			opts := f.opts
			opts.Bootstrap = test.bootstrap
			opts.TLSFingerprint = test.fingerprint
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			pconn, addr, err := client.Open(ctx, r, opts)
			if err != nil {
				t.Fatal(err)
			}
			tunnel, err := client.NewTunnel(ctx, pconn, addr, domain, pubkey)
			if err != nil {
				t.Fatal(err)
			}
			defer tunnel.Close()

			// Two streams at once.
			errs := make(chan error, 2)
			for i := 0; i < 2; i++ {
				go func() {
					stream, err := tunnel.OpenStream()
					if err != nil {
						errs <- err
						return
					}
					defer stream.Close()
					data := make([]byte, 16*1024)
					rand.Read(data)
					go stream.Write(data)
					got := make([]byte, len(data))
					stream.SetReadDeadline(time.Now().Add(30 * time.Second))
					if _, err := io.ReadFull(stream, got); err != nil {
						errs <- err
						return
					}
					if !bytes.Equal(got, data) {
						errs <- errors.New("echoed data differs")
						return
					}
					errs <- nil
				}()
			}
			for i := 0; i < 2; i++ {
				if err := <-errs; err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestNewTunnelWrongKey(t *testing.T) {
	server, _ := startServer(t, tcpEcho(t))
	r, _ := client.ParseResolver(server)
	domain, _ := dns.ParseName(testDomain)
	wrongKey := make([]byte, noise.KeyLen)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	pconn, addr, err := client.Open(ctx, r, client.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if tunnel, err := client.NewTunnel(ctx, pconn, addr, domain, wrongKey); err == nil {
		tunnel.Close()
		t.Fatal("tunnel with a wrong server key")
	}
}

func TestProbe(t *testing.T) {
	server, _ := startServer(t, tcpEcho(t))
	f := startFronts(t, server)
	domain, _ := dns.ParseName(testDomain)
	other, _ := dns.ParseName("other.example")

	for _, test := range f.cases() {
		r, _ := client.ParseResolver(test.spec)
		opts := f.opts
		opts.Bootstrap = test.bootstrap
		opts.TLSFingerprint = test.fingerprint
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		latency, err := client.Probe(ctx, r, opts, domain)
		if err != nil || latency <= 0 {
			t.Errorf("%s: %v, %v", test.spec, latency, err)
		}
		// The server is not authoritative for other names.
		_, err = client.Probe(ctx, r, opts, other)
		var rcodeErr *client.RcodeError
		if !errors.As(err, &rcodeErr) || rcodeErr.Rcode != dns.RcodeNameError {
			t.Errorf("%s: other domain: %v", test.spec, err)
		}
		cancel()
	}

	// No answer at all: a timeout.
	silent, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	r, _ := client.ParseResolver(silent.LocalAddr().String())
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, err := client.Probe(ctx, r, client.Options{}, domain); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("silent resolver: %v", err)
	}
}

// freePort returns a TCP port on 127.0.0.1 that was free a moment ago.
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func TestMobileClient(t *testing.T) {
	server, pubkey := startServer(t, tcpEcho(t))
	listenAddr := fmt.Sprintf("127.0.0.1:%d", freePort(t))

	if _, err := mobile.NewClient("https://", testDomain, hex.EncodeToString(pubkey), listenAddr); err == nil {
		t.Errorf("invalid resolver accepted")
	}

	c, err := mobile.NewClient(server, testDomain, hex.EncodeToString(pubkey), listenAddr)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	if !c.IsRunning() {
		t.Fatal("not running after Start")
	}
	conn, err := net.Dial("tcp", listenAddr)
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	checkEcho(t, conn, 8*1024)
	conn.Close()

	c.Stop()
	if c.IsRunning() {
		t.Fatal("running after Stop")
	}
	if conn, err := net.Dial("tcp", listenAddr); err == nil {
		conn.Close()
		t.Fatal("listener still open after Stop")
	}

	// Started again after Stop.
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	c.Stop()

	if latency, err := mobile.ProbeResolver(server, "", "", testDomain, 5000); err != nil || latency < 0 {
		t.Errorf("ProbeResolver: %v, %v", latency, err)
	}
}

func TestMobileHelpers(t *testing.T) {
	for _, test := range []struct{ spec, kind, udpAddr string }{
		{"192.0.2.1", "udp", "192.0.2.1:53"},
		{"[2001:db8::1]:5353", "udp", "[2001:db8::1]:5353"},
		{"https://dns.example/dns-query", "doh", ""},
		{"tls://dns.example", "dot", ""},
		{"bogus://x", "", ""},
	} {
		if kind := mobile.ResolverKind(test.spec); kind != test.kind {
			t.Errorf("ResolverKind(%q) = %q, want %q", test.spec, kind, test.kind)
		}
		if addr := mobile.UdpResolverAddr(test.spec); addr != test.udpAddr {
			t.Errorf("UdpResolverAddr(%q) = %q, want %q", test.spec, addr, test.udpAddr)
		}
	}
}

func TestMobileBridge(t *testing.T) {
	server, _ := startServer(t, tcpEcho(t))
	b, err := mobile.StartBridge(server, "", "")
	if err != nil {
		t.Fatal(err)
	}
	defer b.Stop()
	// A probe through the bridge reaches the server.
	if _, err := mobile.ProbeResolver(fmt.Sprintf("127.0.0.1:%d", b.Port()), "", "", testDomain, 5000); err != nil {
		t.Fatal(err)
	}
}
