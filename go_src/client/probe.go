package client

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"www.bamsoftware.com/git/dnstt.git/dns"
	"www.bamsoftware.com/git/dnstt.git/turbotunnel"
)

// rcodeNames names the RCODEs a resolver commonly answers with.
var rcodeNames = map[uint16]string{
	1: "FORMERR",
	2: "SERVFAIL",
	3: "NXDOMAIN",
	4: "NOTIMP",
	5: "REFUSED",
}

// RcodeError is a DNS answer with an RCODE other than NOERROR.
type RcodeError struct {
	Rcode uint16
}

func (e *RcodeError) Error() string {
	if name, ok := rcodeNames[e.Rcode]; ok {
		return "resolver answered " + name
	}
	return fmt.Sprintf("resolver answered RCODE %d", e.Rcode)
}

// Probe sends one DNSTT polling query under domain through the resolver, with
// a new random client ID, and returns the time from the start (connection
// setup included) to the answer. An answer with RCODE NOERROR is success;
// any other RCODE is an *RcodeError. The DNSTT server holds a lone poll for up
// to a second before it answers, so that wait is part of the time.
func Probe(ctx context.Context, r Resolver, opts Options, domain dns.Name) (time.Duration, error) {
	start := time.Now()
	transport, addr, err := Open(ctx, r, opts)
	if err != nil {
		return 0, err
	}
	defer transport.Close()

	query, err := encodeQuery(turbotunnel.NewClientID(), domain, nil)
	if err != nil {
		return 0, err
	}
	buf, err := query.WireFormat()
	if err != nil {
		return 0, err
	}
	if _, err := transport.WriteTo(buf, addr); err != nil {
		return 0, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		// Supported by the UDP socket; the other transports end their
		// reads when closed.
		transport.SetReadDeadline(deadline)
	}

	type result struct {
		resp dns.Message
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		var buf [65536]byte
		for {
			n, _, err := transport.ReadFrom(buf[:])
			if err != nil {
				ch <- result{err: err}
				return
			}
			resp, err := dns.MessageFromWireFormat(buf[:n])
			if err != nil || resp.ID != query.ID || resp.Flags&0x8000 == 0 ||
				len(resp.Question) != 1 || !strings.EqualFold(resp.Question[0].Name.String(), query.Question[0].Name.String()) {
				// Not the answer to our query.
				continue
			}
			ch <- result{resp: resp}
			return
		}
	}()

	select {
	case <-ctx.Done():
		return 0, fmt.Errorf("no answer from resolver: %w", ctx.Err())
	case res := <-ch:
		if res.err != nil {
			if ctx.Err() != nil {
				return 0, fmt.Errorf("no answer from resolver: %w", ctx.Err())
			}
			// The read deadline comes from ctx and may pass a moment
			// before ctx reports it.
			var netErr net.Error
			if errors.As(res.err, &netErr) && netErr.Timeout() {
				return 0, fmt.Errorf("no answer from resolver: %w", context.DeadlineExceeded)
			}
			return 0, res.err
		}
		if rcode := res.resp.Rcode(); rcode != dns.RcodeNoError {
			return 0, &RcodeError{Rcode: rcode}
		}
		return time.Since(start), nil
	}
}
