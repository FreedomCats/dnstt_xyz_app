package client

import (
	"context"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/xtaci/kcp-go/v5"
	"github.com/xtaci/smux"
	"www.bamsoftware.com/git/dnstt.git/dns"
	"www.bamsoftware.com/git/dnstt.git/noise"
	"www.bamsoftware.com/git/dnstt.git/turbotunnel"
)

// smux streams will be closed after this much time without receiving data.
const idleTimeout = 2 * time.Minute

// dnsNameCapacity returns the number of bytes remaining for encoded data after
// including domain in a DNS name.
func dnsNameCapacity(domain dns.Name) int {
	// Names must be 255 octets or shorter in total length.
	// https://tools.ietf.org/html/rfc1035#section-2.3.4
	capacity := 255
	// Subtract the length of the null terminator.
	capacity -= 1
	for _, label := range domain {
		// Subtract the length of the label and the length octet.
		capacity -= len(label) + 1
	}
	// Each label may be up to 63 bytes long and requires 64 bytes to
	// encode.
	capacity = capacity * 63 / 64
	// Base32 expands every 5 bytes to 8.
	capacity = capacity * 5 / 8
	return capacity
}

// MTU returns the KCP MTU that queries under domain leave room for.
func MTU(domain dns.Name) (int, error) {
	mtu := dnsNameCapacity(domain) - 8 - 1 - numPadding - 1 // clientid + padding length prefix + padding + data length prefix
	if mtu < 80 {
		return 0, fmt.Errorf("domain %s leaves only %d bytes for payload", domain, mtu)
	}
	return mtu, nil
}

// Tunnel is a DNSTT session: smux streams over Noise over KCP over DNS
// messages carried by a transport (UDP, DoH or DoT).
type Tunnel struct {
	sess      *smux.Session
	kcpConn   *kcp.UDPSession
	dnsConn   *DNSPacketConn
	closeOnce sync.Once
}

// NewTunnel opens a tunnel to the DNSTT server for domain with public key
// pubkey, over transport, writing DNS messages to remoteAddr. The Noise
// handshake is aborted when ctx ends. The tunnel owns transport: Close, or a
// failed NewTunnel, closes it.
func NewTunnel(ctx context.Context, transport net.PacketConn, remoteAddr net.Addr, domain dns.Name, pubkey []byte) (*Tunnel, error) {
	mtu, err := MTU(domain)
	if err != nil {
		transport.Close()
		return nil, err
	}

	dnsConn := NewDNSPacketConn(transport, remoteAddr, domain)

	// Open a KCP conn on the PacketConn.
	conn, err := kcp.NewConn2(remoteAddr, nil, 0, 0, dnsConn)
	if err != nil {
		dnsConn.Close()
		return nil, fmt.Errorf("opening KCP conn: %v", err)
	}
	// Permit coalescing the payloads of consecutive sends.
	conn.SetStreamMode(true)
	// Disable the dynamic congestion window (limit only by the maximum of
	// local and remote static windows).
	conn.SetNoDelay(
		0, // default nodelay
		0, // default interval
		0, // default resend
		1, // nc=1 => congestion window off
	)
	conn.SetWindowSize(turbotunnel.QueueSize/2, turbotunnel.QueueSize/2)
	if !conn.SetMtu(mtu) {
		conn.Close()
		dnsConn.Close()
		return nil, fmt.Errorf("failed to set KCP MTU %d", mtu)
	}

	// Put a Noise channel on top of the KCP conn. Closing the KCP conn
	// aborts the handshake.
	type noiseResult struct {
		rw  io.ReadWriteCloser
		err error
	}
	ch := make(chan noiseResult, 1)
	go func() {
		rw, err := noise.NewClient(conn, pubkey)
		ch <- noiseResult{rw, err}
	}()
	var rw io.ReadWriteCloser
	select {
	case result := <-ch:
		if result.err != nil {
			conn.Close()
			dnsConn.Close()
			return nil, result.err
		}
		rw = result.rw
	case <-ctx.Done():
		conn.Close()
		dnsConn.Close()
		return nil, ctx.Err()
	}

	// Start a smux session on the Noise channel.
	smuxConfig := smux.DefaultConfig()
	smuxConfig.Version = 2
	smuxConfig.KeepAliveTimeout = idleTimeout
	smuxConfig.MaxStreamBuffer = 1 * 1024 * 1024 // default is 65536
	sess, err := smux.Client(rw, smuxConfig)
	if err != nil {
		rw.Close()
		conn.Close()
		dnsConn.Close()
		return nil, fmt.Errorf("opening smux session: %v", err)
	}
	return &Tunnel{sess: sess, kcpConn: conn, dnsConn: dnsConn}, nil
}

// OpenStream opens a stream to the server, which connects it to its
// upstream.
func (t *Tunnel) OpenStream() (*smux.Stream, error) {
	return t.sess.OpenStream()
}

// Conv returns the KCP conversation ID, for logging.
func (t *Tunnel) Conv() uint32 {
	return t.kcpConn.GetConv()
}

// CloseChan returns a channel that is closed when the session ends.
func (t *Tunnel) CloseChan() <-chan struct{} {
	return t.sess.CloseChan()
}

// IsClosed reports whether the session has ended.
func (t *Tunnel) IsClosed() bool {
	return t.sess.IsClosed()
}

// Close closes the session, the KCP conn and the transport.
func (t *Tunnel) Close() error {
	t.closeOnce.Do(func() {
		t.sess.Close()
		t.kcpConn.Close()
		t.dnsConn.Close()
	})
	return nil
}
