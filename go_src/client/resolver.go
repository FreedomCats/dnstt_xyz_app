package client

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"

	utls "github.com/refraction-networking/utls"
	"www.bamsoftware.com/git/dnstt.git/turbotunnel"
)

// Kind is the transport of a resolver.
type Kind string

const (
	KindUDP Kind = "udp" // plain DNS over UDP
	KindDoH Kind = "doh" // DNS over HTTPS, RFC 8484
	KindDoT Kind = "dot" // DNS over TLS, RFC 7858
)

// DefaultTLSFingerprint is the TLS fingerprint distribution used when
// Options.TLSFingerprint is empty: common browsers only, since a rare or
// randomized ClientHello stands out by itself. The labels without a version
// follow the newest fingerprint of the uTLS release in use.
const DefaultTLSFingerprint = "4*Chrome,1*Firefox,1*Safari"

// numHTTPSenders is the number of concurrent DoH requests.
const numHTTPSenders = 32

// Resolver is a parsed resolver spec.
//
//	192.0.2.1, 192.0.2.1:5353          UDP (port 53 by default)
//	2001:db8::1, [2001:db8::1]:5353    UDP
//	dns.example, udp://host[:port]     UDP
//	https://host[:port][/path][?query] DoH (port 443, path /dns-query by default)
//	tls://host[:port]                  DoT (port 853)
type Resolver struct {
	Kind Kind
	// Host is an IP address or a lower-case host name, without brackets.
	Host string
	Port int
	// Path is the DoH request path with the query string, starting with "/".
	Path string
}

// Addr returns host:port, with brackets around an IPv6 address.
func (r Resolver) Addr() string {
	return net.JoinHostPort(r.Host, strconv.Itoa(r.Port))
}

// URL returns the DoH URL, or "" for other kinds.
func (r Resolver) URL() string {
	if r.Kind != KindDoH {
		return ""
	}
	host := r.Addr()
	if r.Port == 443 {
		host = r.Host
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
	}
	return "https://" + host + r.Path
}

// String returns the canonical spec: ParseResolver(r.String()) gives r back.
func (r Resolver) String() string {
	switch r.Kind {
	case KindDoH:
		return r.URL()
	case KindDoT:
		return "tls://" + r.Addr()
	default:
		return r.Addr()
	}
}

// ParseResolver parses a resolver spec (see Resolver).
func ParseResolver(spec string) (Resolver, error) {
	s := strings.TrimSpace(spec)
	if s == "" {
		return Resolver{}, fmt.Errorf("empty resolver")
	}
	i := strings.Index(s, "://")
	if i < 0 {
		return parseUDPAddr(s)
	}

	scheme := strings.ToLower(s[:i])
	var r Resolver
	switch scheme {
	case "udp":
		r = Resolver{Kind: KindUDP, Port: 53}
	case "https":
		r = Resolver{Kind: KindDoH, Port: 443}
	case "tls":
		r = Resolver{Kind: KindDoT, Port: 853}
	default:
		return Resolver{}, fmt.Errorf("unsupported resolver scheme %q", s[:i])
	}
	if strings.Contains(s, "#") {
		return Resolver{}, fmt.Errorf("resolver %q: fragment not allowed", s)
	}
	u, err := url.Parse(scheme + s[i:])
	if err != nil {
		return Resolver{}, fmt.Errorf("invalid resolver %q: %v", s, err)
	}
	if u.User != nil {
		return Resolver{}, fmt.Errorf("resolver %q: user info not allowed", s)
	}
	if u.Host == "" {
		return Resolver{}, fmt.Errorf("resolver %q: missing host", s)
	}
	host, err := checkHost(u.Hostname())
	if err != nil {
		return Resolver{}, fmt.Errorf("resolver %q: %v", s, err)
	}
	r.Host = host
	if port := u.Port(); port != "" {
		r.Port, err = parsePort(port)
		if err != nil {
			return Resolver{}, fmt.Errorf("resolver %q: %v", s, err)
		}
	} else if strings.HasSuffix(u.Host, ":") {
		return Resolver{}, fmt.Errorf("resolver %q: empty port", s)
	}

	if r.Kind == KindDoH {
		r.Path = u.EscapedPath()
		if r.Path == "" {
			r.Path = "/dns-query"
		}
		if u.RawQuery != "" {
			r.Path += "?" + u.RawQuery
		}
	} else if u.Path != "" || u.RawQuery != "" || u.ForceQuery {
		return Resolver{}, fmt.Errorf("resolver %q: path not allowed", s)
	}
	return r, nil
}

// parseUDPAddr parses a spec without a scheme: an address, optionally with a
// port.
func parseUDPAddr(s string) (Resolver, error) {
	r := Resolver{Kind: KindUDP, Port: 53}
	host := s
	if _, err := netip.ParseAddr(s); err != nil {
		// Not a bare address: host:port, [IPv6]:port, [IPv6] or a name.
		if h, port, err := net.SplitHostPort(s); err == nil {
			host = h
			r.Port, err = parsePort(port)
			if err != nil {
				return Resolver{}, fmt.Errorf("resolver %q: %v", s, err)
			}
		} else if strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]") {
			host = s[1 : len(s)-1]
			if _, err := netip.ParseAddr(host); err != nil {
				return Resolver{}, fmt.Errorf("resolver %q: invalid IPv6 address", s)
			}
		}
	}
	host, err := checkHost(host)
	if err != nil {
		return Resolver{}, fmt.Errorf("resolver %q: %v", s, err)
	}
	r.Host = host
	return r, nil
}

func parsePort(s string) (int, error) {
	if s == "" || len(s) > 5 || strings.Trim(s, "0123456789") != "" {
		return 0, fmt.Errorf("invalid port %q", s)
	}
	port, _ := strconv.Atoi(s)
	if port < 1 || port > 65535 {
		return 0, fmt.Errorf("port %d out of range", port)
	}
	return port, nil
}

// checkHost checks that host is an IP address (without zone) or a host name,
// and returns it in canonical form.
func checkHost(host string) (string, error) {
	if host == "" {
		return "", fmt.Errorf("missing host")
	}
	if strings.Contains(host, ":") || strings.Contains(host, "%") {
		addr, err := netip.ParseAddr(host)
		if err != nil {
			return "", fmt.Errorf("invalid address %q", host)
		}
		if addr.Zone() != "" {
			return "", fmt.Errorf("address %q: zone not allowed", host)
		}
		return addr.String(), nil
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		return addr.String(), nil
	}
	name := strings.ToLower(strings.TrimSuffix(host, "."))
	if len(name) == 0 || len(name) > 253 {
		return "", fmt.Errorf("invalid host name %q", host)
	}
	labels := strings.Split(name, ".")
	for _, label := range labels {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' ||
			strings.Trim(label, "abcdefghijklmnopqrstuvwxyz0123456789-") != "" {
			return "", fmt.Errorf("invalid host name %q", host)
		}
	}
	// A numeric top-level label is a mistyped IPv4 address, not a name.
	if strings.Trim(labels[len(labels)-1], "0123456789") == "" {
		return "", fmt.Errorf("invalid address %q", host)
	}
	return name, nil
}

// Options control how a resolver is reached.
type Options struct {
	// Bootstrap is an IP address to connect to instead of resolving the
	// resolver's host name. TLS server name, certificate check and HTTP
	// Host keep the name. Empty: resolve the name with the system resolver.
	Bootstrap string
	// TLSFingerprint is a uTLS fingerprint distribution such as
	// "3*Chrome,1*Firefox", a single label, or "none" for Go's own TLS.
	// Empty means DefaultTLSFingerprint. One fingerprint is sampled per Open.
	TLSFingerprint string
	// Protect, if set, is called with the file descriptor of every socket
	// before it connects (Android VpnService.protect). Returning false
	// fails the connection.
	Protect func(fd int) bool
	// RootCAs are the trusted certificate authorities; nil means the
	// system roots.
	RootCAs *x509.CertPool
}

// ParseBootstrap checks a bootstrap address: empty, or an IP address without
// zone.
func ParseBootstrap(s string) (netip.Addr, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return netip.Addr{}, nil
	}
	addr, err := netip.ParseAddr(strings.TrimSuffix(strings.TrimPrefix(s, "["), "]"))
	if err != nil || addr.Zone() != "" {
		return netip.Addr{}, fmt.Errorf("invalid bootstrap address %q", s)
	}
	return addr.Unmap(), nil
}

// SampleTLSFingerprint parses a fingerprint distribution (empty means
// DefaultTLSFingerprint) and samples one fingerprint from it. nil means Go's
// own TLS ("none").
func SampleTLSFingerprint(spec string) (*utls.ClientHelloID, error) {
	if strings.TrimSpace(spec) == "" {
		spec = DefaultTLSFingerprint
	}
	return sampleUTLSDistribution(spec)
}

// sampleUTLSDistribution parses a weighted uTLS Client Hello ID distribution
// string of the form "3*Firefox,2*Chrome,1*iOS", matches each label to a
// utls.ClientHelloID from utlsClientHelloIDMap, and randomly samples one
// utls.ClientHelloID from the distribution.
func sampleUTLSDistribution(spec string) (*utls.ClientHelloID, error) {
	weights, labels, err := parseWeightedList(spec)
	if err != nil {
		return nil, err
	}
	ids := make([]*utls.ClientHelloID, 0, len(labels))
	for _, label := range labels {
		var id *utls.ClientHelloID
		if label == "none" {
			id = nil
		} else {
			id = utlsLookup(label)
			if id == nil {
				return nil, fmt.Errorf("unknown TLS fingerprint %q", label)
			}
		}
		ids = append(ids, id)
	}
	return ids[sampleWeighted(weights)], nil
}

// Open opens a transport for DNS messages to the resolver: a UDP socket, an
// HTTPPacketConn or a TLSPacketConn. Messages are written to the returned
// address. For DoT the TLS connection is made here, bounded by ctx; DoH
// connects on the first message.
func Open(ctx context.Context, r Resolver, opts Options) (net.PacketConn, net.Addr, error) {
	bootstrap, err := ParseBootstrap(opts.Bootstrap)
	if err != nil {
		return nil, nil, err
	}
	d := &dialer{host: r.Host, bootstrap: bootstrap, protect: opts.Protect}
	switch r.Kind {
	case KindUDP:
		return d.listenUDP(ctx, r)
	case KindDoH, KindDoT:
	default:
		return nil, nil, fmt.Errorf("unknown resolver kind %q", r.Kind)
	}

	id, err := SampleTLSFingerprint(opts.TLSFingerprint)
	if err != nil {
		return nil, nil, err
	}
	if id != nil {
		log.Printf("uTLS fingerprint %s %s", id.Client, id.Version)
	}

	if r.Kind == KindDoH {
		var rt http.RoundTripper
		if id == nil {
			tr := http.DefaultTransport.(*http.Transport).Clone()
			// No proxy from the environment, as with uTLS and DoT.
			tr.Proxy = nil
			tr.DialContext = d.DialContext
			tr.TLSClientConfig = &tls.Config{RootCAs: opts.RootCAs}
			tr.HTTP2 = &http.HTTP2Config{
				SendPingTimeout: http2ReadIdleTimeout,
				PingTimeout:     http2PingTimeout,
			}
			rt = tr
		} else {
			rt = NewUTLSRoundTripper(&utls.Config{RootCAs: opts.RootCAs}, id, d.DialContext)
		}
		pconn, err := NewHTTPPacketConn(rt, r.URL(), numHTTPSenders)
		if err != nil {
			return nil, nil, err
		}
		return pconn, turbotunnel.DummyAddr{}, nil
	}

	dialTLS := func(ctx context.Context, network, addr string) (net.Conn, error) {
		if id == nil {
			conn, err := d.DialContext(ctx, network, addr)
			if err != nil {
				return nil, err
			}
			tconn := tls.Client(conn, &tls.Config{ServerName: r.Host, RootCAs: opts.RootCAs})
			if err := tconn.HandshakeContext(ctx); err != nil {
				conn.Close()
				return nil, err
			}
			return tconn, nil
		}
		return utlsDialContext(ctx, network, addr, &utls.Config{ServerName: r.Host, RootCAs: opts.RootCAs}, id, d.DialContext)
	}
	pconn, err := NewTLSPacketConn(ctx, r.Addr(), dialTLS)
	if err != nil {
		return nil, nil, err
	}
	return pconn, turbotunnel.DummyAddr{}, nil
}
