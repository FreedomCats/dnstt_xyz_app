import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dnstt_xyz_app/services/socks5_auth_relay.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal SOCKS5 server that requires username/password auth and echoes data after CONNECT.
class FakeUpstream {
  final String username;
  final String password;
  late final ServerSocket server;
  final authAttempts = <List<String>>[];
  final connectTargets = <String>[];

  FakeUpstream(this.username, this.password);

  int get port => server.port;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> close() => server.close();

  Future<void> _handle(Socket socket) async {
    final reader = _Reader(socket);
    try {
      final greeting = await reader.read(2);
      final methods = await reader.read(greeting[1]);
      if (!methods.contains(0x02)) {
        socket.add([0x05, 0xFF]);
        await socket.close();
        return;
      }
      socket.add([0x05, 0x02]);

      await reader.read(1);
      final user = utf8.decode(await reader.read((await reader.read(1))[0]));
      final pass = utf8.decode(await reader.read((await reader.read(1))[0]));
      authAttempts.add([user, pass]);
      if (user != username || pass != password) {
        socket.add([0x01, 0x01]);
        await socket.close();
        return;
      }
      socket.add([0x01, 0x00]);

      final request = await reader.read(4);
      final host = utf8.decode(await reader.read((await reader.read(1))[0]));
      final portBytes = await reader.read(2);
      connectTargets.add('$host:${portBytes[0] << 8 | portBytes[1]}');
      expect(request.sublist(0, 4), [0x05, 0x01, 0x00, 0x03]);
      socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

      // Echo everything else
      reader.onData = socket.add;
      final rest = reader.takeAll();
      if (rest.isNotEmpty) socket.add(rest);
    } catch (_) {
      socket.destroy();
    }
  }
}

/// Buffers socket data so tests can read exact byte counts.
class _Reader {
  final _buffer = BytesBuilder();
  Completer<void>? _waiter;
  bool _done = false;
  void Function(Uint8List)? onData;

  _Reader(Socket socket) {
    socket.listen((data) {
      if (onData != null) {
        onData!(data);
        return;
      }
      _buffer.add(data);
      _waiter?.complete();
      _waiter = null;
    }, onDone: _finish, onError: (_) => _finish(), cancelOnError: true);
  }

  void _finish() {
    _done = true;
    _waiter?.complete();
    _waiter = null;
  }

  Future<Uint8List> read(int n) async {
    while (_buffer.length < n) {
      if (_done) throw const SocketException('closed');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final bytes = _buffer.takeBytes();
    _buffer.add(bytes.sublist(n));
    return bytes.sublist(0, n);
  }

  Uint8List takeAll() => _buffer.takeBytes();

  Future<bool> get closed async {
    while (!_done) {
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    return true;
  }
}

List<int> connectRequest(String host, int port) =>
    [0x05, 0x01, 0x00, 0x03, host.length, ...utf8.encode(host), port >> 8, port & 0xFF];

void main() {
  late FakeUpstream upstream;
  late Socks5AuthRelay relay;
  late int relayPort;

  Future<void> startRelay(String username, String password) async {
    relayPort = await Socks5AuthRelay.findFreePort();
    relay = Socks5AuthRelay(
      bindHost: '127.0.0.1',
      bindPort: relayPort,
      upstreamHost: '127.0.0.1',
      upstreamPort: upstream.port,
      username: username,
      password: password,
    );
    expect(await relay.start(), isTrue);
  }

  setUp(() async {
    upstream = FakeUpstream('user', 'pässword');
    await upstream.start();
  });

  tearDown(() async {
    await relay.stop();
    await upstream.close();
  });

  test('client without auth is authenticated upstream and data passes through', () async {
    await startRelay('user', 'pässword');

    final client = await Socket.connect('127.0.0.1', relayPort);
    final reader = _Reader(client);

    client.add([0x05, 0x01, 0x00]);
    expect(await reader.read(2), [0x05, 0x00]);

    client.add(connectRequest('example.com', 443));
    expect((await reader.read(10)).sublist(0, 2), [0x05, 0x00]);

    client.add(utf8.encode('ping'));
    expect(utf8.decode(await reader.read(4)), 'ping');

    expect(upstream.authAttempts, [
      ['user', 'pässword']
    ]);
    expect(upstream.connectTargets, ['example.com:443']);
    client.destroy();
  });

  test('request pipelined with the greeting is forwarded', () async {
    await startRelay('user', 'pässword');

    final client = await Socket.connect('127.0.0.1', relayPort);
    final reader = _Reader(client);

    client.add([0x05, 0x01, 0x00, ...connectRequest('example.com', 80), ...utf8.encode('data')]);
    expect(await reader.read(2), [0x05, 0x00]);
    expect((await reader.read(10)).sublist(0, 2), [0x05, 0x00]);
    expect(utf8.decode(await reader.read(4)), 'data');
    client.destroy();
  });

  test('client offering only username/password auth is accepted with any credentials', () async {
    await startRelay('user', 'pässword');

    final client = await Socket.connect('127.0.0.1', relayPort);
    final reader = _Reader(client);

    client.add([0x05, 0x01, 0x02]);
    expect(await reader.read(2), [0x05, 0x02]);
    client.add([0x01, 1, ...utf8.encode('x'), 1, ...utf8.encode('y')]);
    expect(await reader.read(2), [0x01, 0x00]);

    client.add(connectRequest('example.com', 443));
    expect((await reader.read(10)).sublist(0, 2), [0x05, 0x00]);
    expect(upstream.authAttempts, [
      ['user', 'pässword']
    ]);
    client.destroy();
  });

  test('wrong upstream credentials close the client connection', () async {
    await startRelay('user', 'wrong');

    final client = await Socket.connect('127.0.0.1', relayPort);
    // The relay resets the connection, which fails pending writes
    client.done.catchError((_) => client);
    final reader = _Reader(client);

    client.add([0x05, 0x01, 0x00]);
    expect(await reader.read(2), [0x05, 0x00]);
    client.add(connectRequest('example.com', 443));

    expect(await reader.closed.timeout(const Duration(seconds: 5)), isTrue);
    expect(upstream.connectTargets, isEmpty);
    client.destroy();
  });

  test('stop closes the listening socket', () async {
    await startRelay('user', 'pässword');
    await relay.stop();
    await expectLater(Socket.connect('127.0.0.1', relayPort), throwsA(isA<SocketException>()));
  });
}
