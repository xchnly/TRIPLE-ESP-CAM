import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../main.dart';
import '../mesh/store.dart';
import 'camera_tab.dart';
import 'chats_tab.dart';
import 'network_tab.dart';
import 'sos_tab.dart';
import 'util.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  String? _warning;

  @override
  void initState() {
    super.initState();
    app.onSos = _showSos;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startNetworking());
  }

  Future<void> _startNetworking() async {
    final w = await app.startNetworking();
    if (mounted) setState(() => _warning = w);
  }

  void _showSos(SosAlert s) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    final pos = app.lastPosition;
    final where = s.lat == null
        ? 'Lokasi tidak tersedia'
        : pos == null
            ? formatCoord(s.lat!, s.lon!)
            : '${formatDistance(distanceMeters(pos.latitude, pos.longitude, s.lat!, s.lon!))} arah '
                '${compassName(bearingDeg(pos.latitude, pos.longitude, s.lat!, s.lon!))}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.sos, color: kSos, size: 36),
        title: Text('SOS dari ${s.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (s.msg.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('"${s.msg}"')),
          Text(where),
          Text('${clockTime(s.ts)} · ${s.hops} hop', style: Theme.of(ctx).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _tab = 1);
            },
            child: const Text('Lihat'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [const ChatsTab(), const SosTab(), const NetworkTab(), const CameraTab()];
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            _StatusStrip(warning: _warning, onRetry: _startNetworking),
            Expanded(child: IndexedStack(index: _tab, children: tabs)),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            setState(() => _tab = i);
            if (i == 0) app.clearUnread();
          },
          destinations: [
            NavigationDestination(
              icon: Badge(isLabelVisible: app.unread > 0, label: Text('${app.unread}'), child: const Icon(Icons.chat_bubble_outline)),
              selectedIcon: const Icon(Icons.chat_bubble),
              label: 'Chat',
            ),
            const NavigationDestination(icon: Icon(Icons.sos_outlined), selectedIcon: Icon(Icons.sos), label: 'SOS'),
            const NavigationDestination(icon: Icon(Icons.hub_outlined), selectedIcon: Icon(Icons.hub), label: 'Jaringan'),
            const NavigationDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: 'Kamera'),
          ],
        ),
      ),
    );
  }
}

/// Satu baris status jaringan di atas semua tab.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.warning, required this.onRetry});
  final String? warning;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final phones = app.nearby?.linkCount ?? 0;
    final node = app.node.node;
    final online = phones > 0 || node != null;
    final parts = [
      '$phones HP',
      node != null ? 'node ${node.id}' : 'tanpa node',
      if (app.emergencyOnly) 'mode darurat',
    ];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF3ECF6E) : cs.outline),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(parts.join(' · '),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
          Text(app.identity?.shortId ?? '', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.outline)),
        ]),
      ),
      if (warning != null)
        MaterialBanner(
          content: Text(warning!),
          actions: [TextButton(onPressed: onRetry, child: const Text('Coba lagi'))],
        ),
    ]);
  }
}
