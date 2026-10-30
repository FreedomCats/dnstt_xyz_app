package client

import (
	"context"
	"encoding/binary"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"www.bamsoftware.com/git/dnstt.git/dns"
)

// How long the bridge remembers who sent a query.
const bridgeQueryTimeout = 15 * time.Second

// questionKey is the question of a query.
type questionKey struct {
	name  string // lower case
	qtype uint16
	class uint16
}

// queryKey identifies a query and its answer: the transports may return
// answers in any order.
type queryKey struct {
	id uint16
	questionKey
}

type pendingQuery struct {
	addr    net.Addr
	expires time.Time
}

// Bridge is a local UDP DNS server that forwards each query unchanged
// through a resolver transport (UDP, DoH or DoT) and sends the answer back to
// the query's sender. It lets programs that speak only UDP DNS, such as
// slipstream-client, use DoH and DoT resolvers. An answer goes to the query
// with the same ID and question, or, if the resolver changed the ID, to the
// latest query with the same question, with the ID restored.
type Bridge struct {
	local     *net.UDPConn
	transport net.PacketConn
	remote    net.Addr

	mu      sync.Mutex
	pending map[queryKey]pendingQuery
	// The ID of the latest pending query for each question, for resolvers
	// that answer with another ID.
	latestID map[questionKey]uint16

	done      chan struct{}
	closeOnce sync.Once
	wg        sync.WaitGroup
}

// NewBridge opens the resolver transport and listens on 127.0.0.1 on a free
// UDP port.
func NewBridge(ctx context.Context, r Resolver, opts Options) (*Bridge, error) {
	transport, remote, err := Open(ctx, r, opts)
	if err != nil {
		return nil, err
	}
	local, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		transport.Close()
		return nil, err
	}
	b := &Bridge{
		local:     local,
		transport: transport,
		remote:    remote,
		pending:   make(map[queryKey]pendingQuery),
		latestID:  make(map[questionKey]uint16),
		done:      make(chan struct{}),
	}
	b.wg.Add(3)
	go b.queryLoop()
	go b.answerLoop()
	go b.expireLoop()
	return b, nil
}

// Addr returns the local address the bridge listens on.
func (b *Bridge) Addr() *net.UDPAddr {
	return b.local.LocalAddr().(*net.UDPAddr)
}

// Close stops the bridge and closes the resolver transport.
func (b *Bridge) Close() error {
	b.closeOnce.Do(func() {
		close(b.done)
		b.local.Close()
		b.transport.Close()
	})
	b.wg.Wait()
	return nil
}

func (b *Bridge) closed() bool {
	select {
	case <-b.done:
		return true
	default:
		return false
	}
}

// keyOf returns the key of a DNS message, or false if it is not a message
// with exactly one question.
func keyOf(p []byte) (queryKey, bool) {
	msg, err := dns.MessageFromWireFormat(p)
	if err != nil || len(msg.Question) != 1 {
		return queryKey{}, false
	}
	q := msg.Question[0]
	return queryKey{
		id:          msg.ID,
		questionKey: questionKey{name: strings.ToLower(q.Name.String()), qtype: q.Type, class: q.Class},
	}, true
}

// take removes the pending query an answer with key belongs to and returns
// it with the query's key. If no query has the answer's ID, it takes the
// latest query with the same question. Call with b.mu held.
func (b *Bridge) take(key queryKey) (queryKey, pendingQuery, bool) {
	q, ok := b.pending[key]
	if !ok {
		id, found := b.latestID[key.questionKey]
		if !found {
			return key, pendingQuery{}, false
		}
		key.id = id
		q, ok = b.pending[key]
	}
	if ok {
		b.forget(key)
	}
	return key, q, ok
}

// forget removes a pending query. Call with b.mu held.
func (b *Bridge) forget(key queryKey) {
	delete(b.pending, key)
	if id, ok := b.latestID[key.questionKey]; ok && id == key.id {
		delete(b.latestID, key.questionKey)
	}
}

// queryLoop forwards queries from local clients to the resolver.
func (b *Bridge) queryLoop() {
	defer b.wg.Done()
	buf := make([]byte, 65536)
	for {
		n, addr, err := b.local.ReadFrom(buf)
		if err != nil {
			if b.closed() {
				return
			}
			if err, ok := err.(net.Error); ok && err.Timeout() {
				continue
			}
			log.Printf("bridge: read query: %v", err)
			return
		}
		p := buf[:n]
		key, ok := keyOf(p)
		if !ok {
			continue
		}
		b.mu.Lock()
		b.pending[key] = pendingQuery{addr: addr, expires: time.Now().Add(bridgeQueryTimeout)}
		b.latestID[key.questionKey] = key.id
		b.mu.Unlock()
		// The transports copy p.
		if _, err := b.transport.WriteTo(p, b.remote); err != nil && !b.closed() {
			log.Printf("bridge: send query: %v", err)
		}
	}
}

// answerLoop sends answers from the resolver to the clients that asked.
func (b *Bridge) answerLoop() {
	defer b.wg.Done()
	buf := make([]byte, 65536)
	for {
		n, addr, err := b.transport.ReadFrom(buf)
		if err != nil {
			if b.closed() {
				return
			}
			if err, ok := err.(net.Error); ok && err.Temporary() {
				continue
			}
			log.Printf("bridge: read answer: %v", err)
			return
		}
		// A UDP socket accepts datagrams from anyone: take answers only
		// from the resolver.
		if remote, ok := b.remote.(*net.UDPAddr); ok {
			if from, ok := addr.(*net.UDPAddr); !ok || !from.IP.Equal(remote.IP) || from.Port != remote.Port {
				continue
			}
		}
		p := buf[:n]
		key, ok := keyOf(p)
		if !ok {
			continue
		}
		b.mu.Lock()
		queryKey, q, ok := b.take(key)
		b.mu.Unlock()
		if !ok {
			continue
		}
		if queryKey.id != key.id {
			binary.BigEndian.PutUint16(p, queryKey.id)
		}
		if _, err := b.local.WriteTo(p, q.addr); err != nil && !b.closed() {
			log.Printf("bridge: send answer: %v", err)
		}
	}
}

// expireLoop forgets queries that got no answer.
func (b *Bridge) expireLoop() {
	defer b.wg.Done()
	ticker := time.NewTicker(bridgeQueryTimeout / 3)
	defer ticker.Stop()
	for {
		select {
		case <-b.done:
			return
		case now := <-ticker.C:
			b.mu.Lock()
			for key, q := range b.pending {
				if now.After(q.expires) {
					b.forget(key)
				}
			}
			b.mu.Unlock()
		}
	}
}
