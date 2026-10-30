package client

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"www.bamsoftware.com/git/dnstt.git/internal/testresolver"
)

// TestSlipstreamOverBridge runs slipstream-client through a Bridge to local
// DoH and DoT servers that forward to slipstream-server, and directly over
// UDP for comparison, and downloads a payload through each. It needs both
// binaries, built from vendor/slipstream-rust:
//
//	SLIPSTREAM_CLIENT=<path> SLIPSTREAM_SERVER=<path> go test ./client -run Slipstream -v
//
// slipstream-client binds its UDP socket to [::], so the host needs IPv6
// sockets.
func TestSlipstreamOverBridge(t *testing.T) {
	clientBin, serverBin := os.Getenv("SLIPSTREAM_CLIENT"), os.Getenv("SLIPSTREAM_SERVER")
	if clientBin == "" || serverBin == "" {
		t.Skip("SLIPSTREAM_CLIENT and SLIPSTREAM_SERVER are not set")
	}
	const domain = "t.example.com"

	payload := make([]byte, 4<<20)
	rand.Read(payload)
	target := startTarget(t, payload)

	dnsPort := freePort(t, "udp")
	dir := t.TempDir()
	startProcess(t, serverBin,
		"--dns-listen-host", "127.0.0.1",
		"--dns-listen-port", fmt.Sprint(dnsPort),
		"--target-address", target,
		"--domain", domain,
		"--cert", filepath.Join(dir, "cert.pem"),
		"--key", filepath.Join(dir, "key.pem"),
		"--reset-seed", filepath.Join(dir, "reset-seed"))
	serverAddr := fmt.Sprintf("127.0.0.1:%d", dnsPort)

	cert, pool := testresolver.Cert(t)
	forward := testresolver.UDPForwarder(serverAddr, 5*time.Second)
	dohPort := testresolver.DoH(t, cert, forward)
	dotPort := testresolver.DoT(t, cert, 0, forward)

	for _, spec := range []string{
		serverAddr,
		fmt.Sprintf("https://127.0.0.1:%d/dns-query", dohPort),
		fmt.Sprintf("tls://127.0.0.1:%d", dotPort),
	} {
		t.Run(spec, func(t *testing.T) {
			r, err := ParseResolver(spec)
			if err != nil {
				t.Fatal(err)
			}
			resolver := serverAddr
			if r.Kind != KindUDP {
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				b, err := NewBridge(ctx, r, Options{RootCAs: pool})
				if err != nil {
					t.Fatal(err)
				}
				defer b.Close()
				resolver = b.Addr().String()
			}

			listenPort := freePort(t, "tcp")
			stop := startProcess(t, clientBin,
				"--tcp-listen-host", "127.0.0.1",
				"--tcp-listen-port", fmt.Sprint(listenPort),
				"--resolver", resolver,
				"--domain", domain)
			defer stop()

			start := time.Now()
			var conn net.Conn
			for {
				conn, err = net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", listenPort))
				if err == nil {
					break
				}
				if time.Since(start) > 10*time.Second {
					t.Fatalf("slipstream-client does not listen: %v", err)
				}
				time.Sleep(100 * time.Millisecond)
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(60 * time.Second))
			start = time.Now()
			if _, err := conn.Write([]byte{1}); err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(conn)
			elapsed := time.Since(start)
			if err != nil {
				t.Fatalf("after %d bytes: %v", len(got), err)
			}
			if !bytes.Equal(got, payload) {
				t.Fatalf("got %d bytes, want the %d byte payload", len(got), len(payload))
			}
			t.Logf("%d bytes in %v (%.1f Mbit/s)", len(got), elapsed.Round(time.Millisecond),
				float64(len(got))*8/elapsed.Seconds()/1e6)
		})
	}
}

// startTarget starts a TCP server that sends payload after it has read one
// byte; slipstream-client opens the stream when the client sends, so the
// client speaks first, as with SOCKS5. It returns the server's address.
func startTarget(t *testing.T, payload []byte) string {
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
				if _, err := io.ReadFull(conn, make([]byte, 1)); err == nil {
					conn.Write(payload)
				}
			}()
		}
	}()
	return ln.Addr().String()
}

// freePort returns a port that was free on 127.0.0.1 a moment ago.
func freePort(t *testing.T, network string) int {
	t.Helper()
	if network == "udp" {
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		return conn.LocalAddr().(*net.UDPAddr).Port
	}
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

// startProcess starts a program that runs until the returned function or the
// end of the test stops it; its output is logged if the test fails.
func startProcess(t *testing.T, name string, args ...string) func() {
	t.Helper()
	cmd := exec.Command(name, args...)
	var out lockedBuffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cmd.Process.Kill()
			cmd.Wait()
			if t.Failed() {
				t.Logf("%s output:\n%s", filepath.Base(name), out.String())
			}
		})
	}
	t.Cleanup(stop)
	return stop
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}
