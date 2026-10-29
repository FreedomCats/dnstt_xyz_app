// Package testresolver provides local DoH and DoT servers for tests, with a
// self-signed certificate for 127.0.0.1 and resolver.example.
package testresolver

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Name is the host name in the certificate.
const Name = "resolver.example"

// Cert returns a self-signed TLS certificate for 127.0.0.1 and Name, and a
// pool that trusts it.
func Cert(t testing.TB) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: Name},
		DNSNames:              []string{Name},
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1)},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, pool
}

// Handler answers one DNS message. A nil answer means no answer.
type Handler func(query []byte) []byte

// DoH starts an HTTPS server (HTTP/2 and HTTP/1.1) that answers RFC 8484
// POST requests on /dns-query with h. It returns the server's port.
func DoH(t testing.TB, cert tls.Certificate, h Handler) int {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/dns-query", func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost || req.Header.Get("Content-Type") != "application/dns-message" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		query, err := io.ReadAll(io.LimitReader(req.Body, 65536))
		if err != nil {
			return
		}
		answer := h(query)
		if answer == nil {
			http.Error(w, "no answer", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(answer)
	})
	srv := httptest.NewUnstartedServer(mux)
	srv.EnableHTTP2 = true
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv.Listener.Addr().(*net.TCPAddr).Port
}

// DoT starts a DNS over TLS server that answers with h. Each connection is
// served until the client closes it, or after maxMessages messages if
// maxMessages > 0 (to test redialing). It returns the listener's port.
func DoT(t testing.TB, cert tls.Certificate, maxMessages int, h Handler) int {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
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
			go serveDoT(conn, maxMessages, h)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func serveDoT(conn net.Conn, maxMessages int, h Handler) {
	defer conn.Close()
	br := bufio.NewReader(conn)
	answers := make(chan []byte, 64)
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			select {
			case <-done:
				return
			case p := <-answers:
				var length [2]byte
				binary.BigEndian.PutUint16(length[:], uint16(len(p)))
				if _, err := conn.Write(append(length[:], p...)); err != nil {
					return
				}
			}
		}
	}()
	for n := 0; maxMessages <= 0 || n < maxMessages; n++ {
		var length uint16
		if err := binary.Read(br, binary.BigEndian, &length); err != nil {
			return
		}
		query := make([]byte, length)
		if _, err := io.ReadFull(br, query); err != nil {
			return
		}
		// Answer concurrently: DoT answers may come in any order.
		go func() {
			if answer := h(query); answer != nil {
				select {
				case answers <- answer:
				case <-done:
				}
			}
		}()
	}
	// Give the last answers a moment before dropping the connection.
	time.Sleep(100 * time.Millisecond)
}

// UDPForwarder returns a handler that sends each query to the UDP DNS server
// at addr and returns its answer (matched by DNS ID), or nil after timeout.
func UDPForwarder(addr string, timeout time.Duration) Handler {
	return func(query []byte) []byte {
		if len(query) < 2 {
			return nil
		}
		conn, err := net.Dial("udp", addr)
		if err != nil {
			return nil
		}
		defer conn.Close()
		if _, err := conn.Write(query); err != nil {
			return nil
		}
		conn.SetReadDeadline(time.Now().Add(timeout))
		buf := make([]byte, 65536)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				return nil
			}
			if n >= 2 && buf[0] == query[0] && buf[1] == query[1] {
				return buf[:n]
			}
		}
	}
}
