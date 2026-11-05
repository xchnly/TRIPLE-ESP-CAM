import 'package:flutter/material.dart';

import '../app_state.dart';
import '../mesh/crypto.dart';
import '../mesh/store.dart';
import 'chat_screen.dart';
import 'util.dart';

class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final mesh = app.mesh;
    if (mesh == null) return const SizedBox();
    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newChat(context),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Baru'),
      ),
      body: ListenableBuilder(
        listenable: mesh,
        builder: (context, _) => FutureBuilder<List<Conversation>>(
          future: mesh.store.conversations(),
          builder: (context, snap) {
            final convs = snap.data ?? const [];
            if (snap.hasData && convs.isEmpty) {
              return const _Empty(
                title: 'Belum ada percakapan',
                text: 'Orang di sekitar muncul otomatis di tab Jaringan. '
                    'Tekan "Baru" untuk chat ke seseorang atau bergabung ke channel rombongan.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: convs.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, i) {
                final c = convs[i];
                return ListTile(
                  leading: CircleAvatar(child: c.isChannel ? const Icon(Icons.tag) : Text(_initial(c.title))),
                  title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(c.lastText, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(c.lastTs == 0 ? '' : clockTime(c.lastTs), style: Theme.of(context).textTheme.labelSmall),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conv: c.conv, title: c.title))),
                );
              },
            );
          },
        ),
      ),
    );
  }

  static String _initial(String s) => s.isEmpty ? '?' : s.characters.first.toUpperCase();

  Future<void> _newChat(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Chat ke orang'),
            subtitle: const Text('Pilih dari orang yang pernah terdeteksi di jaringan'),
            onTap: () => Navigator.pop(ctx, 'dm'),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: const Text('Gabung / buat channel'),
            subtitle: const Text('Semua yang memakai kode sama ada di channel yang sama'),
            onTap: () => Navigator.pop(ctx, 'chan'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'dm') {
      final contact = await Navigator.push<Contact>(context, MaterialPageRoute(builder: (_) => const ContactPicker()));
      if (contact != null && context.mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conv: 'dm:${contact.pub}', title: contact.name)));
      }
    } else if (choice == 'chan') {
      await joinChannelDialog(context);
    }
  }
}

Future<void> joinChannelDialog(BuildContext context) async {
  final name = TextEditingController(), code = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Channel'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama (bebas)', hintText: 'Rombongan Merbabu')),
        const SizedBox(height: 12),
        TextField(
          controller: code,
          decoration: const InputDecoration(
            labelText: 'Kode channel',
            hintText: 'merbabu-okt',
            helperText: 'Bagikan kode ini ke anggota. Siapa pun yang tahu kodenya bisa membaca.',
            helperMaxLines: 2,
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Gabung')),
      ],
    ),
  );
  if (ok != true || code.text.trim().length < 4 || !context.mounted) return;
  final id = await app.mesh!.joinChannel(name.text, code.text);
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ChatScreen(conv: 'chan:$id', title: name.text.trim().isEmpty ? code.text.trim() : name.text.trim())),
  );
}

class ContactPicker extends StatelessWidget {
  const ContactPicker({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Pilih orang')),
        body: FutureBuilder<List<Contact>>(
          future: app.mesh!.store.contacts(),
          builder: (context, snap) {
            final list = snap.data ?? const [];
            if (snap.hasData && list.isEmpty) {
              return const _Empty(
                title: 'Belum ada orang terdeteksi',
                text: 'Orang muncul di sini setelah HP-nya terhubung ke jaringan yang sama (langsung atau lewat relay).',
              );
            }
            return ListView(children: [
              for (final c in list)
                ListTile(
                  leading: CircleAvatar(child: Text(ChatsTab._initial(c.name))),
                  title: Text(c.name),
                  subtitle: Text('${shortIdOf(c.pub)} · ${c.hops} hop · ${timeAgo(c.lastSeen)}'),
                  onTap: () => Navigator.pop(context, c),
                ),
            ]);
          },
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.text});
  final String title, text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
}
