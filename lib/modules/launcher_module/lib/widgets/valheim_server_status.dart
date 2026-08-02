import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/valheim_server_service.dart';
import '../services/launcher_config_service.dart';
import '../services/i18n_service.dart';

/// Small status pill for the launcher top bar.
///
/// UI binding notes:
/// - Listens to SteamQueryService via ValueListenableBuilder for reactive updates.
/// - Colors: green when online (server responds), red when offline.
/// - Shows ping (ms) measured from Steam Query response time.
class ValheimServerStatus extends StatefulWidget {
  final SteamQueryService? service;
  const ValheimServerStatus({super.key, this.service});

  @override
  State<ValheimServerStatus> createState() => _ValheimServerStatusState();
}

class _ValheimServerStatusState extends State<ValheimServerStatus> {
  SteamQueryService? _service;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    debugPrint('[ValheimServerStatus] initState -> start service');
    _initService();
  }

  Future<void> _initService() async {
    try {
      final configService = LauncherConfigService();
      final config = await configService.loadConfig();

      _service = SteamQueryService(
        host: config.serverAddress,
        gamePort: config.serverPort,
        interval: const Duration(seconds: 5), // Częstsze odpytywanie dla statusu
        panelUrl: config.panelUrl,
      );
      _service!.start();

      if (kDebugMode) {
        debugPrint('[ValheimServerStatus] Service started with host=${config.serverAddress} port=${config.serverPort}');
      }

      if (mounted) {
        setState(() {
          _initialized = true;
        });
      }
    } catch (e) {
      debugPrint('[ValheimServerStatus] Init error: $e');
      // Fallback to default
      _service = SteamQueryService(host: 'howtodev.it', gamePort: 2456);
      _service!.start();
      if (mounted) {
        setState(() {
          _initialized = true;
        });
      }
    }
  }

  @override
  void dispose() {
    debugPrint('[ValheimServerStatus] dispose');
    _service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized || _service == null) {
      // Loading state
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x22000000),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x44FFFFFF), width: 1),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white54,
              ),
            ),
            SizedBox(width: 6),
            Text(
              '...',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ValueListenableBuilder<SteamQueryStatus>(
      valueListenable: _service!.statusListenable,
      builder: (context, status, _) {
        if (kDebugMode) {
          debugPrint('[ValheimServerStatus] update: available=${status.isAvailable} ping=${status.pingMs} players=${status.playerCount} err=${status.error}');
        }
        final bool online = status.isAvailable;
        final Color dotColor = online ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C);
        final String pingText = status.pingMs != null
            ? 'Ping: ${status.pingMs} ms'
            : (online ? 'Ping: ...' : 'Offline');

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0x22000000),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x44FFFFFF), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Colored status dot
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withAlpha(128),
                      blurRadius: 6,
                      spreadRadius: 0.5,
                    )
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // Ping text only
              Text(
                pingText,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Pastylka pokazująca liczbę graczy online
/// Używa Steam Query (A2S_PLAYER) na porcie gamePort + 1
/// Zielona gdy są gracze, pomarańczowa gdy serwer online ale 0 graczy
/// Nie pokazuje się gdy serwer nie odpowiada na Steam Query
class PlayerCountPill extends StatefulWidget {
  const PlayerCountPill({super.key});

  @override
  State<PlayerCountPill> createState() => _PlayerCountPillState();
}

class _PlayerCountPillState extends State<PlayerCountPill> {
  SteamQueryService? _service;
  LauncherConfig? _config;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    try {
      final configService = LauncherConfigService();
      _config = await configService.loadConfig();

      _service = SteamQueryService(
        host: _config!.serverAddress,
        gamePort: _config!.serverPort,
        panelUrl: _config!.panelUrl,
      );

      _service!.start();

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PlayerCountPill] Init error: $e');
    }
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  void _showPlayersDialog() {
    if (_service == null) return;

    final status = _service!.currentStatus;
    if (status.players == null || status.players!.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => _PlayersDialog(
        serverName: _config?.serverName ?? 'Server',
        players: status.players!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_service == null) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<SteamQueryStatus>(
      valueListenable: _service!.statusListenable,
      builder: (context, status, _) {
        // Nie pokazuj pastylki jeśli serwer nie odpowiada na Steam Query
        if (!status.isAvailable) {
          return const SizedBox.shrink();
        }

        final playerCount = status.playerCount ?? 0;
        final isOnline = playerCount > 0;

        // Zielony gdy są gracze, pomarańczowy gdy serwer online ale 0 graczy
        final Color numberColor = isOnline
            ? const Color(0xFF2ECC71)
            : const Color(0xFFF39C12);

        // Tooltip z liczbą graczy
        final pluralKey = playerCount == 1 ? 'players_online_single' : 'players_online_plural';
        final tooltipText = '$playerCount ${I18n.instance.t(pluralKey)}';

        return Tooltip(
          message: tooltipText,
          child: GestureDetector(
            onTap: status.players != null && status.players!.isNotEmpty
                ? _showPlayersDialog
                : null,
            child: MouseRegion(
              cursor: status.players != null && status.players!.isNotEmpty
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0x22000000),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0x44FFFFFF), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.people,
                      color: numberColor,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$playerCount',
                      style: TextStyle(
                        color: numberColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Dialog pokazujący listę graczy online
class _PlayersDialog extends StatelessWidget {
  final String serverName;
  final List<PlayerInfo> players;

  const _PlayersDialog({
    required this.serverName,
    required this.players,
  });

  @override
  Widget build(BuildContext context) {
    final pluralKey = players.length == 1 ? 'players_online_single' : 'players_online_plural';
    final playersText = '${players.length} ${I18n.instance.t(pluralKey)}';

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2ECC71), width: 2),
      ),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                const Icon(
                  Icons.people,
                  color: Color(0xFF2ECC71),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        serverName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        playersText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: I18n.instance.t('dialog_close'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(color: Color(0x44FFFFFF)),
            const SizedBox(height: 16),
            // Lista graczy
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: players.length,
                itemBuilder: (context, index) {
                  final player = players[index];
                  final hasName = player.name.isNotEmpty &&
                                  !player.name.startsWith('Player #');

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0x11FFFFFF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0x22FFFFFF),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        // Avatar/Index
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2ECC71),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Name & Time
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                hasName ? player.name : 'Player #${index + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.access_time,
                                    color: Colors.white54,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    I18n.instance.t('player_time_played', {'minutes': '${player.durationMinutes}'}),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
