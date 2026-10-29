import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Local SOCKS5 relay that authenticates to the upstream SOCKS5 proxy on behalf of its clients.
///
/// The tunnel client (dnstt or slipstream) forwards raw TCP to the server, which forwards it to
/// a SOCKS5 proxy. When that proxy requires username/password authentication (RFC 1929), local
/// clients (browsers, the tunnel verification) connect to this relay instead. The relay accepts
/// them without auth (or with any credentials), reads the client's request, performs the
/// handshake with the upstream proxy and then passes the rest of the stream through unchanged.
///
/// The upstream greeting, credentials and the client's request are sent in one write, so the
/// extra authentication step costs no additional round trip through the DNS tunnel. Some proxies
/// (microsocks, for example) handle each read as one message and drop the bytes that follow it.
/// When the proxy accepts username/password auth but the pipelined handshake does not complete,
/// the relay retries the connection step by step, and keeps doing so for later connections once
/// that works.
///
/// Mirrors android/app/src/main/kotlin/xyz/dnstt/app/Socks5AuthRelay.kt.
class Socks5AuthRelay {
  static const int _socksVersion = 0x05;
  static const int _authNone = 0x00;
  static const int _authUsername = 0x02;
  static const int _authNoAcceptable = 0xFF;
  static const int _authSubnegotiationVersion = 0x01;
  static const int _atypIpv4 = 0x01;
  static const int _atypDomain = 0x03;
  static const int _atypIpv6 = 0x04;
  static const int _replyGeneralFailure = 0x01;
  static const int _replyAddressTypeNotSupported = 0x08;
  static const Duration _connectTimeout = Duration(seconds: 10);
  // The upstream replies travel through the DNS tunnel, which can be slow
  static const Duration defaultHandshakeTimeout = Duration(seconds: 60);
  // A pipelined auth reply follows the method reply almost at once; a proxy that dropped
  // the credentials sends nothing, so stop waiting after this (or 3x the method reply time)
  static const Duration defaultPipelineGrace = Duration(seconds: 3);

  // Greeting offering only username/password auth: VER(5) NMETHODS(1) METHOD(2)
  static const List<int> _greeting = [_socksVersion, 1, _authUsername];

  final String bindHost;
  final int bindPort;
  final String upstreamHost;
  final int upstreamPort;
  final Duration handshakeTimeout;
  final Duration pipelineGrace;
  // RFC 1929 request: VER(1) ULEN UNAME PLEN PASSWD
  final Uint8List _credentials;

  ServerSocket? _server;
  final Set<Socket> _openSockets = {};

  // Cleared once the upstream proxy turns out to need a step-by-step handshake
  bool _pipelining = true;

  Socks5AuthRelay({
    required this.bindHost,
    required this.bindPort,
    required this.upstreamHost,
    required this.upstreamPort,
    required String username,
    required String password,
    this.handshakeTimeout = defaultHandshakeTimeout,
    this.pipelineGrace = defaultPipelineGrace,
  }) : _credentials = _buildCredentials(username, password);

  static Uint8List _buildCredentials(String username, String password) {
    final usernameBytes = utf8.encode(username);
    final passwordBytes = utf8.encode(password);
    if (usernameBytes.isEmpty || usernameBytes.length > 255) {
      throw ArgumentError('Invalid SOCKS5 username length');
    }
    if (passwordBytes.length > 255) {
      throw ArgumentError('Invalid SOCKS5 password length');
    }
    return Uint8List.fromList([
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
    final clientReader = _SocketReader(client);
    _UpstreamConnection? upstream;

    void closeAll() {
      clientReader.cancel();
      client.destroy();
      _openSockets.remove(client);
      final up = upstream;
      if (up != null) {
        up.reader.cancel();
        up.socket.destroy();
        _openSockets.remove(up.socket);
      }
    }

    try {
      client.setOption(SocketOption.tcpNoDelay, true);

      if (!await _negotiateWithClient(clientReader, client).timeout(handshakeTimeout)) {
        closeAll();
        return;
      }

      final request = await _readSocksMessage(clientReader).timeout(handshakeTimeout);
      if (request == null || request[0] != _socksVersion) {
        print('Socks5AuthRelay: unsupported SOCKS5 request from client');
        await _sendFailure(client, _replyAddressTypeNotSupported);
        closeAll();
        return;
      }

      final _UpstreamConnection connection;
      try {
        connection = await _connectUpstream(request);
      } on _HandshakeException catch (e) {
        if (_server != null) print('Socks5AuthRelay: upstream SOCKS5 $e');
        await _sendFailure(client, _replyGeneralFailure);
        closeAll();
        return;
      }
      upstream = connection;

      client.add(connection.reply);
      if (connection.reply[1] != 0x00) {
        // The upstream proxy refused the request; it has already told the client why
        await client.flush();
        closeAll();
        return;
      }

      var pending = 2;
      void finished() {
        pending--;
        if (pending == 0) closeAll();
      }

      clientReader.forwardTo(connection.socket, onDone: finished, onError: closeAll);
      connection.reader.forwardTo(client, onDone: finished, onError: closeAll);
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

  /// Opens an authenticated upstream connection and sends [request] on it.
  Future<_UpstreamConnection> _connectUpstream(Uint8List request) async {
    if (!_pipelining) return _handshake(request, pipelined: false);
    try {
      return await _handshake(request, pipelined: true);
    } on _HandshakeException catch (e) {
      if (!e.methodAccepted) rethrow;
      if (_server != null) {
        print('Socks5AuthRelay: pipelined SOCKS5 handshake failed ($e), retrying step by step');
      }
    }
    final connection = await _handshake(request, pipelined: false);
    if (_pipelining) {
      _pipelining = false;
      print('Socks5AuthRelay: upstream SOCKS5 proxy needs a step-by-step handshake, pipelining disabled');
    }
    return connection;
  }

  Future<_UpstreamConnection> _handshake(Uint8List request, {required bool pipelined}) async {
    Socket? socket;
    _SocketReader? reader;
    var methodAccepted = false;
    try {
      final up = await Socket.connect(upstreamHost, upstreamPort, timeout: _connectTimeout);
      socket = up;
      _openSockets.add(up);
      up.setOption(SocketOption.tcpNoDelay, true);
      final upReader = _SocketReader(up);
      reader = upReader;

      final stopwatch = Stopwatch()..start();
      up.add(pipelined ? [..._greeting, ..._credentials, ...request] : _greeting);

      final methodReply = await upReader.read(2).timeout(handshakeTimeout);
      if (methodReply[0] != _socksVersion || methodReply[1] != _authUsername) {
        throw _HandshakeException(
            'proxy did not accept username/password auth (method=${methodReply[1]})',
            methodAccepted: false);
      }
      methodAccepted = true;

      var authTimeout = handshakeTimeout;
      if (pipelined) {
        final grace = stopwatch.elapsed * 3 > pipelineGrace ? stopwatch.elapsed * 3 : pipelineGrace;
        if (grace < authTimeout) authTimeout = grace;
      } else {
        up.add(_credentials);
      }
      final authReply = await upReader.read(2).timeout(authTimeout);
      if (authReply[1] != 0x00) {
        throw _HandshakeException('authentication failed (status=${authReply[1]})',
            methodAccepted: true);
      }

      if (!pipelined) up.add(request);
      final reply = await _readSocksMessage(upReader).timeout(handshakeTimeout);
      if (reply == null || reply[0] != _socksVersion) {
        throw _HandshakeException('proxy sent an invalid reply', methodAccepted: true);
      }
      return _UpstreamConnection(up, upReader, reply);
    } catch (e) {
      reader?.cancel();
      final up = socket;
      if (up != null) {
        up.destroy();
        _openSockets.remove(up);
      }
      if (e is _HandshakeException) rethrow;
      throw _HandshakeException('handshake failed: $e', methodAccepted: methodAccepted);
    }
  }

  /// Reads a SOCKS5 request or reply (both share one layout); null for an unknown address type.
  static Future<Uint8List?> _readSocksMessage(_SocketReader reader) async {
    final header = await reader.read(4);
    final List<int> address;
    switch (header[3]) {
      case _atypIpv4:
        address = await reader.read(4);
      case _atypIpv6:
        address = await reader.read(16);
      case _atypDomain:
        final length = await reader.read(1);
        address = [...length, ...await reader.read(length[0])];
      default:
        return null;
    }
    return Uint8List.fromList([...header, ...address, ...await reader.read(2)]);
  }

  static Future<void> _sendFailure(Socket client, int reply) async {
    try {
      client.add([_socksVersion, reply, 0x00, _atypIpv4, 0, 0, 0, 0, 0, 0]);
      await client.flush();
    } catch (_) {
      // The client is gone
    }
  }
}

/// Upstream handshake failure. [methodAccepted]: the proxy had chosen username/password auth.
class _HandshakeException implements Exception {
  final String message;
  final bool methodAccepted;

  _HandshakeException(this.message, {required this.methodAccepted});

  @override
  String toString() => message;
}

class _UpstreamConnection {
  final Socket socket;
  final _SocketReader reader;
  final Uint8List reply;

  _UpstreamConnection(this.socket, this.reader, this.reply);
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
