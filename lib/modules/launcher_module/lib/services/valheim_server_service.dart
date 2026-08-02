import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Data model representing the server status exposed to the UI.
class ServerStatus {
  final bool online;
  final int? pingMs; // null while measuring or on error
  final int? playerCount; // null when unknown
  final DateTime lastUpdated;
  final String? error;

  const ServerStatus({
    required this.online,
    required this.pingMs,
    required this.playerCount,
    required this.lastUpdated,
    this.error,
  });

  ServerStatus copyWith({
    bool? online,
    int? pingMs,
    int? playerCount,
    DateTime? lastUpdated,
    String? error,
  }) => ServerStatus(
    online: online ?? this.online,
    pingMs: pingMs ?? this.pingMs,
    playerCount: playerCount ?? this.playerCount,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    error: error,
  );
}

/// A lightweight UDP client implementing Steam Server Queries (A2S_INFO & A2S_PLAYER)
/// suitable for Valheim servers. It periodically polls server status and exposes
/// updates via a ValueNotifier and a broadcast Stream.
///
/// Key points:
/// - Uses UDP socket (RawDatagramSocket) to send queries and await responses.
/// - Implements DNS resolution (domain -> IP) for the target server.
/// - Handles the A2S_PLAYER challenge-response handshake.
/// - Measures ping as the round-trip time for A2S_INFO.
/// - Emits an update every [interval] (default 5 seconds).
class ValheimServerService {
  final String host;
  final int port;
  final Duration interval;
  final Duration timeout;

  final ValueNotifier<ServerStatus> _notifier;
  Timer? _timer;
  bool _running = false;

  final StreamController<ServerStatus> _controller =
  StreamController<ServerStatus>.broadcast();

  bool _isPolling = false;

  /// Singleton helper (optional for simple apps)
  static ValheimServerService? _instance;

  /// Reset singleton to allow reconfiguration with new host/port
  static void resetSingleton() {
    _instance?.dispose();
    _instance = null;
  }

  factory ValheimServerService.singleton({
    String host = 'howtodev.it',
    int port = 2456,
    Duration interval = const Duration(seconds: 5),
    Duration timeout = const Duration(milliseconds: 1500),
  }) {
    _instance ??= ValheimServerService(
      host: host,
      port: port,
      interval: interval,
      timeout: timeout,
    );
    return _instance!;
  }

  ValheimServerService({
    this.host = 'howtodev.it',
    this.port = 2456,
    this.interval = const Duration(seconds: 5),
    this.timeout = const Duration(milliseconds: 2500),
  }) : _notifier = ValueNotifier<ServerStatus>(
    ServerStatus(
      online: false,
      pingMs: null,
      playerCount: null,
      lastUpdated: DateTime.now(),
      error: null,
    ),
  );

  ValueListenable<ServerStatus> get listenable => _notifier;
  Stream<ServerStatus> get stream => _controller.stream;

  void start() {
    if (_running) {
      if (kDebugMode) debugPrint('[ValheimServerService] start() called but already running');
      return;
    }
    _running = true;
    if (kDebugMode) {
      debugPrint('[ValheimServerService] Starting poller: host=$host port=$port interval=${interval.inSeconds}s timeout=${timeout.inMilliseconds}ms');
    }
    // Trigger immediately, then periodically.
    _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  void stop() {
    if (kDebugMode) debugPrint('[ValheimServerService] Stopping poller');
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  void dispose() {
    if (kDebugMode) debugPrint('[ValheimServerService] dispose()');
    stop();
    _controller.close();
    _notifier.dispose();
  }

  Future<void> _poll() async {
    if (_isPolling) {
      if (kDebugMode) debugPrint('[ValheimServerService] _poll skipped (already polling)');
      return;
    }
    _isPolling = true;
    if (kDebugMode) debugPrint('[ValheimServerService] _poll begin');
    try {
      final result = await _queryOnce(host, port, timeout: timeout);
      final status = ServerStatus(
        online: result.online,
        pingMs: result.pingMs,
        playerCount: result.playerCount,
        lastUpdated: DateTime.now(),
        error: result.error,
      );
      if (kDebugMode) {
        debugPrint('[ValheimServerService] _poll result: online=${status.online} ping=${status.pingMs}ms players=${status.playerCount} error=${status.error}');
      }
      _notifier.value = status;
      _controller.add(status);
    } catch (e) {
      if (kDebugMode) debugPrint('[ValheimServerService] _poll error: $e');
      final status = ServerStatus(
        online: false,
        pingMs: null,
        playerCount: null,
        lastUpdated: DateTime.now(),
        error: e.toString(),
      );
      _notifier.value = status;
      _controller.add(status);
    } finally {
      _isPolling = false;
      if (kDebugMode) debugPrint('[ValheimServerService] _poll end');
    }
  }
}

/// Lightweight result holder for a single query round.
class _QueryResult {
  final bool online;
  final int? pingMs;
  final int? playerCount;
  final String? error;

  _QueryResult({
    required this.online,
    required this.pingMs,
    required this.playerCount,
    this.error,
  });
}

/// Core query logic: perform Steam Query A2S_INFO to check if server is online and measure ping.
/// Uses gamePort + 1 as query port (standard for Valheim/Steam servers).
Future<_QueryResult> _queryOnce(String host, int port, {required Duration timeout}) async {
  if (kDebugMode) debugPrint('[ValheimServerService] _queryOnce(host=$host, port=$port) using Steam Query');

  RawDatagramSocket? socket;
  try {
    // DNS resolution
    final List<InternetAddress> addresses = await InternetAddress.lookup(host)
        .timeout(timeout, onTimeout: () => throw TimeoutException('DNS timeout'));
    if (kDebugMode) debugPrint('[ValheimServerService] Resolved $host -> ${addresses.map((a)=>a.address).join(', ')}');

    final target = addresses.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );

    // Steam Query port is gamePort + 1
    final queryPort = port + 1;

    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    // Build A2S_INFO request
    final request = _buildA2SInfoRequest();

    // Measure ping
    final stopwatch = Stopwatch()..start();
    socket.send(request, target, queryPort);

    // Wait for response
    final completer = Completer<Uint8List?>();
    Timer? timer;
    StreamSubscription? subscription;

    subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket!.receive();
        if (datagram != null && !completer.isCompleted) {
          completer.complete(Uint8List.fromList(datagram.data));
        }
      }
    });

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    final response = await completer.future;
    stopwatch.stop();

    await subscription.cancel();
    timer.cancel();

    if (response == null) {
      if (kDebugMode) debugPrint('[ValheimServerService] No response from Steam Query');
      return _QueryResult(online: false, pingMs: null, playerCount: null, error: 'No response from server');
    }

    // Check if it's a valid A2S_INFO response (0xFFFFFFFF 0x49) or challenge (0xFFFFFFFF 0x41)
    if (response.length >= 5 && response[0] == 0xFF && response[1] == 0xFF && response[2] == 0xFF && response[3] == 0xFF) {
      final pingMs = stopwatch.elapsedMilliseconds;
      if (kDebugMode) debugPrint('[ValheimServerService] Steam Query response received, ping=${pingMs}ms');
      return _QueryResult(online: true, pingMs: pingMs, playerCount: null, error: null);
    }

    return _QueryResult(online: false, pingMs: null, playerCount: null, error: 'Invalid response');
  } catch (e) {
    if (kDebugMode) debugPrint('[ValheimServerService] Query error: $e');
    return _QueryResult(online: false, pingMs: null, playerCount: null, error: e.toString());
  } finally {
    socket?.close();
  }
}

class _SimplePingResult {
  final bool online;
  final int? pingMs;
  final String? error;
  _SimplePingResult({required this.online, this.pingMs, this.error});
}

Future<_SimplePingResult> _systemPing(String host, Duration timeout) async {
  try {
    if (Platform.isWindows) {
      final args = ['-n', '1', '-w', timeout.inMilliseconds.toString(), host];
      if (kDebugMode) debugPrint('[ValheimServerService] Running: ping ${args.join(' ')}');
      final res = await Process.run('ping', args);
      final out = (res.stdout ?? '').toString();
      final err = (res.stderr ?? '').toString();
      final text = out + (err.isEmpty ? '' : '\n' + err);
      final success = res.exitCode == 0 && RegExp(r'ttl\s*=|ttl\s*=', caseSensitive: false).hasMatch(text) || RegExp(r'ttl=', caseSensitive: false).hasMatch(text);
      int? pingMs;
      final m = RegExp(r'(?:time|czas)[=<]?\s*=?\s*(\d+)\s*ms', caseSensitive: false).firstMatch(text);
      if (m != null) {
        pingMs = int.tryParse(m.group(1)!);
      }
      return _SimplePingResult(online: success, pingMs: pingMs, error: success ? null : 'Ping failed');
    } else {
      // Unix-like: -c 1 (one packet), -W timeout in seconds (integer)
      final args = ['-c', '1', '-W', timeout.inSeconds.toString(), host];
      if (kDebugMode) debugPrint('[ValheimServerService] Running: ping ${args.join(' ')}');
      final res = await Process.run('ping', args);
      final text = (res.stdout ?? '').toString() + ((res.stderr ?? '').toString().isEmpty ? '' : '\n${res.stderr}');
      final success = res.exitCode == 0 && text.contains('time=');
      int? pingMs;
      final m = RegExp(r'time[=<>]?\s*(\d+(?:\.\d+)?)\s*ms', caseSensitive: false).firstMatch(text);
      if (m != null) {
        final v = double.tryParse(m.group(1)!);
        if (v != null) pingMs = v.round();
      }
      return _SimplePingResult(online: success, pingMs: pingMs, error: success ? null : 'Ping failed');
    }
  } catch (e) {
    return _SimplePingResult(online: false, pingMs: null, error: e.toString());
  }
}

/// Build A2S_INFO request packet: 0xFFFFFFFF 0x54 "Source Engine Query" 0x00
Uint8List _buildA2SInfoRequest() {
  final List<int> bytes = []
    ..addAll([0xFF, 0xFF, 0xFF, 0xFF])
    ..add(0x54)
    ..addAll('Source Engine Query'.codeUnits)
    ..add(0x00);
  return Uint8List.fromList(bytes);
}

bool _isA2SInfoResponse(Uint8List data) {
  // Expected: 0xFFFFFFFF 0x49 ... (S2A_INFO)
  if (data.length < 5) return false;
  return data[0] == 0xFF && data[1] == 0xFF && data[2] == 0xFF && data[3] == 0xFF && data[4] == 0x49;
}

// Steam split packet header: 0xFFFFFFFE ...
bool _isSplitPacket(Uint8List data) {
  return data.length >= 5 && data[0] == 0xFF && data[1] == 0xFF && data[2] == 0xFF && data[3] == 0xFF && data[4] == 0xFE;
}

// Very small assembler for split UDP packets. It collects 'total' chunks and concatenates their payloads.
Future<Uint8List> _recvAndAssembleSplit(
    RawDatagramSocket socket,
    InternetAddress remote,
    int port, {
      required Uint8List firstChunk,
      required Duration timeout,
    }) async {
  int offset = 5;
  final bd = ByteData.sublistView(firstChunk, offset);
  final int id = bd.getInt32(0, Endian.little);
  int index = 4; // after id
  int total = bd.getUint8(index++);
  int number = bd.getUint8(index++);
  int payloadStart = 5 + index;
  if (payloadStart >= firstChunk.length) payloadStart = firstChunk.length;
  final Map<int, List<int>> parts = {number: firstChunk.sublist(payloadStart).toList()};

  if (kDebugMode) debugPrint('[ValheimServerService] Split packet id=$id total=$total first=#$number (${firstChunk.length} bytes)');

  final completer = Completer<Uint8List>();
  Timer? to;

  void tryFinish() {
    if (parts.length == total && !completer.isCompleted) {
      final builder = BytesBuilder();
      for (int i = 0; i < total; i++) {
        final p = parts[i];
        if (p == null) return;
        builder.add(p);
      }
      final merged = builder.toBytes();
      completer.complete(merged);
    }
  }

  void onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final d = socket.receive();
      if (d == null) return;
      final String from = d.address.address;
      final expected = remote.address;
      if (from != expected && from != '::ffff:$expected') return;
      final data = d.data;
      if (!_isSplitPacket(data)) return;
      final bd2 = ByteData.sublistView(data, 5);
      final int id2 = bd2.getInt32(0, Endian.little);
      if (id2 != id) return;
      int idx2 = 4;
      final int total2 = bd2.getUint8(idx2++);
      final int num2 = bd2.getUint8(idx2++);
      int ps = 5 + idx2;
      if (ps >= data.length) ps = data.length;
      parts[num2] = data.sublist(ps).toList();
      total = total2;
      tryFinish();
    }
  }

  final sub = socket.listen(onEvent);
  to = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(TimeoutException('Split packet assembly timeout'));
    }
  });

  try {
    tryFinish();
    return await completer.future;
  } finally {
    to?.cancel();
    await sub.cancel();
  }
}

/// Build A2S_PLAYER request. First try with challenge = -1 (0xFFFFFFFF) to obtain challenge.
Uint8List _buildA2SPlayerRequest(int challenge) {
  final bytes = BytesBuilder();
  bytes.add([0xFF, 0xFF, 0xFF, 0xFF]);
  bytes.add([0x55]); // A2S_PLAYER request header
  final b = ByteData(4)..setInt32(0, challenge, Endian.little);
  bytes.add(b.buffer.asUint8List());
  return bytes.toBytes();
}

bool _isA2SChallenge(Uint8List data) {
  // Expected: 0xFFFFFFFF 0x41 <int32 challenge>
  return data.length >= 9 &&
      data[0] == 0xFF &&
      data[1] == 0xFF &&
      data[2] == 0xFF &&
      data[3] == 0xFF &&
      data[4] == 0x41;
}

bool _isA2SPlayerResponse(Uint8List data) {
  // Expected: 0xFFFFFFFF 0x44 <byte numPlayers> ...
  return data.length >= 6 &&
      data[0] == 0xFF &&
      data[1] == 0xFF &&
      data[2] == 0xFF &&
      data[3] == 0xFF &&
      data[4] == 0x44;
}

Future<int?> _queryPlayers(RawDatagramSocket socket, InternetAddress target, int port,
    {required Duration timeout}) async {
  if (kDebugMode) debugPrint('[ValheimServerService] -> A2S_PLAYER challenge request');
  // 1) Send with challenge=-1 to receive server-generated challenge number.
  Uint8List response = await _sendAndWait(
    socket,
    remote: target,
    port: port,
    payload: _buildA2SPlayerRequest(-1),
    timeout: timeout,
    expectValidator: (d) => _isA2SChallenge(d) || _isA2SPlayerResponse(d),
  );

  int challenge;
  if (_isA2SChallenge(response)) {
    final bd = ByteData.sublistView(response, 5);
    challenge = bd.getInt32(0, Endian.little);
    if (kDebugMode) debugPrint('[ValheimServerService] <- Challenge received: $challenge');

    if (kDebugMode) debugPrint('[ValheimServerService] -> A2S_PLAYER with challenge');
    response = await _sendAndWait(
      socket,
      remote: target,
      port: port,
      payload: _buildA2SPlayerRequest(challenge),
      timeout: timeout,
      expectValidator: (d) => _isA2SPlayerResponse(d),
    );
  }

  if (!_isA2SPlayerResponse(response)) {
    throw StateError('Unexpected A2S_PLAYER response');
  }
  if (response.length < 6) return null;
  final count = response[5];
  return count;
}

/// Send [payload] to [remote]:[port] and wait for a UDP datagram that passes
/// [expectValidator]. Times out after [timeout].
Future<Uint8List> _sendAndWait(
    RawDatagramSocket socket, {
      required InternetAddress remote,
      required int port,
      required Uint8List payload,
      required Duration timeout,
      required bool Function(Uint8List) expectValidator,
    }) async {
  final completer = Completer<Uint8List>();
  Timer? to;

  void tryComplete(Uint8List data) {
    if (!completer.isCompleted) {
      if (kDebugMode) debugPrint('[ValheimServerService] _sendAndWait complete (${data.length} bytes)');
      completer.complete(data);
    }
  }

  void onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final datagram = socket.receive();
      if (datagram == null) return;
      final String from = datagram.address.address;
      final String expected = remote.address;
      if (from != expected && from != '::ffff:$expected') {
        if (kDebugMode) debugPrint('[ValheimServerService] Ignoring datagram from $from (expected $expected)');
        return;
      }
      final data = datagram.data;
      if (kDebugMode) debugPrint('[ValheimServerService] <- UDP ${data.length} bytes from $from');
      if (expectValidator(data)) {
        tryComplete(Uint8List.fromList(data));
      }
    }
  }

  final sub = socket.listen(onEvent);
  if (kDebugMode) debugPrint('[ValheimServerService] -> UDP send ${payload.length} bytes to ${remote.address}:$port');
  socket.send(payload, remote, port);

  to = Timer(timeout, () {
    if (!completer.isCompleted) {
      if (kDebugMode) debugPrint('[ValheimServerService] UDP receive timeout after ${timeout.inMilliseconds}ms');
      completer.completeError(TimeoutException('UDP receive timeout'));
    }
  });

  try {
    final data = await completer.future;
    return data;
  } finally {
    to?.cancel();
    await sub.cancel();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEAM QUERY SERVICE - Pobieranie liczby graczy z serwera Valheim
// ═══════════════════════════════════════════════════════════════════════════

/// Model danych gracza
class PlayerInfo {
  final int index;
  final String name;
  final int score;
  final double durationSeconds;

  PlayerInfo({
    required this.index,
    required this.name,
    required this.score,
    required this.durationSeconds,
  });

  int get durationMinutes => (durationSeconds / 60).floor();

  @override
  String toString() => 'Player #$index: "$name" (${durationMinutes}min)';
}

/// Model statusu Steam Query
class SteamQueryStatus {
  final bool isAvailable; // Czy serwer odpowiada na zapytania Steam Query
  final int? playerCount;
  final int? pingMs; // Ping mierzony jako czas round-trip Steam Query
  final List<PlayerInfo>? players;
  final DateTime lastUpdated;
  final String? error;

  const SteamQueryStatus({
    required this.isAvailable,
    this.playerCount,
    this.pingMs,
    this.players,
    required this.lastUpdated,
    this.error,
  });

  bool get isOnline => isAvailable && playerCount != null && playerCount! > 0;

  SteamQueryStatus copyWith({
    bool? isAvailable,
    int? playerCount,
    int? pingMs,
    List<PlayerInfo>? players,
    DateTime? lastUpdated,
    String? error,
  }) => SteamQueryStatus(
    isAvailable: isAvailable ?? this.isAvailable,
    playerCount: playerCount ?? this.playerCount,
    pingMs: pingMs ?? this.pingMs,
    players: players ?? this.players,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    error: error ?? this.error,
  );
}

/// Serwis do odpytywania serwera Valheim o liczbę graczy
/// Używa Steam Server Query Protocol (A2S_PLAYER)
/// Port query to zawsze gamePort + 1
class SteamQueryService {
  final String host;
  final int gamePort;
  final Duration interval;
  final Duration timeout;

  /// Panel mode: when set, status comes from `<panelUrl>/api/launcher/status`
  /// over HTTPS instead of A2S over UDP. The query port is rarely forwarded to
  /// the internet, so UDP shows "offline" for a server that is up - the panel
  /// sits next to the game and always knows.
  final String? panelUrl;

  Timer? _timer;
  bool _running = false;
  bool _isPolling = false;

  final ValueNotifier<SteamQueryStatus> _statusNotifier = ValueNotifier(
    SteamQueryStatus(
      isAvailable: false,
      lastUpdated: DateTime.now(),
    ),
  );

  SteamQueryService({
    required this.host,
    required this.gamePort,
    this.interval = const Duration(seconds: 15),
    this.timeout = const Duration(seconds: 3),
    this.panelUrl,
  });

  ValueListenable<SteamQueryStatus> get statusListenable => _statusNotifier;
  SteamQueryStatus get currentStatus => _statusNotifier.value;

  int get queryPort => gamePort + 1;

  void start() {
    if (_running) return;
    _running = true;
    if (kDebugMode) {
      debugPrint('[SteamQueryService] Starting: $host:$gamePort (query: $queryPort)');
    }
    _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  void dispose() {
    stop();
    _statusNotifier.dispose();
  }

  Future<void> _poll() async {
    if (_isPolling) return;
    _isPolling = true;

    try {
      final result = await queryPlayers();
      _statusNotifier.value = result;
    } catch (e) {
      _statusNotifier.value = SteamQueryStatus(
        isAvailable: false,
        lastUpdated: DateTime.now(),
        error: e.toString(),
      );
    } finally {
      _isPolling = false;
    }
  }

  Future<SteamQueryStatus> queryPlayers() async {
    if (panelUrl != null && panelUrl!.trim().isNotEmpty) {
      return _queryPanel();
    }
    return _queryA2S();
  }

  Future<SteamQueryStatus> _queryPanel() async {
    try {
      final base = panelUrl!.trim().replaceAll(RegExp(r'/+$'), '');
      final sw = Stopwatch()..start();
      final r = await http
          .get(Uri.parse('$base/api/launcher/status'))
          .timeout(const Duration(seconds: 8));
      sw.stop();
      if (r.statusCode != 200) {
        return SteamQueryStatus(isAvailable: false, lastUpdated: DateTime.now());
      }
      final j = json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final names = ((j['names'] as List?) ?? const []).cast<String>();
      return SteamQueryStatus(
        isAvailable: j['online'] == true,
        playerCount: (j['players'] as num?)?.toInt() ?? 0,
        // RTT do panelu, nie do serwera gry — dla gracza to ta sama droga.
        pingMs: sw.elapsedMilliseconds,
        players: [
          for (var i = 0; i < names.length; i++)
            PlayerInfo(index: i, name: names[i], score: 0, durationSeconds: 0)
        ],
        lastUpdated: DateTime.now(),
      );
    } catch (e) {
      return SteamQueryStatus(
          isAvailable: false, lastUpdated: DateTime.now(), error: e.toString());
    }
  }

  Future<SteamQueryStatus> _queryA2S() async {
    RawDatagramSocket? socket1;
    RawDatagramSocket? socket2;

    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(timeout, onTimeout: () => throw TimeoutException('DNS timeout'));

      final target = addresses.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => addresses.first,
      );

      // Mierzymy ping od wysłania pierwszego pakietu do otrzymania odpowiedzi
      final stopwatch = Stopwatch()..start();

      // Krok 1: Challenge
      socket1 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final challengePacket = _buildA2SPlayerQueryRequest(-1);
      socket1.send(challengePacket, target, queryPort);

      final challengeResponse = await _waitForSteamPacket(socket1, timeout);
      
      // Zatrzymaj stopwatch po pierwszej odpowiedzi - to jest nasz ping
      stopwatch.stop();
      final pingMs = stopwatch.elapsedMilliseconds;

      if (challengeResponse == null || challengeResponse.length < 9 || challengeResponse[4] != 0x41) {
        return SteamQueryStatus(
          isAvailable: false,
          lastUpdated: DateTime.now(),
        );
      }

      final challenge = ByteData.sublistView(challengeResponse, 5).getInt32(0, Endian.little);

      // Krok 2: Player data
      socket2 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final playerPacket = _buildA2SPlayerQueryRequest(challenge);
      socket2.send(playerPacket, target, queryPort);

      final playerResponse = await _waitForSteamPacket(socket2, timeout);

      if (playerResponse == null) {
        return SteamQueryStatus(
          isAvailable: true,
          playerCount: 0,
          pingMs: pingMs,
          players: [],
          lastUpdated: DateTime.now(),
        );
      }

      if (playerResponse.length >= 6 && playerResponse[4] == 0x44) {
        final playerCount = playerResponse[5];
        final players = _parsePlayerData(playerResponse);

        return SteamQueryStatus(
          isAvailable: true,
          playerCount: playerCount,
          pingMs: pingMs,
          players: players,
          lastUpdated: DateTime.now(),
        );
      }

      return SteamQueryStatus(
        isAvailable: false,
        pingMs: pingMs,
        lastUpdated: DateTime.now(),
      );

    } catch (e) {
      return SteamQueryStatus(
        isAvailable: false,
        lastUpdated: DateTime.now(),
        error: e.toString(),
      );
    } finally {
      socket1?.close();
      socket2?.close();
    }
  }

  Uint8List _buildA2SPlayerQueryRequest(int challenge) {
    final challengeBytes = ByteData(4)..setInt32(0, challenge, Endian.little);
    return Uint8List.fromList([
      0xFF, 0xFF, 0xFF, 0xFF,
      0x55,
      ...challengeBytes.buffer.asUint8List(),
    ]);
  }

  Future<Uint8List?> _waitForSteamPacket(
    RawDatagramSocket socket,
    Duration timeout,
  ) async {
    final completer = Completer<Uint8List?>();
    Timer? timer;
    StreamSubscription? subscription;

    subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram != null && !completer.isCompleted) {
          completer.complete(Uint8List.fromList(datagram.data));
        }
      }
    });

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    try {
      final result = await completer.future;
      return result;
    } finally {
      await subscription.cancel();
      timer.cancel();
    }
  }

  List<PlayerInfo> _parsePlayerData(Uint8List data) {
    final players = <PlayerInfo>[];

    try {
      int offset = 6;
      final playerCount = data[5];

      for (int i = 0; i < playerCount && offset < data.length; i++) {
        if (offset >= data.length) break;
        final index = data[offset++];

        final nameStart = offset;
        while (offset < data.length && data[offset] != 0) offset++;
        if (offset >= data.length) break;

        final name = String.fromCharCodes(data.sublist(nameStart, offset));
        offset++;

        if (offset + 8 > data.length) break;

        final score = ByteData.sublistView(data, offset).getInt32(0, Endian.little);
        offset += 4;

        final duration = ByteData.sublistView(data, offset).getFloat32(0, Endian.little);
        offset += 4;

        players.add(PlayerInfo(
          index: index,
          name: name.isEmpty ? 'Player #${i + 1}' : name,
          score: score,
          durationSeconds: duration,
        ));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SteamQueryService] Parse error: $e');
    }

    return players;
  }
}
