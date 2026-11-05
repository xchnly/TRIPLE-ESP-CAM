import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../transport/node_transport.dart';
import 'mjpeg_view.dart';
import 'util.dart';

class CameraTab extends StatefulWidget {
  const CameraTab({super.key});

  @override
  State<CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends State<CameraTab> {
  bool _live = true;
  bool _flash = false;
  List<File> _photos = [];

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'captures'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _loadPhotos() async {
    final files = (await _dir()).listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (mounted) setState(() => _photos = files);
  }

  Future<void> _capture(String url, String camId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final name = '${DateTime.now().millisecondsSinceEpoch}_$camId.jpg';
      await File(p.join((await _dir()).path, name)).writeAsBytes(r.bodyBytes);
      messenger.showSnackBar(SnackBar(content: Text('Foto $camId tersimpan (${(r.bodyBytes.length / 1024).round()} KB)')));
      await _loadPhotos();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Gagal mengambil foto: $e')));
    }
  }

  Future<void> _toggleFlash(String base) async {
    final v = !_flash;
    try {
      await http.get(Uri.parse('$base/control?var=flash&val=${v ? 1 : 0}')).timeout(const Duration(seconds: 4));
      setState(() => _flash = v);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final NodeInfo? node = app.node.node;
    return Scaffold(
      appBar: AppBar(title: const Text('Kamera'), actions: [
        if (node != null)
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('Live')), ButtonSegment(value: false, label: Text('Foto'))],
            selected: {_live},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _live = s.first),
          ),
        const SizedBox(width: 12),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        if (node == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Belum terhubung ke node', style: t.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Kamera hanya bisa dilihat saat WiFi HP tersambung ke salah satu node '
                  '("${kNodeSsidPrefix}1", "${kNodeSsidPrefix}2", ...). Sambungkan dari tab Jaringan.',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ]),
            ),
          )
        else ...[
          _CamCard(
            title: '${node.name} · ${node.id}',
            subtitle: 'Node yang tersambung ke HP ini',
            view: _live ? MjpegView(url: 'http://${node.ip}:81/stream') : SnapshotView(url: 'http://${node.ip}/capture'),
            actions: [
              FilledButton.icon(
                onPressed: () => _capture('http://${node.ip}/capture', node.id),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Ambil foto'),
              ),
              OutlinedButton.icon(
                onPressed: () => _toggleFlash('http://${node.ip}'),
                icon: Icon(_flash ? Icons.flash_on : Icons.flash_off),
                label: Text(_flash ? 'Flash nyala' : 'Flash'),
              ),
            ],
          ),
          for (final n in node.neighbors)
            _CamCard(
              title: '${n.name} · ${n.id}',
              subtitle: 'Lewat node ${node.id} · foto diperbarui tiap 5 detik',
              view: SnapshotView(url: 'http://${node.ip}/peer/capture?id=${n.id}', every: const Duration(seconds: 5)),
              actions: [
                OutlinedButton.icon(
                  onPressed: () => _capture('http://${node.ip}/peer/capture?id=${n.id}', n.id),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Ambil foto'),
                ),
              ],
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text('FOTO TERSIMPAN DI HP', style: t.labelSmall?.copyWith(letterSpacing: 1.2, color: cs.onSurfaceVariant)),
        ),
        if (_photos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('Belum ada.', style: TextStyle(color: cs.onSurfaceVariant)),
          )
        else
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 4 / 3,
            children: [
              for (final f in _photos)
                InkWell(
                  onTap: () => _openPhoto(f),
                  child: Image.file(f, fit: BoxFit.cover, cacheWidth: 300),
                ),
            ],
          ),
      ]),
    );
  }

  void _openPhoto(File f) {
    final name = p.basenameWithoutExtension(f.path).split('_');
    final ts = int.tryParse(name.first) ?? 0;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('${name.length > 1 ? name[1] : ''} · ${clockTime(ts)}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await f.delete();
                  if (ctx.mounted) Navigator.pop(ctx);
                  _loadPhotos();
                },
              ),
            ],
          ),
          body: InteractiveViewer(child: Center(child: Image.file(f))),
        ),
      ),
    );
  }
}

class _CamCard extends StatelessWidget {
  const _CamCard({required this.title, required this.subtitle, required this.view, required this.actions});
  final String title, subtitle;
  final Widget view;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(aspectRatio: 4 / 3, child: view),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Text(title, style: t.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(subtitle, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Wrap(spacing: 8, runSpacing: 8, children: actions),
          ),
        ]),
      ),
    );
  }
}
