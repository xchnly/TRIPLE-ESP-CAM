import 'package:flutter/material.dart';

import '../app_state.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _name = TextEditingController();
  bool _busy = false;

  Future<void> _start() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    await app.createIdentity(_name.text);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
          children: [
            Text('MeshLokal', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(
              'Chat tanpa internet dan tanpa server. HP kamu ikut meneruskan pesan orang lain, '
              'jadi jangkauan makin luas setiap ada HP atau node ESP32 baru.',
              style: t.bodyLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: 32),
            _Point(icon: Icons.key_outlined, text: 'Tidak perlu akun atau nomor HP. Identitasmu berupa kunci yang dibuat di HP ini.'),
            _Point(icon: Icons.lock_outline, text: 'Chat pribadi terenkripsi. HP lain yang meneruskan tidak bisa membacanya.'),
            _Point(icon: Icons.sos_outlined, text: 'Tombol SOS mengirim lokasi GPS ke semua perangkat di jaringan.'),
            const SizedBox(height: 32),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Nama tampilan', hintText: 'mis. Hendry'),
              onSubmitted: (_) => _start(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _start,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(_busy ? 'Membuat kunci...' : 'Mulai'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(child: Text(text)),
        ]),
      );
}
