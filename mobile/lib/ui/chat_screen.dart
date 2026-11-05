import 'package:flutter/material.dart';

import '../app_state.dart';
import '../mesh/crypto.dart';
import '../mesh/store.dart';
import 'util.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conv, required this.title});
  final String conv; // 'dm:<pub>' atau 'chan:<id>'
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  bool get _isChannel => widget.conv.startsWith('chan:');
  String get _target => widget.conv.substring(widget.conv.indexOf(':') + 1);

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final mesh = app.mesh!;
    if (_isChannel) {
      await mesh.sendChannel(_target, text);
    } else {
      final c = await mesh.store.contact(_target);
      if (c == null) return;
      await mesh.sendDm(c, text);
    }
  }

  Future<void> _channelMenu(String action) async {
    final mesh = app.mesh!;
    if (action == 'code') {
      final ch = (await mesh.store.channels()).where((c) => c.id == _target).firstOrNull;
      if (!mounted || ch == null) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Kode channel'),
          content: SelectableText(ch.code, style: Theme.of(ctx).textTheme.headlineSmall),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup'))],
        ),
      );
    } else if (action == 'leave') {
      await mesh.leaveChannel(_target);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = app.mesh!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title),
          Text(
            _isChannel ? 'Channel · terenkripsi dengan kode' : '${shortIdOf(_target)} · terenkripsi end-to-end',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ]),
        actions: [
          if (_isChannel)
            PopupMenuButton<String>(
              onSelected: _channelMenu,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'code', child: Text('Lihat kode')),
                PopupMenuItem(value: 'leave', child: Text('Keluar channel')),
              ],
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ListenableBuilder(
            listenable: mesh,
            builder: (context, _) => FutureBuilder<List<ChatMessage>>(
              future: mesh.store.messages(widget.conv),
              builder: (context, snap) {
                final msgs = (snap.data ?? const <ChatMessage>[]).reversed.toList();
                if (snap.hasData && msgs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Pesan disimpan di HP dan diteruskan begitu ada HP atau node di sekitar.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _Bubble(msg: msgs[i], showSender: _isChannel),
                );
              },
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Tulis pesan', counterText: '', isDense: true),
                  onSubmitted: (_) => _send(),
                ),
              ),
              IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg, required this.showSender});
  final ChatMessage msg;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final mine = msg.outgoing;
    final meta = mine ? _statusLabel(msg.status) : '${msg.hops} hop';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (showSender && !mine) Text(msg.senderName, style: t.labelMedium?.copyWith(color: cs.primary)),
            Text(msg.text),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${clockTime(msg.ts)} · $meta', style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
              if (mine) ...[const SizedBox(width: 4), _statusIcon(msg.status, cs)],
            ]),
          ]),
        ),
      ),
    );
  }

  static String _statusLabel(int s) => switch (s) {
        MsgStatus.delivered => 'diterima',
        MsgStatus.forwarded => 'diteruskan',
        _ => 'tersimpan',
      };

  static Widget _statusIcon(int s, ColorScheme cs) => Icon(
        switch (s) {
          MsgStatus.delivered => Icons.done_all,
          MsgStatus.forwarded => Icons.done,
          _ => Icons.schedule,
        },
        size: 14,
        color: s == MsgStatus.delivered ? cs.primary : cs.onSurfaceVariant,
      );
}
