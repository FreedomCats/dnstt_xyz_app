import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import '../models/resolver_spec.dart';

/// FFI bindings for the dnstt Go library
/// Used on desktop platforms (macOS, Windows, Linux)
class DnsttFfiService {
  static DnsttFfiService? _instance;
  static DnsttFfiService get instance => _instance ??= DnsttFfiService._();

  DynamicLibrary? _lib;
  bool _loaded = false;
  bool _loading = false;

  // FFI function types
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>) _createClient;
  late final int Function() _start;
  late final int Function() _stop;
  late final bool Function() _isRunning;
  late final Pointer<Utf8> Function() _getLastError;
  late final void Function(Pointer<Utf8>) _freeString;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int) _testDnsServer;
  // Optional: missing in libraries built before upstream SOCKS5 auth support
  int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>)?
      _testDnsServerAuth;
  // Optional: missing in libraries built before DoH/DoT support
  int Function(Pointer<Utf8>)? _setBootstrap;
  int Function(Pointer<Utf8>)? _setTlsFingerprint;
  int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int,
      Pointer<Utf8>, Pointer<Utf8>)? _testDnsServerEx;

  /// Error found on the Dart side, reported by [getLastError] instead of the
  /// library's.
  String? _localError;

  static const _tooOldForDoh = 'dnstt library too old for DoH/DoT servers, rebuild libdnstt';

  DnsttFfiService._();

  bool get isLoaded => _loaded;

  /// Load the native library
  void load() {
    if (_loaded) return;
    if (_loading) return; // Prevent reentry

    _loading = true;
    try {
      if (Platform.isMacOS) {
        // Get the app bundle path
        final executablePath = Platform.resolvedExecutable;
        final bundlePath = executablePath.contains('/Contents/MacOS/')
            ? executablePath.substring(0, executablePath.indexOf('/Contents/MacOS/'))
            : executablePath;
        final contentsPath = '$bundlePath/Contents';

        // Try different locations for the dylib
        final paths = [
          // In Frameworks directory of the app bundle (preferred)
          '$contentsPath/Frameworks/libdnstt.dylib',
          // In Libraries directory
          '$contentsPath/Libraries/libdnstt.dylib',
          // In Resources directory
          '$contentsPath/Resources/libdnstt.dylib',
          // Next to the executable
          '$contentsPath/MacOS/libdnstt.dylib',
          // Development paths
          '${Directory.current.path}/macos/Runner/Libraries/libdnstt.dylib',
          '${Directory.current.path}/libdnstt.dylib',
          'macos/Runner/Libraries/libdnstt.dylib',
          'libdnstt.dylib',
        ];

        DynamicLibrary? lib;
        for (final path in paths) {
          try {
            lib = DynamicLibrary.open(path);
            print('Loaded libdnstt from: $path');
            break;
          } catch (e) {
            continue;
          }
        }

        if (lib == null) {
          throw Exception('Could not load libdnstt.dylib from any path');
        }
        _lib = lib;
      } else if (Platform.isWindows) {
        // Get the directory containing the executable
        final executableDir = File(Platform.resolvedExecutable).parent.path;

        // Try different locations for the DLL
        final paths = [
          // Same directory as executable
          '$executableDir\\dnstt.dll',
          // Development paths
          '${Directory.current.path}\\dnstt.dll',
          'dnstt.dll',
        ];

        DynamicLibrary? lib;
        for (final path in paths) {
          try {
            lib = DynamicLibrary.open(path);
            print('Loaded dnstt.dll from: $path');
            break;
          } catch (e) {
            continue;
          }
        }

        if (lib == null) {
          throw Exception('Could not load dnstt.dll from any path');
        }
        _lib = lib;
      } else if (Platform.isLinux) {
        // Get the directory containing the executable
        final executableDir = File(Platform.resolvedExecutable).parent.path;

        // Try different locations for the shared library
        final paths = [
          // lib subdirectory (Flutter convention)
          '$executableDir/lib/libdnstt.so',
          // Same directory as executable
          '$executableDir/libdnstt.so',
          // Development paths
          '${Directory.current.path}/libdnstt.so',
          'libdnstt.so',
        ];

        DynamicLibrary? lib;
        for (final path in paths) {
          try {
            lib = DynamicLibrary.open(path);
            print('Loaded libdnstt.so from: $path');
            break;
          } catch (e) {
            continue;
          }
        }

        if (lib == null) {
          throw Exception('Could not load libdnstt.so from any path');
        }
        _lib = lib;
      } else {
        throw UnsupportedError('Platform not supported for FFI');
      }

      // Bind functions
      _createClient = _lib!.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
      >('dnstt_create_client');

      _start = _lib!.lookupFunction<Int32 Function(), int Function()>('dnstt_start');
      _stop = _lib!.lookupFunction<Int32 Function(), int Function()>('dnstt_stop');
      _isRunning = _lib!.lookupFunction<Bool Function(), bool Function()>('dnstt_is_running');
      _getLastError = _lib!.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('dnstt_get_last_error');
      _freeString = _lib!.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('dnstt_free_string');
      _testDnsServer = _lib!.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)
      >('dnstt_test_dns_server');
      if (_lib!.providesSymbol('dnstt_test_dns_server_auth')) {
        _testDnsServerAuth = _lib!.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>)
        >('dnstt_test_dns_server_auth');
      }
      if (_lib!.providesSymbol('dnstt_set_bootstrap') &&
          _lib!.providesSymbol('dnstt_set_tls_fingerprint') &&
          _lib!.providesSymbol('dnstt_test_dns_server_ex')) {
        _setBootstrap = _lib!.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(
            'dnstt_set_bootstrap');
        _setTlsFingerprint = _lib!.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(
            'dnstt_set_tls_fingerprint');
        _testDnsServerEx = _lib!.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Int32, Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                int, Pointer<Utf8>, Pointer<Utf8>)
        >('dnstt_test_dns_server_ex');
      }

      _loaded = true;
      _loading = false;
    } catch (e) {
      _loading = false;
      print('Failed to load dnstt library: $e');
      rethrow;
    }
  }

  /// Whether the library supports DoH/DoT resolvers, bootstrap addresses and
  /// TLS fingerprints.
  bool get supportsEncryptedDns => _testDnsServerEx != null;

  /// Whether [dnsServer] needs a library with DoH/DoT support.
  static bool _needsEncryptedDns(String dnsServer) =>
      (ResolverSpec.kindOf(dnsServer) ?? ResolverKind.udp) != ResolverKind.udp;

  /// Create a new dnstt client. [dnsServer] is a resolver spec; [dnsBootstrap]
  /// and [tlsFingerprint] apply to DoH and DoT resolvers.
  /// Returns true on success, false on failure
  bool createClient({
    required String dnsServer,
    String? dnsBootstrap,
    String tlsFingerprint = '',
    required String tunnelDomain,
    required String publicKey,
    String listenAddr = '127.0.0.1:1080',
  }) {
    if (!_loaded) {
      throw StateError('Library not loaded. Call load() first.');
    }
    _localError = null;
    final setBootstrap = _setBootstrap;
    final setTlsFingerprint = _setTlsFingerprint;
    if (_needsEncryptedDns(dnsServer) && (setBootstrap == null || setTlsFingerprint == null)) {
      _localError = _tooOldForDoh;
      return false;
    }

    final dnsServerPtr = dnsServer.toNativeUtf8();
    final tunnelDomainPtr = tunnelDomain.toNativeUtf8();
    final publicKeyPtr = publicKey.toNativeUtf8();
    final listenAddrPtr = listenAddr.toNativeUtf8();
    final bootstrapPtr = (dnsBootstrap ?? '').toNativeUtf8();
    final fingerprintPtr = tlsFingerprint.toNativeUtf8();

    try {
      if (_createClient(dnsServerPtr, tunnelDomainPtr, publicKeyPtr, listenAddrPtr) != 0) return false;
      if (setBootstrap != null && setBootstrap(bootstrapPtr) != 0) return false;
      if (setTlsFingerprint != null && setTlsFingerprint(fingerprintPtr) != 0) return false;
      return true;
    } finally {
      calloc.free(dnsServerPtr);
      calloc.free(tunnelDomainPtr);
      calloc.free(publicKeyPtr);
      calloc.free(listenAddrPtr);
      calloc.free(bootstrapPtr);
      calloc.free(fingerprintPtr);
    }
  }

  /// Start the dnstt client
  /// Returns true on success, false on failure
  bool start() {
    if (!_loaded) {
      throw StateError('Library not loaded. Call load() first.');
    }
    return _start() == 0;
  }

  /// Stop the dnstt client
  /// Returns true on success, false on failure
  bool stop() {
    if (!_loaded) {
      throw StateError('Library not loaded. Call load() first.');
    }
    return _stop() == 0;
  }

  /// Check if the client is running
  bool get isRunning {
    if (!_loaded) return false;
    return _isRunning();
  }

  /// Get the last error message
  String getLastError() {
    if (!_loaded) return 'Library not loaded';
    final localError = _localError;
    if (localError != null) return localError;

    final errorPtr = _getLastError();
    if (errorPtr == nullptr) return '';

    final error = errorPtr.toDartString();
    _freeString(errorPtr);
    return error;
  }

  /// Test a DNS server by making an actual connection through the tunnel
  /// Returns latency in milliseconds on success, -1 on failure
  int testDnsServer({
    required String dnsServer,
    String? dnsBootstrap,
    String tlsFingerprint = '',
    required String tunnelDomain,
    required String publicKey,
    String testUrl = 'https://api.ipify.org?format=json',
    int timeoutMs = 15000,
    String? socksUsername,
    String? socksPassword,
  }) {
    if (!_loaded) {
      return -1;
    }

    final testDnsServerEx = _testDnsServerEx;
    if (testDnsServerEx != null) {
      final ptrs = [
        dnsServer,
        dnsBootstrap ?? '',
        tlsFingerprint,
        tunnelDomain,
        publicKey,
        testUrl,
        socksUsername ?? '',
        socksPassword ?? '',
      ].map((v) => v.toNativeUtf8()).toList();
      try {
        return testDnsServerEx(ptrs[0], ptrs[1], ptrs[2], ptrs[3], ptrs[4], ptrs[5], timeoutMs, ptrs[6], ptrs[7]);
      } finally {
        ptrs.forEach(calloc.free);
      }
    }
    if (_needsEncryptedDns(dnsServer)) {
      print(_tooOldForDoh);
      return -1;
    }

    if (socksUsername != null && socksUsername.isNotEmpty) {
      return _testDnsServerWithAuth(
        dnsServer: dnsServer,
        tunnelDomain: tunnelDomain,
        publicKey: publicKey,
        testUrl: testUrl,
        timeoutMs: timeoutMs,
        socksUsername: socksUsername,
        socksPassword: socksPassword ?? '',
      );
    }

    final dnsServerPtr = dnsServer.toNativeUtf8();
    final tunnelDomainPtr = tunnelDomain.toNativeUtf8();
    final publicKeyPtr = publicKey.toNativeUtf8();
    final testUrlPtr = testUrl.toNativeUtf8();

    try {
      final result = _testDnsServer(
        dnsServerPtr,
        tunnelDomainPtr,
        publicKeyPtr,
        testUrlPtr,
        timeoutMs,
      );
      return result;
    } finally {
      calloc.free(dnsServerPtr);
      calloc.free(tunnelDomainPtr);
      calloc.free(publicKeyPtr);
      calloc.free(testUrlPtr);
    }
  }

  int _testDnsServerWithAuth({
    required String dnsServer,
    required String tunnelDomain,
    required String publicKey,
    required String testUrl,
    required int timeoutMs,
    required String socksUsername,
    required String socksPassword,
  }) {
    final testDnsServerAuth = _testDnsServerAuth;
    if (testDnsServerAuth == null) {
      print('dnstt library does not support SOCKS5 auth tests, rebuild libdnstt');
      return -1;
    }

    final dnsServerPtr = dnsServer.toNativeUtf8();
    final tunnelDomainPtr = tunnelDomain.toNativeUtf8();
    final publicKeyPtr = publicKey.toNativeUtf8();
    final testUrlPtr = testUrl.toNativeUtf8();
    final socksUsernamePtr = socksUsername.toNativeUtf8();
    final socksPasswordPtr = socksPassword.toNativeUtf8();

    try {
      return testDnsServerAuth(
        dnsServerPtr,
        tunnelDomainPtr,
        publicKeyPtr,
        testUrlPtr,
        timeoutMs,
        socksUsernamePtr,
        socksPasswordPtr,
      );
    } finally {
      calloc.free(dnsServerPtr);
      calloc.free(tunnelDomainPtr);
      calloc.free(publicKeyPtr);
      calloc.free(testUrlPtr);
      calloc.free(socksUsernamePtr);
      calloc.free(socksPasswordPtr);
    }
  }
}
