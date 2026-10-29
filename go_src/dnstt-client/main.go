// dnstt-client is the client end of a DNS tunnel.
//
// Usage:
//
//	dnstt-client [-doh URL|-dot ADDR|-udp ADDR] [-bootstrap IP] -pubkey-file PUBKEYFILE DOMAIN LOCALADDR
//
// Examples:
//
//	dnstt-client -doh https://resolver.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
//	dnstt-client -dot resolver.example:853 -pubkey-file server.pub t.example.com 127.0.0.1:7000
//
// The program supports DNS over HTTPS (DoH), DNS over TLS (DoT), and UDP DNS.
// Use one of these options:
//
//	-doh https://resolver.example/dns-query
//	-dot resolver.example:853
//	-udp resolver.example:53
//
// With -bootstrap, the program connects to the given IP address instead of
// resolving the host name of the DoH or DoT resolver; TLS still uses the name.
//
//	-bootstrap 192.0.2.1
//
// You can give the server's public key as a file or as a hex string. Use
// "dnstt-server -gen-key" to get the public key.
//
//	-pubkey-file server.pub
//	-pubkey 0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff
//
// DOMAIN is the root of the DNS zone reserved for the tunnel. See README for
// instructions on setting it up.
//
// LOCALADDR is the TCP address that will listen for connections and forward
// them over the tunnel.
//
// In -doh and -dot modes, the program's TLS fingerprint is camouflaged with
// uTLS by default. The specific TLS fingerprint is selected randomly from a
// weighted distribution. You can set your own distribution (or specific single
// fingerprint) using the -utls option. The special value "none" disables uTLS.
//
//	-utls '3*Firefox,2*Chrome,1*iOS'
//	-utls Firefox
//	-utls none
package main

import (
	"context"
	"errors"
	"flag"
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

// How long the connection to the resolver and the Noise handshake may take.
const connectTimeout = 1 * time.Minute

// readKeyFromFile reads a key from a named file.
func readKeyFromFile(filename string) ([]byte, error) {
	f, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return noise.ReadKey(f)
}

func handle(local *net.TCPConn, sess *client.Tunnel, conv uint32) error {
	stream, err := sess.OpenStream()
	if err != nil {
		return fmt.Errorf("session %08x opening stream: %v", conv, err)
	}
	defer func() {
		log.Printf("end stream %08x:%d", conv, stream.ID())
		stream.Close()
	}()
	log.Printf("begin stream %08x:%d", conv, stream.ID())

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, err := io.Copy(stream, local)
		if err == io.EOF {
			// smux Stream.Write may return io.EOF.
			err = nil
		}
		if err != nil && !errors.Is(err, io.ErrClosedPipe) {
			log.Printf("stream %08x:%d copy stream←local: %v", conv, stream.ID(), err)
		}
		local.CloseRead()
		stream.Close()
	}()
	go func() {
		defer wg.Done()
		_, err := io.Copy(local, stream)
		if err == io.EOF {
			// smux Stream.WriteTo may return io.EOF.
			err = nil
		}
		if err != nil && !errors.Is(err, io.ErrClosedPipe) {
			log.Printf("stream %08x:%d copy local←stream: %v", conv, stream.ID(), err)
		}
		local.CloseWrite()
	}()
	wg.Wait()

	return err
}

func run(pubkey []byte, domain dns.Name, localAddr *net.TCPAddr, resolver client.Resolver, opts client.Options) error {
	ln, err := net.ListenTCP("tcp", localAddr)
	if err != nil {
		return fmt.Errorf("opening local listener: %v", err)
	}
	defer ln.Close()

	mtu, err := client.MTU(domain)
	if err != nil {
		return err
	}
	log.Printf("effective MTU %d", mtu)

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	pconn, remoteAddr, err := client.Open(ctx, resolver, opts)
	if err != nil {
		return err
	}
	tunnel, err := client.NewTunnel(ctx, pconn, remoteAddr, domain, pubkey)
	if err != nil {
		return err
	}
	conv := tunnel.Conv()
	defer func() {
		log.Printf("end session %08x", conv)
		tunnel.Close()
	}()
	log.Printf("begin session %08x", conv)

	for {
		local, err := ln.Accept()
		if err != nil {
			if err, ok := err.(net.Error); ok && err.Temporary() {
				continue
			}
			return err
		}
		go func() {
			defer local.Close()
			err := handle(local.(*net.TCPConn), tunnel, conv)
			if err != nil {
				log.Printf("handle: %v", err)
			}
		}()
	}
}

func main() {
	var dohURL string
	var dotAddr string
	var pubkeyFilename string
	var pubkeyString string
	var udpAddr string
	var bootstrap string
	var utlsDistribution string

	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), `Usage:
  %[1]s [-doh URL|-dot ADDR|-udp ADDR] [-bootstrap IP] -pubkey-file PUBKEYFILE DOMAIN LOCALADDR

Examples:
  %[1]s -doh https://resolver.example/dns-query -pubkey-file server.pub t.example.com 127.0.0.1:7000
  %[1]s -dot resolver.example:853 -pubkey-file server.pub t.example.com 127.0.0.1:7000

`, os.Args[0])
		flag.PrintDefaults()
		labels := append([]string{"none"}, client.TLSFingerprintLabels()...)
		fmt.Fprintf(flag.CommandLine.Output(), `
Known TLS fingerprints for -utls are:
`)
		i := 0
		for i < len(labels) {
			var line strings.Builder
			fmt.Fprintf(&line, "  %s", labels[i])
			w := 2 + len(labels[i])
			i++
			for i < len(labels) && w+1+len(labels[i]) <= 72 {
				fmt.Fprintf(&line, " %s", labels[i])
				w += 1 + len(labels[i])
				i++
			}
			fmt.Fprintln(flag.CommandLine.Output(), line.String())
		}
	}
	flag.StringVar(&dohURL, "doh", "", "URL of DoH resolver")
	flag.StringVar(&dotAddr, "dot", "", "address of DoT resolver")
	flag.StringVar(&pubkeyString, "pubkey", "", fmt.Sprintf("server public key (%d hex digits)", noise.KeyLen*2))
	flag.StringVar(&pubkeyFilename, "pubkey-file", "", "read server public key from file")
	flag.StringVar(&udpAddr, "udp", "", "address of UDP DNS resolver")
	flag.StringVar(&bootstrap, "bootstrap", "", "IP address to connect to instead of resolving the DoH or DoT host name")
	flag.StringVar(&utlsDistribution, "utls",
		"4*random,3*Firefox_120,1*Firefox_105,3*Chrome_120,1*Chrome_102,1*iOS_14,1*iOS_13",
		"choose TLS fingerprint from weighted distribution")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC)

	if flag.NArg() != 2 {
		flag.Usage()
		os.Exit(1)
	}
	domain, err := dns.ParseName(flag.Arg(0))
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid domain %+q: %v\n", flag.Arg(0), err)
		os.Exit(1)
	}
	localAddr, err := net.ResolveTCPAddr("tcp", flag.Arg(1))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var pubkey []byte
	if pubkeyFilename != "" && pubkeyString != "" {
		fmt.Fprintf(os.Stderr, "only one of -pubkey and -pubkey-file may be used\n")
		os.Exit(1)
	} else if pubkeyFilename != "" {
		var err error
		pubkey, err = readKeyFromFile(pubkeyFilename)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cannot read pubkey from file: %v\n", err)
			os.Exit(1)
		}
	} else if pubkeyString != "" {
		var err error
		pubkey, err = noise.DecodeKey(pubkeyString)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pubkey format error: %v\n", err)
			os.Exit(1)
		}
	}
	if len(pubkey) == 0 {
		fmt.Fprintf(os.Stderr, "the -pubkey or -pubkey-file option is required\n")
		os.Exit(1)
	}

	// Check the distribution here, so that a mistake is reported before
	// connecting. client.Open samples from it.
	if _, err := client.SampleTLSFingerprint(utlsDistribution); err != nil {
		fmt.Fprintf(os.Stderr, "parsing -utls: %v\n", err)
		os.Exit(1)
	}
	if _, err := client.ParseBootstrap(bootstrap); err != nil {
		fmt.Fprintf(os.Stderr, "parsing -bootstrap: %v\n", err)
		os.Exit(1)
	}

	// Select one and only one of the remote resolver address options.
	var spec string
	for _, opt := range []struct {
		value, prefix string
	}{
		{dohURL, ""},
		{dotAddr, "tls://"},
		{udpAddr, "udp://"},
	} {
		if opt.value == "" {
			continue
		}
		if spec != "" {
			fmt.Fprintf(os.Stderr, "only one of -doh, -dot, and -udp may be given\n")
			os.Exit(1)
		}
		spec = opt.prefix + opt.value
	}
	if spec == "" {
		fmt.Fprintf(os.Stderr, "one of -doh, -dot, or -udp is required\n")
		os.Exit(1)
	}
	resolver, err := client.ParseResolver(spec)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if dohURL != "" && resolver.Kind != client.KindDoH {
		fmt.Fprintf(os.Stderr, "-doh needs an https:// URL\n")
		os.Exit(1)
	}

	opts := client.Options{Bootstrap: bootstrap, TLSFingerprint: utlsDistribution}
	err = run(pubkey, domain, localAddr, resolver, opts)
	if err != nil {
		log.Fatal(err)
	}
}
