package client

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"syscall"
)

// dialer makes the sockets to a resolver: it substitutes the bootstrap address
// for the resolver's host name and lets the protect hook see each socket.
type dialer struct {
	// host is the resolver's host name or address.
	host string
	// bootstrap, if valid, is dialed instead of host.
	bootstrap netip.Addr
	protect   func(fd int) bool
}

var errProtect = errors.New("failed to protect socket")

func (d *dialer) control(network, address string, c syscall.RawConn) error {
	if d.protect == nil {
		return nil
	}
	ok := false
	err := c.Control(func(fd uintptr) {
		ok = d.protect(int(fd))
	})
	if err != nil {
		return err
	}
	if !ok {
		return errProtect
	}
	return nil
}

// DialContext dials a TCP connection, to the bootstrap address if addr is the
// resolver's host.
func (d *dialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	if d.bootstrap.IsValid() && strings.EqualFold(host, d.host) {
		addr = net.JoinHostPort(d.bootstrap.String(), port)
	}
	nd := net.Dialer{Timeout: dialTimeout, Control: d.control}
	return nd.DialContext(ctx, network, addr)
}

// listenUDP opens a UDP socket for the resolver and returns it with the
// resolver's address. IPv4 resolvers get an IPv4-only socket on 0.0.0.0, as
// the app has always used (an IPv6 socket could be routed differently).
func (d *dialer) listenUDP(ctx context.Context, r Resolver) (net.PacketConn, net.Addr, error) {
	ip, err := d.resolve(ctx, r.Host)
	if err != nil {
		return nil, nil, err
	}
	network, local := "udp4", "0.0.0.0:0"
	if !ip.Is4() {
		network, local = "udp6", "[::]:0"
	}
	lc := net.ListenConfig{Control: d.control}
	pconn, err := lc.ListenPacket(ctx, network, local)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create UDP socket: %v", err)
	}
	return pconn, net.UDPAddrFromAddrPort(netip.AddrPortFrom(ip, uint16(r.Port))), nil
}

// resolve returns the address of host: host itself if it is an address, else
// the bootstrap address, else the first address the system resolver gives,
// preferring IPv4.
func (d *dialer) resolve(ctx context.Context, host string) (netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap(), nil
	}
	if d.bootstrap.IsValid() {
		return d.bootstrap, nil
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return netip.Addr{}, err
	}
	for _, ip := range ips {
		if ip.Unmap().Is4() {
			return ip.Unmap(), nil
		}
	}
	if len(ips) == 0 {
		return netip.Addr{}, fmt.Errorf("no address for %s", host)
	}
	return ips[0], nil
}
