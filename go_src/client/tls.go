package client

import (
	"bufio"
	"context"
	"encoding/binary"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"www.bamsoftware.com/git/dnstt.git/turbotunnel"
)

// Variables, not constants, so that tests can shorten them.
var (
	// How long one dial of the TLS server may take, TLS handshake included.
	dialTimeout = 20 * time.Second

	// After a connection is lost, the next dial waits redialMinDelay. The
	// delay doubles after every failed dial and every connection that lasted
	// less than stableConnection, up to redialMaxDelay.
	redialMinDelay   = 500 * time.Millisecond
	redialMaxDelay   = 15 * time.Second
	stableConnection = 30 * time.Second

	// A connection is considered dead when a message was sent and nothing
	// has been received for this long. After a network change, the old TCP
	// connection may accept writes and never deliver anything; this gets the
	// tunnel onto a new connection. DNSTT polls at least every 10 seconds and
	// the server answers within about a second.
	responseTimeout = 20 * time.Second
)

// TLSPacketConn is a TLS- and TCP-based transport for DNS messages, used for
// DNS over TLS (DoT). Its WriteTo and ReadFrom methods exchange DNS messages
// over a TLS channel, prefixing each message with a two-octet length field as
// in DNS over TCP.
//
// TLSPacketConn deals only with already formatted DNS messages. It does not
// handle encoding information into the messages. That is rather the
// responsibility of DNSPacketConn.
//
// https://tools.ietf.org/html/rfc7858
type TLSPacketConn struct {
	// QueuePacketConn is the direct receiver of ReadFrom and WriteTo calls.
	// recvLoop and sendLoop take the messages out of the receive and send
	// queues and actually put them on the network.
	*turbotunnel.QueuePacketConn

	// ctx is canceled by Close, aborting a dial in progress.
	ctx    context.Context
	cancel context.CancelFunc

	// responseTimeout as it was when the conn was made.
	responseTimeout time.Duration
}

// NewTLSPacketConn creates a new TLSPacketConn configured to use the TLS
// server at addr as a DNS over TLS resolver. It maintains a TLS connection to
// the resolver, redialing with backoff whenever the connection is lost, until
// the TLSPacketConn is closed. The first dial happens here, bounded by ctx, so
// that immediate connection errors are reported to the caller.
func NewTLSPacketConn(ctx context.Context, addr string, dialTLSContext func(ctx context.Context, network, addr string) (net.Conn, error)) (*TLSPacketConn, error) {
	connCtx, cancel := context.WithCancel(context.Background())
	dialTimeout, minDelay, maxDelay, stable := dialTimeout, redialMinDelay, redialMaxDelay, stableConnection
	dial := func(ctx context.Context) (net.Conn, error) {
		ctx, cancelDial := context.WithTimeout(ctx, dialTimeout)
		defer cancelDial()
		return dialTLSContext(ctx, "tcp", addr)
	}
	conn, err := dial(ctx)
	if err != nil {
		cancel()
		return nil, err
	}
	c := &TLSPacketConn{
		QueuePacketConn: turbotunnel.NewQueuePacketConn(turbotunnel.DummyAddr{}, 0),
		ctx:             connCtx,
		cancel:          cancel,
		responseTimeout: responseTimeout,
	}
	go func() {
		delay := minDelay
		for {
			start := time.Now()
			c.serve(conn)
			if c.ctx.Err() != nil {
				return
			}
			if time.Since(start) >= stable {
				delay = minDelay
			}
			for {
				select {
				case <-c.ctx.Done():
					return
				case <-time.After(delay):
				}
				delay = min(delay*2, maxDelay)
				conn, err = dial(c.ctx)
				if err == nil {
					break
				}
				if c.ctx.Err() != nil {
					return
				}
				log.Printf("dial tls: %v", err)
			}
		}
	}()
	return c, nil
}

// Close closes the TLS connection and stops redialing.
func (c *TLSPacketConn) Close() error {
	err := c.QueuePacketConn.Close()
	c.cancel()
	return err
}

// serve exchanges messages over conn until conn fails, stops answering, or c
// is closed. It closes conn before returning.
func (c *TLSPacketConn) serve(conn net.Conn) {
	done := make(chan struct{})
	var once sync.Once
	stop := func() {
		once.Do(func() {
			close(done)
			conn.Close()
		})
	}

	// pendingSince is the time (UnixNano) of the first send after the last
	// receive, or 0 if nothing has been sent since.
	var pendingSince atomic.Int64

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		defer stop()
		err := c.recvLoop(conn, &pendingSince)
		if err != nil && c.ctx.Err() == nil {
			log.Printf("recvLoop: %v", err)
		}
	}()
	go func() {
		defer wg.Done()
		defer stop()
		err := c.sendLoop(conn, done, &pendingSince)
		if err != nil && c.ctx.Err() == nil {
			log.Printf("sendLoop: %v", err)
		}
	}()

	ticker := time.NewTicker(c.responseTimeout / 4)
	defer ticker.Stop()
loop:
	for {
		select {
		case <-done:
			break loop
		case <-c.ctx.Done():
			stop()
			break loop
		case now := <-ticker.C:
			since := pendingSince.Load()
			if since != 0 && now.Sub(time.Unix(0, since)) > c.responseTimeout {
				log.Printf("tls: no response for %v, reconnecting", c.responseTimeout)
				stop()
				break loop
			}
		}
	}
	wg.Wait()
}

// recvLoop reads length-prefixed messages from conn and passes them to the
// incoming queue.
func (c *TLSPacketConn) recvLoop(conn net.Conn, pendingSince *atomic.Int64) error {
	br := bufio.NewReader(conn)
	for {
		var length uint16
		err := binary.Read(br, binary.BigEndian, &length)
		if err != nil {
			if err == io.EOF {
				err = nil
			}
			return err
		}
		p := make([]byte, int(length))
		_, err = io.ReadFull(br, p)
		if err != nil {
			return err
		}
		pendingSince.Store(0)
		c.QueuePacketConn.QueueIncoming(p, turbotunnel.DummyAddr{})
	}
}

// sendLoop reads messages from the outgoing queue and writes them,
// length-prefixed, to conn, until done is closed or c is closed.
func (c *TLSPacketConn) sendLoop(conn net.Conn, done <-chan struct{}, pendingSince *atomic.Int64) error {
	bw := bufio.NewWriter(conn)
	outgoing := c.QueuePacketConn.OutgoingQueue(turbotunnel.DummyAddr{})
	for {
		var p []byte
		select {
		case p = <-outgoing:
		case <-done:
			return nil
		case <-c.QueuePacketConn.Closed():
			return nil
		}
		length := uint16(len(p))
		if int(length) != len(p) {
			panic(len(p))
		}
		err := binary.Write(bw, binary.BigEndian, &length)
		if err != nil {
			return err
		}
		_, err = bw.Write(p)
		if err != nil {
			return err
		}
		err = bw.Flush()
		if err != nil {
			return err
		}
		pendingSince.CompareAndSwap(0, time.Now().UnixNano())
	}
}
