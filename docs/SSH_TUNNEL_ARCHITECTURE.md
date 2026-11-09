# SSH Tunnel over DNSTT Architecture

This document describes how the SSH tunnel mode works in the DNSTT app.

## Overview

The SSH tunnel mode provides an alternative to the standard SOCKS5 proxy mode. Instead of DNSTT directly providing a SOCKS5 proxy, the app establishes an SSH connection through the DNSTT tunnel and uses SSH dynamic port forwarding to create a SOCKS5 proxy.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Android Phone                       │
│                                                                 │
│  User Apps ──► SOCKS5 Proxy (127.0.0.1:1080)                   │
│                      │                                          │
│                      ▼                                          │
│              SSH Client (JSch in app)                           │
│              Uses: sshUsername, sshPassword                     │
│                      │                                          │
│                      ▼                                          │
│              DNSTT Client (127.0.0.1:7001)                      │
│              Uses: publicKey, tunnelDomain                      │
│                      │                                          │
└──────────────────────┼──────────────────────────────────────────┘
                       │ DNS queries
                       ▼
              ┌─────────────────┐
              │   DNS Resolver   │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  DNSTT Server   │
              │  (your server)  │
              │       │         │
              │       ▼         │
              │  SSH Server:22  │
              └────────┬────────┘
                       │
                       ▼
                   Internet
```

## Data Flow

1. **User Apps** connect to the local SOCKS5 proxy at `127.0.0.1:1080`
2. **SSH Client (JSch)** receives SOCKS5 requests and forwards them through SSH dynamic port forwarding
3. **DNSTT Client** tunnels the SSH traffic over DNS queries to the tunnel domain
4. **DNS Resolver** forwards queries to the authoritative DNS server
5. **DNSTT Server** decodes DNS traffic and forwards to the local SSH server
6. **SSH Server** authenticates the connection and forwards traffic to the internet

## Configuration

A single config contains both DNSTT and SSH settings:

| Field | Description |
|-------|-------------|
| `publicKey` | DNSTT server's 64-character hex public key |
| `tunnelDomain` | DNSTT tunnel domain (e.g., `t.example.com`) |
| `tunnelType` | Set to `ssh` for SSH tunnel mode |
| `sshUsername` | SSH username for authentication |
| `sshPassword` | SSH password (optional if using key) |
| `sshPrivateKey` | SSH private key in OpenSSH format (optional) |
| `sshHostKeyFingerprint` | SHA-256 host key fingerprint (`SHA256:` + unpadded base64, the value `ssh-keygen -lf` prints); empty means trust on first use. Android only. |

## Host key verification

On Android the app verifies the SSH host key instead of accepting any key. The
first connection to a server remembers its key fingerprint in the config
(`sshHostKeyFingerprint`); later connections accept the same key and refuse a
different one. A refusal names both fingerprints and asks the user to forget
the key in the config editor if the server really changed. There is no accept
dialog: a changed key is refused, and the config editor's "Forget host key"
action clears the field so the next connection accepts the new key.

The check is implemented by `SshHostKeyRepository.kt`, a JSch
`HostKeyRepository` wired into `SshTunnelClient`. The fingerprint format is the
one `ssh-keygen -lf` prints, so a user can compare it with the server's key.

This release covers Android only: the desktop SSH path starts the system `ssh`
command with `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null` and
does not use the config fingerprint. Desktop host key verification is a
separate later change.

## Advantages of SSH Tunnel Mode

- **Authentication**: SSH provides user authentication, adding a layer of access control
- **Encryption**: SSH provides end-to-end encryption between the app and SSH server
- **Flexibility**: Can use password or key-based authentication
- **Compatibility**: Works with existing SSH infrastructure

## Implementation Details

- **Android**: Uses [JSch](https://github.com/mwiede/jsch) library for SSH client functionality
- **DNSTT**: Creates TCP tunnel on `127.0.0.1:7001` that forwards to SSH server port 22
- **SSH**: Connects through the DNSTT tunnel and implements dynamic port forwarding (equivalent to `ssh -D`)
- **SOCKS5**: The local proxy listens on `127.0.0.1:1080` (`SshTunnelClient.SOCKS5_PROXY_PORT`)
- **Host key**: `SshHostKeyRepository.kt` (JSch `HostKeyRepository`) implements
  trust on first use as described above
- **SSH VPN mode**: `MainActivity` starts `DnsttVpnService` with
  `SshTunnelClient.SOCKS5_PROXY_PORT`; the service starts tun2socks on that
  port and starts no tunnel of its own
- **Desktop**: runs the system `ssh` command; it does not verify host keys in
  this release (see "Host key verification")
