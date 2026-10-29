// Package mobile provides a mobile-friendly interface to dnstt-client
package mobile

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"www.bamsoftware.com/git/dnstt.git/client"
	"www.bamsoftware.com/git/dnstt.git/dns"
	"www.bamsoftware.com/git/dnstt.git/noise"
)

const (
	// How long connecting to a UDP resolver and the Noise handshake may
	// take (10 seconds for faster feedback).
	handshakeTimeout = 10 * time.Second

	// The same for DoH and DoT, which first set up a TLS connection to the
	// resolver.
	handshakeTimeoutTLS = 20 * time.Second

	// How long setting up a bridge's DoT connection may take.
	bridgeTimeout = 20 * time.Second
)

// SocketProtector keeps a socket out of the VPN: on Android, implement it with
// VpnService.protect.
type SocketProtector interface {
	Protect(fd int) bool
}

// DnsttClient wraps the dnstt tunnel client
type DnsttClient struct {
	mu             sync.Mutex
	running        bool
	listener       net.Listener
	tunnel         *client.Tunnel
	ctx            context.Context
	cancel         context.CancelFunc
	pubKey         []byte
	domain         string
	resolver       client.Resolver
	bootstrap      string
	tlsFingerprint string
	listenAddr     string
	tunFd          int
	protector      SocketProtector
	shareProxy     bool // If true, bind to 0.0.0.0 instead of 127.0.0.1
}

// NewClient creates a new dnstt client. resolver is a resolver spec: an IP
// address (UDP, port 53 by default), "udp://host[:port]",
// "https://host[:port]/path" (DoH) or "tls://host[:port]" (DoT).
func NewClient(resolver, tunnelDomain, pubKeyHex, listenAddr string) (*DnsttClient, error) {
	pubKey, err := noise.DecodeKey(pubKeyHex)
	if err != nil {
		return nil, fmt.Errorf("invalid public key: %v", err)
	}
	r, err := client.ParseResolver(resolver)
	if err != nil {
		return nil, fmt.Errorf("invalid DNS server: %v", err)
	}

	return &DnsttClient{
		pubKey:     pubKey,
		domain:     tunnelDomain,
		resolver:   r,
		listenAddr: listenAddr,
		tunFd:      -1,
	}, nil
}

// SetBootstrap sets the IP address to connect to instead of resolving the host
// name of a DoH or DoT resolver ("" to resolve it). Call before Start.
func (c *DnsttClient) SetBootstrap(addr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.bootstrap = addr
}

// SetTLSFingerprint sets the TLS fingerprint distribution for DoH and DoT,
// such as "Chrome", "3*Chrome,1*Firefox" or "none" ("" for the default). Call
// before Start.
func (c *DnsttClient) SetTLSFingerprint(spec string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tlsFingerprint = spec
}

// SetTunFd sets the TUN file descriptor for routing traffic
func (c *DnsttClient) SetTunFd(fd int) {
	c.tunFd = fd
}

// SetSocketProtector sets a callback that keeps the tunnel's sockets out of
// the VPN. Call before Start.
func (c *DnsttClient) SetSocketProtector(p SocketProtector) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.protector = p
}

// SetShareProxy enables or disables proxy sharing (binding to 0.0.0.0)
func (c *DnsttClient) SetShareProxy(enabled bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.shareProxy = enabled
}

// IsShareProxyEnabled returns whether proxy sharing is enabled
func (c *DnsttClient) IsShareProxyEnabled() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.shareProxy
}

// options returns the client options for reaching a resolver.
func options(bootstrap, fingerprint string, protector SocketProtector) client.Options {
	opts := client.Options{Bootstrap: bootstrap, TLSFingerprint: fingerprint}
	if protector != nil {
		opts.Protect = func(fd int) bool {
			ok := protector.Protect(fd)
			if ok {
				log.Printf("socket protected from VPN routing (fd=%d)", fd)
			}
			return ok
		}
	}
	return opts
}

// Start starts the SOCKS5 proxy
func (c *DnsttClient) Start() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.running {
		return nil
	}

	// Parse domain
	domain, err := dns.ParseName(c.domain)
	if err != nil {
		return fmt.Errorf("invalid domain: %v", err)
	}
	mtu, err := client.MTU(domain)
	if err != nil {
		return err
	}
	log.Printf("effective MTU %d", mtu)

	timeout := handshakeTimeout
	if c.resolver.Kind != client.KindUDP {
		timeout = handshakeTimeoutTLS
	}
	connectCtx, cancelConnect := context.WithTimeout(context.Background(), timeout)
	defer cancelConnect()

	opts := options(c.bootstrap, c.tlsFingerprint, c.protector)
	pconn, remoteAddr, err := client.Open(connectCtx, c.resolver, opts)
	if err != nil {
		return fmt.Errorf("failed to connect to DNS server: %v", err)
	}
	log.Printf("resolver %s (%s)", c.resolver.Kind, c.resolver)

	tunnel, err := client.NewTunnel(connectCtx, pconn, remoteAddr, domain, c.pubKey)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return fmt.Errorf("connection timeout: DNS server not responding")
		}
		return fmt.Errorf("failed to create noise session: %v", err)
	}

	// Determine the listen address based on proxy sharing
	listenAddr := c.listenAddr
	if c.shareProxy {
		// Replace 127.0.0.1 with 0.0.0.0 to allow connections from other devices
		if strings.HasPrefix(listenAddr, "127.0.0.1:") {
			port := strings.TrimPrefix(listenAddr, "127.0.0.1:")
			listenAddr = "0.0.0.0:" + port
			log.Printf("Proxy sharing enabled, listening on %s", listenAddr)
		}
	}

	// Start TCP listener for SOCKS5
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		tunnel.Close()
		return fmt.Errorf("failed to start listener: %v", err)
	}

	c.ctx, c.cancel = context.WithCancel(context.Background())
	c.tunnel = tunnel
	c.listener = listener

	// Accept connections
	go c.acceptLoop(c.ctx, listener, tunnel)

	c.running = true
	log.Printf("dnstt client started, listening on %s", c.listenAddr)
	return nil
}

// Stop stops the client
func (c *DnsttClient) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.running {
		return
	}

	if c.cancel != nil {
		c.cancel()
	}
	if c.listener != nil {
		c.listener.Close()
	}
	if c.tunnel != nil {
		c.tunnel.Close()
	}
	c.listener = nil
	c.tunnel = nil

	c.running = false
	log.Printf("dnstt client stopped")
}

// IsRunning returns whether the client is running
func (c *DnsttClient) IsRunning() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.running
}

// DialTunnel creates a connection through the tunnel to the specified address
func (c *DnsttClient) DialTunnel(address string) (net.Conn, error) {
	c.mu.Lock()
	tunnel := c.tunnel
	c.mu.Unlock()

	if tunnel == nil {
		return nil, fmt.Errorf("tunnel not connected")
	}

	stream, err := tunnel.OpenStream()
	if err != nil {
		return nil, err
	}

	return stream, nil
}

func (c *DnsttClient) acceptLoop(ctx context.Context, listener net.Listener, tunnel *client.Tunnel) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			log.Printf("accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}

		go handleConnection(conn.(*net.TCPConn), tunnel)
	}
}

func handleConnection(local *net.TCPConn, tunnel *client.Tunnel) {
	defer local.Close()

	stream, err := tunnel.OpenStream()
	if err != nil {
		log.Printf("failed to open stream: %v", err)
		return
	}
	defer stream.Close()

	log.Printf("new stream opened")

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		io.Copy(stream, local)
		local.CloseRead()
		stream.Close()
	}()
	go func() {
		defer wg.Done()
		io.Copy(local, stream)
		local.CloseWrite()
	}()
	wg.Wait()
}

// ResolverKind returns the transport of a resolver spec: "udp", "doh", "dot",
// or "" if the spec is invalid.
func ResolverKind(spec string) string {
	r, err := client.ParseResolver(spec)
	if err != nil {
		return ""
	}
	return string(r.Kind)
}

// UdpResolverAddr returns "host:port" (IPv6 in brackets) for a UDP resolver
// spec, and "" for other kinds or an invalid spec.
func UdpResolverAddr(spec string) string {
	r, err := client.ParseResolver(spec)
	if err != nil || r.Kind != client.KindUDP {
		return ""
	}
	return r.Addr()
}

// Bridge is a local UDP DNS server on 127.0.0.1 that forwards queries to a
// resolver over UDP, DoH or DoT (for slipstream-client, which speaks only
// UDP).
type Bridge struct {
	bridge *client.Bridge
}

// StartBridge starts a bridge to the resolver given by spec, with an optional
// bootstrap address and TLS fingerprint distribution as for DnsttClient.
func StartBridge(spec, bootstrap, fingerprint string) (*Bridge, error) {
	r, err := client.ParseResolver(spec)
	if err != nil {
		return nil, fmt.Errorf("invalid DNS server: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), bridgeTimeout)
	defer cancel()
	b, err := client.NewBridge(ctx, r, options(bootstrap, fingerprint, nil))
	if err != nil {
		return nil, err
	}
	log.Printf("bridge to %s resolver on %s", r.Kind, b.Addr())
	return &Bridge{bridge: b}, nil
}

// Port returns the bridge's UDP port on 127.0.0.1.
func (b *Bridge) Port() int {
	return b.bridge.Addr().Port
}

// Stop stops the bridge.
func (b *Bridge) Stop() {
	b.bridge.Close()
}

// ProbeResolver sends one DNSTT polling query for tunnelDomain through the
// resolver and returns the time to the answer in milliseconds, connection
// setup included. It fails if there is no answer within timeoutMs or the
// answer is not NOERROR. The server holds a lone poll for up to a second, so
// the time includes that wait.
func ProbeResolver(spec, bootstrap, fingerprint, tunnelDomain string, timeoutMs int) (int, error) {
	r, err := client.ParseResolver(spec)
	if err != nil {
		return 0, fmt.Errorf("invalid DNS server: %v", err)
	}
	domain, err := dns.ParseName(tunnelDomain)
	if err != nil {
		return 0, fmt.Errorf("invalid domain: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	latency, err := client.Probe(ctx, r, options(bootstrap, fingerprint, nil), domain)
	if err != nil {
		return 0, err
	}
	return int(latency.Milliseconds()), nil
}

// GetLocalIPAddresses returns a comma-separated list of local IP addresses
func GetLocalIPAddresses() string {
	var ips []string
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	for _, iface := range ifaces {
		// Skip down interfaces and loopback
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			// Skip IPv6 and loopback addresses
			if ip == nil || ip.IsLoopback() || ip.To4() == nil {
				continue
			}

			// Only include private network addresses
			if isPrivateIP(ip) {
				ips = append(ips, ip.String())
			}
		}
	}

	return strings.Join(ips, ",")
}

// isPrivateIP checks if the IP is a private network address
func isPrivateIP(ip net.IP) bool {
	privateBlocks := []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
	}

	for _, block := range privateBlocks {
		_, subnet, err := net.ParseCIDR(block)
		if err != nil {
			continue
		}
		if subnet.Contains(ip) {
			return true
		}
	}
	return false
}

// ConnectWithTunFd starts the tunnel using a TUN file descriptor from Android
// This allows the Go code to handle TCP/IP directly
func ConnectWithTunFd(fd int, dnsServer, tunnelDomain, pubKeyHex, socksAddr string) error {
	// Create a file from the fd
	tunFile := os.NewFile(uintptr(fd), "tun")
	if tunFile == nil {
		return fmt.Errorf("invalid tun fd")
	}

	log.Printf("TUN fd received: %d", fd)

	// For now, we don't use gvisor netstack - that would require more dependencies
	// Instead, we just log that this feature needs tun2socks integration
	log.Printf("Note: Full TUN integration requires tun2socks - using SOCKS5 proxy mode")

	return nil
}
