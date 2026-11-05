import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../main.dart';
import '../mesh/store.dart';
import 'util.dart';

class SosTab extends StatefulWidget {
  const SosTab({super.key});

  @override
  State<SosTab> createState() => _SosTabState();
}

class _SosTabState extends State<SosTab> with SingleTickerProviderStateMixin {
  late final _hold = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _send();
    });
  final _msg = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    HapticFeedback.heavyImpact();
    setState(() => _sending = true);
    final pos = await app.currentPosition();
    await app.mesh!.sendSos(lat: pos?.latitude, lon: pos?.longitude, acc: pos?.accuracy, msg: _msg.text);
    _hold.reset();
    if (!mounted) return;
    setState(() => _sending = false);
    _msg.clear();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(pos == null
          ? 'SOS terkirim tanpa lokasi (GPS belum dapat posisi). Coba kirim lagi di tempat terbuka.'
          : 'SOS terkirim dengan lokasi ±${pos.accuracy.round()} m'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final mesh = app.mesh;
    if (mesh == null) return const SizedBox();
    return Scaffold(
      appBar: AppBar(title: const Text('SOS')),
      body: ListenableBuilder(
        listenable: app, // app ikut memberi tahu setiap kali mesh berubah
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const SizedBox(height: 8),
            Center(
              child: GestureDetector(
                onTapDown: _sending ? null : (_) => _hold.forward(),
                onTapUp: (_) => _hold.isCompleted ? null : _hold.reverse(),
                onTapCancel: () => _hold.isCompleted ? null : _hold.reverse(),
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (_, _) => SizedBox.square(
                    dimension: 180,
                    child: Stack(alignment: Alignment.center, children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: _hold.value,
                          strokeWidth: 6,
                          color: kSos,
                          backgroundColor: kSos.withValues(alpha: 0.15),
                        ),
                      ),
                      Container(
                        width: 150,
                        height: 150,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: kSos),
                        alignment: Alignment.center,
                        child: _sending
                            ? const CircularProgressIndicator(color: Colors.white)
                            : Text('SOS', style: t.headlineLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 2)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Tahan 2 detik untuk mengirim', textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),
            TextField(
              controller: _msg,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Keterangan (opsional)', hintText: 'mis. kaki terkilir, 3 orang'),
            ),
            const SizedBox(height: 4),
            Text(
              'SOS dikirim terbuka (tidak dienkripsi) ke semua HP dan node, bersama koordinat GPS. '
              'Aplikasi ini bukan pengganti alat darurat resmi atau tim SAR.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(children: [
                SwitchListTile(
                  title: const Text('Bagikan lokasi ke rombongan'),
                  subtitle: const Text('Lokasi terakhirmu ikut di setiap pengumuman, terlihat di tab Jaringan'),
                  value: app.shareLocation,
                  onChanged: app.setShareLocation,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Mode darurat saja'),
                  subtitle: const Text('Hemat baterai: hanya meneruskan SOS, pencarian HP lebih jarang'),
                  value: app.emergencyOnly,
                  onChanged: app.setEmergencyOnly,
                ),
              ]),
            ),
            const SizedBox(height: 24),
            Text('SOS di jaringan', style: t.titleSmall),
            const SizedBox(height: 8),
            FutureBuilder<List<SosAlert>>(
              future: mesh.store.sosAlerts(),
              builder: (context, snap) {
                final list = snap.data ?? const <SosAlert>[];
                if (list.isEmpty) {
                  return Text('Belum ada.', style: TextStyle(color: cs.onSurfaceVariant));
                }
                return Column(children: [for (final s in list) _SosCard(s)]);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SosCard extends StatelessWidget {
  const _SosCard(this.s);
  final SosAlert s;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final pos = app.lastPosition;
    String? where;
    if (s.lat != null && s.lon != null) {
      where = formatCoord(s.lat!, s.lon!);
      if (pos != null && !s.mine) {
        final d = distanceMeters(pos.latitude, pos.longitude, s.lat!, s.lon!);
        final b = bearingDeg(pos.latitude, pos.longitude, s.lat!, s.lon!);
        where = '${formatDistance(d)} arah ${compassName(b)} (${b.round()}°)\n$where';
      }
      if (s.acc != null) where = '$where  ±${s.acc!.round()} m';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: s.mine ? cs.outlineVariant : kSos.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.sos, color: s.mine ? cs.onSurfaceVariant : kSos, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(s.mine ? 'SOS kamu' : s.name, style: t.titleSmall)),
              Text(timeAgo(s.ts), style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
            if (s.msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(s.msg)),
            const SizedBox(height: 6),
            SelectableText(where ?? 'Tanpa lokasi', style: t.bodySmall),
            if (!s.mine) Text('${clockTime(s.ts)} · ${s.hops} hop', style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}
