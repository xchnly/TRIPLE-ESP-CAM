import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../app_state.dart';
import '../mesh/crypto.dart';
import '../mesh/store.dart';
import '../transport/nearby_transport.dart';
import '../transport/node_transport.dart';
import 'chat_screen.dart';
import 'util.dart';

class NetworkTab extends StatelessWidget {
  const NetworkTab({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final me = app.identity!;
    final nearby = app.nearby;
    final node = app.node.node;
    final pos = app.lastPosition;

    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(title.toUpperCase(), style: t.labelSmall?.copyWith(letterSpacing: 1.2, color: cs.onSurfaceVariant)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Jaringan'), actions: [
        PopupMenuButton<String>(
          onSelected: (v) => v == 'rename' ? _rename(context) : _wipe(context),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Ubah nama')),
            PopupMenuItem(value: 'wipe', child: Text('Hapus semua data')),
          ],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(me.name),
            subtitle: Text('ID ${me.shortId}\nCocokkan ID ini kalau ada dua orang bernama sama.'),
            isThreeLine: true,
          ),
        ),

        section('HP ke HP (Bluetooth / WiFi langsung)'),
        Card(
          child: Column(children: [
            SwitchListTile(
              title: const Text('Cari & teruskan lewat HP lain'),
              subtitle: Text(nearby?.running == true
                  ? '${nearby!.linkCount} HP terhubung langsung${nearby.lowPower ? ' · scanning hemat' : ''}'
                  : 'Mati'),
              value: nearby?.running == true,
              onChanged: (v) => v ? app.startNetworking() : app.stopNearby(),
            ),
            for (final p in nearby?.connected.values ?? const <NearbyPeer>[])
              ListTile(dense: true, leading: const Icon(Icons.smartphone, size: 20), title: Text(p.name)),
          ]),
        ),

        section('Node ESP32-CAM'),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(Icons.router_outlined, color: node != null ? cs.primary : null),
              title: Text(node != null ? '${node.name} (${node.id})' : 'Tidak terhubung ke node'),
              subtitle: Text(node != null
                  ? 'WiFi ${node.ssid} · ${node.ip}'
                  : 'Sambungkan WiFi HP ke "${kNodeSsidPrefix}1", "${kNodeSsidPrefix}2", ... (sandi $kNodePassword)'),
              trailing: node != null ? IconButton(onPressed: app.node.refreshInfo, icon: const Icon(Icons.refresh)) : null,
            ),
            if (node == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final n in [1, 2, 3])
                    OutlinedButton(onPressed: () => _joinNode(context, n), child: Text('Sambung cam$n')),
                ]),
              ),
            if (node != null)
              for (final n in node.neighbors)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.settings_input_antenna, size: 20),
                  title: Text('${n.name} (${n.id})'),
                  subtitle: Text('tetangga node lewat ESP-NOW · ${n.ageSec} dtk lalu'),
                ),
          ]),
        ),

        section('Orang di jaringan'),
        FutureBuilder<List<Contact>>(
          future: app.mesh!.store.contacts(),
          builder: (context, snap) {
            final list = snap.data ?? const <Contact>[];
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('Belum ada yang terdeteksi.', style: TextStyle(color: cs.onSurfaceVariant)),
              );
            }
            return Card(
              child: Column(children: [
                for (final c in list)
                  ListTile(
                    leading: CircleAvatar(child: Text(c.name.characters.first.toUpperCase())),
                    title: Text(c.name),
                    subtitle: Text(_contactLine(c, pos)),
                    trailing: const Icon(Icons.chat_bubble_outline, size: 20),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ChatScreen(conv: 'dm:${c.pub}', title: c.name)),
                    ),
                  ),
              ]),
            );
          },
        ),
      ]),
    );
  }

  static String _contactLine(Contact c, Position? pos) {
    final parts = [shortIdOf(c.pub), '${c.hops} hop', 'aktif ${timeAgo(c.lastSeen)}'];
    if (c.lat != null && c.lon != null) {
      if (pos != null) {
        final d = distanceMeters(pos.latitude, pos.longitude, c.lat!, c.lon!);
        final b = bearingDeg(pos.latitude, pos.longitude, c.lat!, c.lon!);
        parts.add('${formatDistance(d)} ${compassName(b)}');
      } else {
        parts.add(formatCoord(c.lat!, c.lon!));
      }
    }
    return parts.join(' · ');
  }

  Future<void> _joinNode(BuildContext context, int n) async {
    final ok = await NodeTransport.joinNodeWifi(n);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Tersambung ke $kNodeSsidPrefix$n, mencari node...' : 'Gagal menyambung. Coba lewat Pengaturan WiFi HP.'),
    ));
  }

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: app.identity!.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ubah nama'),
        content: TextField(controller: c, maxLength: 32, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok == true) await app.rename(c.text);
  }

  Future<void> _wipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus semua data?'),
        content: const Text('Identitas, chat, kontak, dan riwayat SOS di HP ini akan dihapus permanen. '
            'Orang lain akan melihatmu sebagai orang baru.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok == true) await app.wipe();
  }
}
