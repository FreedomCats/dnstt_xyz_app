package client

import (
	"bytes"
	"testing"

	"www.bamsoftware.com/git/dnstt.git/dns"
)

func TestDNSNameCapacity(t *testing.T) {
	for domainLen := 0; domainLen < 255; domainLen++ {
		domain, err := dns.NewName(chunks(bytes.Repeat([]byte{'x'}, domainLen), 63))
		if err != nil {
			continue
		}
		capacity := dnsNameCapacity(domain)
		if capacity <= 0 {
			continue
		}
		prefix := []byte(base32Encoding.EncodeToString(bytes.Repeat([]byte{'y'}, capacity)))
		labels := append(chunks(prefix, 63), domain...)
		_, err = dns.NewName(labels)
		if err != nil {
			t.Errorf("length %v  capacity %v  %v", domainLen, capacity, err)
		}
	}
}

func mustParseName(t *testing.T, s string) dns.Name {
	t.Helper()
	name, err := dns.ParseName(s)
	if err != nil {
		t.Fatal(err)
	}
	return name
}
