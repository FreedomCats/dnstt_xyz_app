import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Local SOCKS5 relay that authenticates to the upstream SOCKS5 proxy on behalf of its clients.
///
/// The tunnel client (dnstt or slipstream) forwards raw TCP to the server, which forwards it to
/// a SOCKS5 proxy. When that proxy requires username/password authentication (RFC 1929), local
/// clients (browsers, the tunnel verification) connect to this relay instead. The relay accepts
/// them without auth (or with any credentials), performs the username/password sub-negotiation
/// with the upstream proxy and then passes the rest of the stream through unchanged.
///
/// The upstream greeting and credentials are sent together right after accepting a client, and
/// the client's request is forwarded without waiting for the upstream auth reply, so the extra
/// authentication step costs no additional round trip through the DNS tunnel.
///
/// Mirrors android/app/src/main/kotlin/xyz/dnstt/app/Socks5AuthRelay.kt.
class Socks5AuthRelay {
  static const int _socksVersion = 0x05;
  static const int _authNone = 0x00;
  static const int _authUsername = 0x02;
  static const int _authNoAcceptable = 0xFF;
  static const int _authSubnegotiationVersion = 0x01;
  static const Duration _connectTimeout = Duration(seconds: 10);
  // The upstream auth reply travels through the DNS tunnel, which can be slow
  static const Duration _handshakeTimeout = Duration(seconds: 60);

  final String bindHost;
  final int bindPort;
  final String upstreamHost;
  final int upstreamPort;
  final Uint8List _authRequest;

  ServerSocket? _server;
  final Set<Socket> _openSockets = {};

  Socks5AuthRelay({
    required this.bindHost,
    required this.bindPort,
    required this.upstreamHost,
    required this.upstreamPort,
    required String username,
    required String password,
  }) : _authRequest = _buildAuthRequest(username, password);

  static Uint8List _buildAuthRequest(String username, String password) {
    final usernameBytes = utf8.encode(username);
    final passwordBytes = utf8.encode(password);
    if (usernameBytes.isEmpty || usernameBytes.length > 255) {
      throw ArgumentError('Invalid SOCKS5 username length');
    }
    if (passwordBytes.length > 255) {
      throw ArgumentError('Invalid SOCKS5 password length');
    }
    // Greeting offering only username/password auth, followed by the RFC 1929 request:
    // VER(5) NMETHODS(1) METHOD(2) | VER(1) ULEN UNAME PLEN PASSWD
    return Uint8List.fromList([
      _socksVersion, 1, _authUsername,
      _authSubnegotiationVersion, usernameBytes.length, ...usernameBytes,
      passwordBytes.length, ...passwordBytes,
    ]);
  }

  /// Finds a free TCP port on localhost for the tunnel client to listen on behind the relay.
  static Future<int> findFreePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  bool get isRunning => _server != null;

  Future<bool> start() async {
    if (_server != null) return true;
    try {
      final server = await ServerSocket.bind(bindHost, bindPort, shared: false);
      _server = server;
      server.listen(_handleClient, onError: (e) => print('Socks5AuthRelay: accept error: $e'));
      print('Socks5AuthRelay: listening on $bindHost:$bindPort, upstream $upstreamHost:$upstreamPort');
      return true;
    } catch (e) {
      print('Socks5AuthRelay: failed to start on $bindHost:$bindPort: $e');
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close();
    for (final socket in _openSockets.toList()) {
      socket.destroy();
    }
    _openSockets.clear();
  }

  Future<void> _handleClient(Socket client) async {
    _openSockets.add(client);
    Socket? upstream;
    final clientReader = _SocketReader(client);
    _SocketReader? upstreamReader;

    void closeAll() {
      clientReader.cancel();
      upstreamReader?.cancel();
      client.destroy();
      upstream?.destroy();
      _openSockets.remove(client);
      if (upstream != null) _openSockets.remove(upstream);
    }

    try {
      client.setOption(SocketOption.tcpNoDelay, true);

      final up = await Socket.connect(upstreamHost, upstreamPort, timeout: _connectTimeout);
      upstream = up;
      _openSockets.add(up);
      up.setOption(SocketOption.tcpNoDelay, true);
      final upReader = _SocketReader(up);
      upstreamReader = upReader;

      // Start upstream authentication while negotiating with the local client
      up.add(_authRequest);

      if (!await _negotiateWithClient(clientReader, client).timeout(_handshakeTimeout)) {
        closeAll();
        return;
      }

      // Forward the client's request (and any data) right away
      var pending = 2;
      void finished() {
        pending--;
        if (pending == 0) closeAll();
      }

      clientReader.forwardTo(up, onDone: finished, onError: closeAll);

      if (!await _readUpstreamAuthReply(upReader).timeout(_handshakeTimeout)) {
        closeAll();
        return;
      }

      upReader.forwardTo(client, onDone: finished, onError: closeAll);
    } catch (e) {
      if (_server != null) print('Socks5AuthRelay: connection failed: $e');
      closeAll();
    }
  }

  /// Accepts the local client without auth, or with any credentials if it only offers username/password.
  Future<bool> _negotiateWithClient(_SocketReader reader, Socket client) async {
    final header = await reader.read(2);
    if (header[0] != _socksVersion) {
      print('Socks5AuthRelay: unsupported SOCKS version from client: ${header[0]}');
      return false;
    }
    final methods = await reader.read(header[1]);

    if (methods.contains(_authNone)) {
      client.add([_socksVersion, _authNone]);
    } else if (methods.contains(_authUsername)) {
      client.add([_socksVersion, _authUsername]);
      // Read and discard the client's credentials: the relay uses the configured ones
      await reader.read(1);
      await reader.read((await reader.read(1))[0]);
      await reader.read((await reader.read(1))[0]);
      client.add([_authSubnegotiationVersion, 0x00]);
    } else {
      client.add([_socksVersion, _authNoAcceptable]);
      await client.flush();
      return false;
    }
    return true;
  }

  Future<bool> _readUpstreamAuthReply(_SocketReader reader) async {
    final methodReply = await reader.read(2);
    if (methodReply[0] != _socksVersion || methodReply[1] != _authUsername) {
      print('Socks5AuthRelay: upstream SOCKS5 proxy did not accept username/password auth '
          '(method=${methodReply[1]})');
      return false;
    }
    final authReply = await reader.read(2);
    if (authReply[1] != 0x00) {
      print('Socks5AuthRelay: upstream SOCKS5 authentication failed (status=${authReply[1]})');
      return false;
    }
    return true;
  }
}

/// Reads exact byte counts from a socket during the handshake, then forwards the rest of the
/// stream (including anything already buffered) to another socket.
class _SocketReader {
  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<void>? _waiter;
  bool _done = false;
  Object? _error;

  Socket? _target;
  void Function()? _onDone;
  void Function()? _onError;

  _SocketReader(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onDone: () {
        _done = true;
        if (_target != null) {
          _finishForwarding();
        } else {
          _wake();
        }
      },
      onError: (Object e) {
        _error = e;
        if (_target != null) {
          _onError?.call();
        } else {
          _wake();
        }
      },
      cancelOnError: true,
    );
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  void _onData(Uint8List data) {
    final target = _target;
    if (target == null) {
      _buffer.add(data);
      _wake();
      return;
    }
    // Apply backpressure: pause reading until the target socket has accepted the data
    _subscription.pause();
    target.add(data);
    target.flush().then((_) => _subscription.resume(), onError: (_) => _onError?.call());
  }

  Future<Uint8List> read(int length) async {
    while (_buffer.length < length) {
      if (_error != null) throw _error!;
      if (_done) throw const SocketException('Unexpected end of stream');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final bytes = _buffer.takeBytes();
    if (bytes.length > length) {
      _buffer.add(Uint8List.sublistView(bytes, length));
    }
    return Uint8List.sublistView(bytes, 0, length);
  }

  /// Forwards buffered and future data to [target]. On EOF, half-closes [target] and calls [onDone].
  void forwardTo(Socket target, {required void Function() onDone, required void Function() onError}) {
    _target = target;
    _onDone = onDone;
    _onError = onError;
    if (_buffer.isNotEmpty) {
      target.add(_buffer.takeBytes());
    }
    if (_error != null) {
      onError();
    } else if (_done) {
      _finishForwarding();
    }
  }

  void _finishForwarding() {
    // Propagate EOF so half-closed connections keep working
    final target = _target!;
    target.flush().then((_) {
      target.close().catchError((_) => target);
    }).catchError((_) => null).whenComplete(() => _onDone?.call());
  }

  void cancel() {
    _subscription.cancel();
  }
}
