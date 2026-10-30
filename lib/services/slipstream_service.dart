import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:socks5_proxy/socks_client.dart';
import '../models/resolver_spec.dart';
import 'dnstt_ffi_service.dart';

/// Manages the slipstream-client binary as a subprocess on desktop platforms.
/// Slipstream uses QUIC-over-DNS and is significantly faster than DNSTT.
///
/// The slipstream-client binary provides a local SOCKS5 proxy, same as DNSTT.
/// DNS resolvers come from the DNS server list (same as DNSTT).
///
/// slipstream-client sends plain UDP only. For a DoH/DoT resolver it gets a
/// local bridge from libdnstt (`127.0.0.1:<port>`) that forwards its queries
/// and lives as long as the subprocess.
class SlipstreamService {
  static SlipstreamService? _instance;
  static SlipstreamService get instance => _instance ??= SlipstreamService._();

  /// The `--resolver` value for a UDP resolver spec (`host:port`), or null
  /// for DoH/DoT and invalid specs.
  static String? resolverArg(String dnsServer) {
    final spec = ResolverSpec.tryParse(dnsServer);
    return spec?.kind == ResolverKind.udp ? spec!.address : null;
  }

  /// The `--resolver` value for [dnsServer] and the port of the bridge
  /// started for it (null for a UDP resolver). Throws [_ResolverError] for an
  /// invalid spec or when the bridge cannot start.
  static Future<({String resolver, int? bridgePort})> _resolverFor(
    String dnsServer,
    String? dnsBootstrap,
    String tlsFingerprint,
  ) async {
    final spec = ResolverSpec.tryParse(dnsServer);
    if (spec == null) throw _ResolverError('Invalid DNS server: $dnsServer');
    if (spec.kind == ResolverKind.udp) return (resolver: spec.address, bridgePort: null);

    // dnstt_bridge_start waits for the connection to the resolver: keep it
    // off the UI isolate.
    final (port, error) = await Isolate.run(() {
      final ffi = DnsttFfiService.instance;
      if (!ffi.isLoaded) ffi.load();
      final port = ffi.startBridge(dnsServer: dnsServer, dnsBootstrap: dnsBootstrap, tlsFingerprint: tlsFingerprint);
      return (port, port == null ? ffi.getLastError() : '');
    });
    if (port == null) throw _ResolverError(error);
    print('SlipstreamService: DNS bridge to $dnsServer on 127.0.0.1:$port');
    return (resolver: '127.0.0.1:$port', bridgePort: port);
  }

  static void _stopBridge(int? port) {
    if (port == null) return;
    try {
      final ffi = DnsttFfiService.instance;
      if (!ffi.isLoaded) ffi.load();
      ffi.stopBridge(port);
    } catch (e) {
      print('SlipstreamService: failed to stop DNS bridge: $e');
    }
  }

  SlipstreamService._();

  Process? _process;
  int? _bridgePort;
  String? _lastError;
  bool _isRunning = false;

  bool get isRunning => _isRunning;
  String? get lastError => _lastError;

  /// Find the slipstream-client binary for the current platform.
  String? _findBinaryPath() {
    final executablePath = Platform.resolvedExecutable;
    print('SlipstreamService: resolvedExecutable = $executablePath');
    final List<String> paths;

    if (Platform.isMacOS) {
      final bundlePath = executablePath.contains('/Contents/MacOS/')
          ? executablePath.substring(0, executablePath.indexOf('/Contents/MacOS/'))
          : executablePath;
      final contentsPath = '$bundlePath/Contents';
      paths = [
        '$contentsPath/Frameworks/slipstream-client',
        '$contentsPath/MacOS/slipstream-client',
        '$contentsPath/Resources/slipstream-client',
        '${Directory.current.path}/macos/Runner/Libraries/slipstream-client',
        '${Directory.current.path}/slipstream-client',
        'slipstream-client',
      ];
    } else if (Platform.isWindows) {
      final executableDir = File(executablePath).parent.path;
      paths = [
        '$executableDir\\slipstream-client.exe',
        '${Directory.current.path}\\slipstream-client.exe',
        'slipstream-client.exe',
      ];
    } else if (Platform.isLinux) {
      final executableDir = File(executablePath).parent.path;
      paths = [
        '$executableDir/lib/slipstream-client',
        '$executableDir/slipstream-client',
        '${Directory.current.path}/slipstream-client',
        'slipstream-client',
      ];
    } else {
      return null;
    }

    for (final path in paths) {
      final exists = File(path).existsSync();
      print('SlipstreamService: checking $path -> $exists');
      if (exists) {
        return path;
      }
    }

    // Try PATH lookup as fallback
    print('SlipstreamService: binary not found in known paths, falling back to PATH lookup');
    return 'slipstream-client';
  }

  /// Start the slipstream-client subprocess.
  ///
  /// [domain] - Tunnel domain (e.g., "tunnel.example.com")
  /// [dnsServerAddr] - DNS server (resolver spec) used as resolver
  /// [dnsBootstrap], [tlsFingerprint] - how to reach a DoH/DoT resolver
  /// [listenPort] - Local SOCKS5 proxy port (default 7000)
  /// [congestionControl] - "bbr" or "dcubic" (default "dcubic")
  /// [keepAliveInterval] - Keep-alive interval in ms (default 400)
  /// [gso] - Enable Generic Segmentation Offload (default false)
  Future<bool> startClient({
    required String domain,
    required String dnsServerAddr,
    String? dnsBootstrap,
    String tlsFingerprint = '',
    int listenPort = 7000,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
  }) async {
    if (_isRunning) {
      _lastError = 'Client already running';
      return false;
    }

    final binaryPath = _findBinaryPath();
    if (binaryPath == null) {
      _lastError = 'slipstream-client binary not found';
      return false;
    }

    _lastError = null;

    try {
      final (:resolver, :bridgePort) = await _resolverFor(dnsServerAddr, dnsBootstrap, tlsFingerprint);
      _bridgePort = bridgePort;
      final args = [
        // Without it slipstream-client listens on all interfaces: an open
        // proxy for the local network.
        '--tcp-listen-host', '127.0.0.1',
        '--tcp-listen-port', listenPort.toString(),
        '--domain', domain,
        '--resolver', resolver,
        '--congestion-control', congestionControl,
        '--keep-alive-interval', keepAliveInterval.toString(),
      ];

      if (gso) {
        args.add('--gso');
      }

      print('Starting slipstream-client: $binaryPath ${args.join(' ')}');

      _process = await Process.start(binaryPath, args);

      // Monitor stderr for errors
      _process!.stderr.listen((data) {
        final output = String.fromCharCodes(data);
        print('slipstream-client stderr: $output');
        if (output.toLowerCase().contains('error') ||
            output.toLowerCase().contains('fatal')) {
          _lastError = output.trim();
        }
      });

      _process!.stdout.listen((data) {
        print('slipstream-client stdout: ${String.fromCharCodes(data)}');
      });

      // Monitor process exit
      _process!.exitCode.then((code) {
        print('slipstream-client exited with code: $code');
        _isRunning = false;
        if (code != 0) {
          _lastError = 'slipstream-client exited with code $code';
        }
      });

      // Wait for the proxy to be ready
      await Future.delayed(const Duration(seconds: 1));

      // Verify the process is still running
      final exitCodeFuture = _process!.exitCode;
      final result = await Future.any([
        exitCodeFuture.then((code) => 'exited:$code'),
        Future.delayed(const Duration(milliseconds: 500), () => 'running'),
      ]);

      if (result.startsWith('exited')) {
        final code = result.split(':')[1];
        _lastError = 'slipstream-client failed to start (exit code: $code)';
        _isRunning = false;
        _process = null;
        _stopBridge(_bridgePort);
        _bridgePort = null;
        return false;
      }

      _isRunning = true;
      return true;
    } catch (e) {
      _lastError = e.toString();
      _isRunning = false;
      _process?.kill();
      _process = null;
      _stopBridge(_bridgePort);
      _bridgePort = null;
      return false;
    }
  }

  /// Stop the running slipstream-client subprocess and its DNS bridge.
  Future<void> stopClient() async {
    if (_process != null) {
      _process!.kill();
      _process = null;
    }
    _stopBridge(_bridgePort);
    _bridgePort = null;
    _isRunning = false;
  }

  /// Counter for assigning unique test ports to avoid conflicts
  static int _nextTestPort = 18500;

  /// Test a slipstream server by spawning a temporary slipstream-client,
  /// making an HTTP request through the SOCKS5 proxy, and returning the latency.
  ///
  /// Returns latency in milliseconds on success, -1 on failure.
  Future<int> testServer({
    required String domain,
    required String dnsServerAddr,
    String? dnsBootstrap,
    String tlsFingerprint = '',
    String testUrl = 'https://api.ipify.org?format=json',
    int timeoutMs = 15000,
    String congestionControl = 'dcubic',
    int keepAliveInterval = 400,
    bool gso = false,
    String? socksUsername,
    String? socksPassword,
  }) async {
    final binaryPath = _findBinaryPath();
    if (binaryPath == null) {
      print('SlipstreamService.testServer: binary not found');
      return -1;
    }

    // Use a unique port for each test to avoid port conflicts
    final listenPort = _nextTestPort++;
    if (_nextTestPort > 19500) _nextTestPort = 18500;

    Process? testProcess;
    int? bridgePort;
    try {
      final resolverFor = await _resolverFor(dnsServerAddr, dnsBootstrap, tlsFingerprint);
      final resolver = resolverFor.resolver;
      bridgePort = resolverFor.bridgePort;
      final args = [
        '--tcp-listen-host', '127.0.0.1',
        '--tcp-listen-port', listenPort.toString(),
        '--domain', domain,
        '--resolver', resolver,
        '--congestion-control', congestionControl,
        '--keep-alive-interval', keepAliveInterval.toString(),
      ];

      if (gso) {
        args.add('--gso');
      }

      print('SlipstreamService.testServer: starting on port $listenPort for $dnsServerAddr');
      testProcess = await Process.start(binaryPath, args);

      // Capture stderr for debugging
      final stderrBuffer = StringBuffer();
      testProcess.stderr.listen((data) {
        stderrBuffer.write(String.fromCharCodes(data));
      });

      // Wait for the proxy to be ready
      await Future.delayed(const Duration(seconds: 2));

      // Check if process is still running
      final checkResult = await Future.any([
        testProcess.exitCode.then((code) => 'exited:$code'),
        Future.delayed(const Duration(milliseconds: 300), () => 'running'),
      ]);

      if (checkResult.startsWith('exited')) {
        final stderr = stderrBuffer.toString();
        print('SlipstreamService.testServer: process exited early for $dnsServerAddr: $stderr');
        return -1;
      }

      // Make HTTP/HTTPS request through SOCKS5 proxy
      final stopwatch = Stopwatch()..start();
      final client = HttpClient();
      client.connectionTimeout = Duration(milliseconds: timeoutMs);
      try {
        SocksTCPClient.assignToHttpClientWithSecureOptions(client, [
          ProxySettings(
            InternetAddress('127.0.0.1'),
            listenPort,
            username: socksUsername != null && socksUsername.isNotEmpty ? socksUsername : null,
            password: socksUsername != null && socksUsername.isNotEmpty ? (socksPassword ?? '') : null,
          ),
        ]);
        final request = await client.getUrl(Uri.parse(testUrl))
            .timeout(Duration(milliseconds: timeoutMs));
        request.headers.set('Connection', 'close');
        final response = await request.close()
            .timeout(Duration(milliseconds: timeoutMs));
        stopwatch.stop();
        client.close(force: true);

        if (response.statusCode >= 200 && response.statusCode < 400) {
          print('SlipstreamService.testServer: SUCCESS for $dnsServerAddr (${stopwatch.elapsedMilliseconds}ms)');
          return stopwatch.elapsedMilliseconds;
        }
        print('SlipstreamService.testServer: HTTP ${response.statusCode} for $dnsServerAddr');
        return -1;
      } on TimeoutException {
        client.close(force: true);
        print('SlipstreamService.testServer: timeout for $dnsServerAddr');
        return -1;
      } catch (e) {
        client.close(force: true);
        print('SlipstreamService.testServer: error for $dnsServerAddr: $e');
        return -1;
      }
    } catch (e) {
      print('SlipstreamService.testServer: process error for $dnsServerAddr: $e');
      return -1;
    } finally {
      if (testProcess != null) {
        testProcess.kill();
        // Wait for process to actually exit so the port is released
        await testProcess.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            testProcess!.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      }
      _stopBridge(bridgePort);
    }
  }
}

/// A DNS server slipstream-client cannot use; the message is for the user.
class _ResolverError implements Exception {
  final String message;
  _ResolverError(this.message);

  @override
  String toString() => message;
}
