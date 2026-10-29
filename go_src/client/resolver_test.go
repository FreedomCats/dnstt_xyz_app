package client

import "testing"

func TestParseResolver(t *testing.T) {
	for _, test := range []struct {
		spec string
		want Resolver // Kind == "" means an error is expected
		str  string   // canonical spec
	}{
		// UDP without scheme: the format stored by the app until now
		{"192.0.2.1", Resolver{KindUDP, "192.0.2.1", 53, ""}, "192.0.2.1:53"},
		{" 192.0.2.1 ", Resolver{KindUDP, "192.0.2.1", 53, ""}, "192.0.2.1:53"},
		{"192.0.2.1:5353", Resolver{KindUDP, "192.0.2.1", 5353, ""}, "192.0.2.1:5353"},
		{"2001:db8::1", Resolver{KindUDP, "2001:db8::1", 53, ""}, "[2001:db8::1]:53"},
		{"2001:DB8::1", Resolver{KindUDP, "2001:db8::1", 53, ""}, "[2001:db8::1]:53"},
		{"[2001:db8::1]", Resolver{KindUDP, "2001:db8::1", 53, ""}, "[2001:db8::1]:53"},
		{"[2001:db8::1]:5353", Resolver{KindUDP, "2001:db8::1", 5353, ""}, "[2001:db8::1]:5353"},
		{"dns.example", Resolver{KindUDP, "dns.example", 53, ""}, "dns.example:53"},
		{"DNS.Example.:54", Resolver{KindUDP, "dns.example", 54, ""}, "dns.example:54"},
		{"192.0.2.300", Resolver{}, ""},
		{"192.0.2", Resolver{}, ""},
		{"192.0.2.1:0", Resolver{}, ""},
		{"192.0.2.1:65536", Resolver{}, ""},
		{"192.0.2.1:+53", Resolver{}, ""},
		{"192.0.2.1:", Resolver{}, ""},
		{"fe80::1%eth0", Resolver{}, ""},
		{"[fe80::1%eth0]:53", Resolver{}, ""},
		{"[192.0.2.1]x", Resolver{}, ""},
		{"dns_server.example", Resolver{}, ""},
		{"-dns.example", Resolver{}, ""},
		{"dns..example", Resolver{}, ""},
		{"", Resolver{}, ""},
		{"   ", Resolver{}, ""},

		// udp://
		{"udp://192.0.2.1", Resolver{KindUDP, "192.0.2.1", 53, ""}, "192.0.2.1:53"},
		{"UDP://192.0.2.1:5353", Resolver{KindUDP, "192.0.2.1", 5353, ""}, "192.0.2.1:5353"},
		{"udp://[2001:db8::1]:53", Resolver{KindUDP, "2001:db8::1", 53, ""}, "[2001:db8::1]:53"},
		{"udp://dns.example", Resolver{KindUDP, "dns.example", 53, ""}, "dns.example:53"},
		{"udp://192.0.2.1/x", Resolver{}, ""},
		{"udp://192.0.2.1?x", Resolver{}, ""},
		{"udp://2001:db8::1", Resolver{}, ""},
		{"udp://", Resolver{}, ""},

		// DoH
		{"https://dns.example/dns-query", Resolver{KindDoH, "dns.example", 443, "/dns-query"}, "https://dns.example/dns-query"},
		{"https://dns.example", Resolver{KindDoH, "dns.example", 443, "/dns-query"}, "https://dns.example/dns-query"},
		{"https://dns.example/", Resolver{KindDoH, "dns.example", 443, "/"}, "https://dns.example/"},
		{"HTTPS://DNS.example:8443/q?ct=x", Resolver{KindDoH, "dns.example", 8443, "/q?ct=x"}, "https://dns.example:8443/q?ct=x"},
		{"https://192.0.2.1/dns-query", Resolver{KindDoH, "192.0.2.1", 443, "/dns-query"}, "https://192.0.2.1/dns-query"},
		{"https://[2001:db8::1]/dns-query", Resolver{KindDoH, "2001:db8::1", 443, "/dns-query"}, "https://[2001:db8::1]/dns-query"},
		{"https://[2001:db8::1]:444/x", Resolver{KindDoH, "2001:db8::1", 444, "/x"}, "https://[2001:db8::1]:444/x"},
		{"https://dns.example/a%20b", Resolver{KindDoH, "dns.example", 443, "/a%20b"}, "https://dns.example/a%20b"},
		{"https://user@dns.example/dns-query", Resolver{}, ""},
		{"https://dns.example/dns-query#x", Resolver{}, ""},
		{"https://dns.example:/dns-query", Resolver{}, ""},
		{"https://dns.example:0/", Resolver{}, ""},
		{"https:///dns-query", Resolver{}, ""},
		{"http://dns.example/dns-query", Resolver{}, ""},

		// DoT
		{"tls://dns.example", Resolver{KindDoT, "dns.example", 853, ""}, "tls://dns.example:853"},
		{"tls://192.0.2.1:8853", Resolver{KindDoT, "192.0.2.1", 8853, ""}, "tls://192.0.2.1:8853"},
		{"tls://[2001:db8::1]", Resolver{KindDoT, "2001:db8::1", 853, ""}, "tls://[2001:db8::1]:853"},
		{"tls://dns.example/x", Resolver{}, ""},

		{"ftp://dns.example", Resolver{}, ""},
		{"://dns.example", Resolver{}, ""},
	} {
		r, err := ParseResolver(test.spec)
		if test.want.Kind == "" {
			if err == nil {
				t.Errorf("%q: got %+v, want error", test.spec, r)
			}
			continue
		}
		if err != nil {
			t.Errorf("%q: %v", test.spec, err)
			continue
		}
		if r != test.want {
			t.Errorf("%q: got %+v, want %+v", test.spec, r, test.want)
		}
		if r.String() != test.str {
			t.Errorf("%q: String() = %q, want %q", test.spec, r.String(), test.str)
		}
		again, err := ParseResolver(r.String())
		if err != nil || again != r {
			t.Errorf("%q: String() %q parses to %+v, %v", test.spec, r.String(), again, err)
		}
	}
}

func TestParseBootstrap(t *testing.T) {
	for _, test := range []struct {
		s, want string
		ok      bool
	}{
		{"", "invalid IP", true},
		{"192.0.2.1", "192.0.2.1", true},
		{"2001:db8::1", "2001:db8::1", true},
		{"[2001:db8::1]", "2001:db8::1", true},
		{"::ffff:192.0.2.1", "192.0.2.1", true},
		{"dns.example", "", false},
		{"192.0.2.1:53", "", false},
		{"fe80::1%eth0", "", false},
	} {
		addr, err := ParseBootstrap(test.s)
		if (err == nil) != test.ok || (test.ok && addr.String() != test.want) {
			t.Errorf("%q: got %v, %v", test.s, addr, err)
		}
	}
}

func TestSampleTLSFingerprint(t *testing.T) {
	for _, spec := range []string{"", DefaultTLSFingerprint, "Chrome", "chrome_133", "3*Chrome,1*Firefox,1*Safari", "none", "Android_11_OkHttp"} {
		if _, err := SampleTLSFingerprint(spec); err != nil {
			t.Errorf("%q: %v", spec, err)
		}
	}
	if id, err := SampleTLSFingerprint("none"); err != nil || id != nil {
		t.Errorf("none: got %v, %v", id, err)
	}
	for _, spec := range []string{"Netscape", "2*", "Chrome,"} {
		if _, err := SampleTLSFingerprint(spec); err == nil {
			t.Errorf("%q: no error", spec)
		}
	}
}
