// Penampil stream MJPEG dari ESP32-CAM (http://<node>:81/stream).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class MjpegView extends StatefulWidget {
  const MjpegView({super.key, required this.url, this.fit = BoxFit.contain});
  final String url;
  final BoxFit fit;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  Uint8List? _frame;
  String? _error;
  http.Client? _client;
  StreamSubscription<List<int>>? _sub;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(MjpegView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _close();
      _connect();
    }
  }

  Future<void> _connect() async {
    _client = http.Client();
    try {
      final res = await _client!.send(http.Request('GET', Uri.parse(widget.url))).timeout(const Duration(seconds: 6));
      final buf = BytesBuilder(copy: false);
      _sub = res.stream.listen((chunk) {
        buf.add(chunk);
        final frame = _extractFrame(buf);
        if (frame != null && mounted) {
          setState(() {
            _frame = frame;
            _error = null;
          });
        }
      }, onError: (_) => _scheduleRetry(), onDone: _scheduleRetry, cancelOnError: true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Stream tidak tersedia');
      _scheduleRetry();
    }
  }

  /// Ambil JPEG utuh terakhir (FFD8 ... FFD9) dari buffer, sisanya disimpan.
  static Uint8List? _extractFrame(BytesBuilder buf) {
    final data = buf.toBytes();
    int end = -1;
    for (var i = data.length - 2; i >= 1; i--) {
      if (data[i] == 0xFF && data[i + 1] == 0xD9) {
        end = i + 2;
        break;
      }
    }
    if (end < 0) {
      if (data.length > 2 * 1024 * 1024) buf.clear(); // buang sampah
      return null;
    }
    int start = -1;
    for (var i = end - 2; i >= 1; i--) {
      if (data[i - 1] == 0xFF && data[i] == 0xD8) {
        start = i - 1;
        break;
      }
    }
    buf.clear();
    if (end < data.length) buf.add(data.sublist(end));
    return start < 0 ? null : Uint8List.sublistView(data, start, end);
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _close();
      _connect();
    });
  }

  void _close() {
    _sub?.cancel();
    _client?.close();
    _sub = null;
    _client = null;
  }

  @override
  void dispose() {
    _retry?.cancel();
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: _error == null
              ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_error!, style: const TextStyle(color: Colors.white54)),
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Image.memory(frame, gaplessPlayback: true, fit: widget.fit),
    );
  }
}

/// Foto yang diperbarui berkala (untuk kamera node lain lewat /peer/capture).
class SnapshotView extends StatefulWidget {
  const SnapshotView({super.key, required this.url, this.every = const Duration(seconds: 4)});
  final String url;
  final Duration every;

  @override
  State<SnapshotView> createState() => _SnapshotViewState();
}

class _SnapshotViewState extends State<SnapshotView> {
  Uint8List? _img;
  String? _error;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.every, (_) => _load());
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await http.get(Uri.parse(widget.url)).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (r.statusCode == 200 && r.bodyBytes.length > 100) {
        setState(() {
          _img = r.bodyBytes;
          _error = null;
        });
      } else {
        setState(() => _error = 'Tidak terjangkau dari node ini');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Tidak terjangkau dari node ini');
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: _img != null
            ? Image.memory(_img!, gaplessPlayback: true, fit: BoxFit.contain)
            : Center(
                child: _error == null
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_error!, style: const TextStyle(color: Colors.white54), textAlign: TextAlign.center),
              ),
      );
}
