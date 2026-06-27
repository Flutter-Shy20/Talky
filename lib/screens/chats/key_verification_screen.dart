import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../talky_api_client.dart';

/// Écran de vérification des clés Signal (Safety Number).
///
/// Affiche les empreintes des clés d'identité DH (X25519) des deux
/// interlocuteurs et calcule un numéro de sécurité que les utilisateurs
/// peuvent comparer hors-bande pour confirmer l'absence d'interception.
class KeyVerificationScreen extends StatefulWidget {
  /// Clé d'identité DH locale en base64 (32 octets X25519).
  final String myFingerprint;
  final int partnerId;
  final String partnerName;
  final TalkyApiClient api;

  const KeyVerificationScreen({
    super.key,
    required this.myFingerprint,
    required this.partnerId,
    required this.partnerName,
    required this.api,
  });

  @override
  State<KeyVerificationScreen> createState() => _KeyVerificationScreenState();
}

class _KeyVerificationScreenState extends State<KeyVerificationScreen> {
  String? _partnerFingerprint;
  String? _safetyNumber;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bundle = await widget.api.fetchKeyBundle(widget.partnerId);
      final partnerIkB64 = bundle['identityKeyDh'] as String?;
      if (partnerIkB64 == null) throw Exception('Clé d\'identité introuvable dans le bundle');
      final safety = await _computeSafetyNumber(
        base64Decode(widget.myFingerprint),
        base64Decode(partnerIkB64),
      );
      if (mounted) {
        setState(() {
          _partnerFingerprint = partnerIkB64;
          _safetyNumber = safety;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  // SHA-256(sorted(a) || sorted(b)) → 10 groupes de 4 hex chars.
  // Les deux interlocuteurs obtiennent le même résultat quel que soit l'ordre.
  Future<String> _computeSafetyNumber(List<int> a, List<int> b) async {
    final List<int> first, second;
    if (_compareBytes(a, b) <= 0) {
      first = a;
      second = b;
    } else {
      first = b;
      second = a;
    }
    final hash = await Sha256().hash([...first, ...second]);
    final hex = hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return List.generate(10, (i) => hex.substring(i * 4, i * 4 + 4)).join(' ');
  }

  int _compareBytes(List<int> a, List<int> b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }

  /// Formatte 32 octets (base64) en 4 groupes de 16 chars hex.
  String _formatFingerprint(String b64) {
    final hex = base64Decode(b64)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return List.generate(4, (i) => hex.substring(i * 16, i * 16 + 16)).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vérification des clés'),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildContent(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: context.colors.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Impossible de récupérer les clés',
              style: context.text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _error!,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.tonal(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _load();
              },
              child: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.verified_user_rounded, size: 56, color: Colors.green.shade600),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Chiffrement de bout en bout',
            style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Comparez le numéro de sécurité avec ${widget.partnerName} '
            'par téléphone ou en personne pour confirmer '
            "que personne n'intercepte vos messages.",
            style: context.text.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl + AppSpacing.md),
          _buildSafetyNumber(),
          const SizedBox(height: AppSpacing.xl),
          const Divider(),
          const SizedBox(height: AppSpacing.lg),
          _buildKeyCard('Ma clé d\'identité', widget.myFingerprint),
          const SizedBox(height: AppSpacing.md),
          _buildKeyCard('Clé de ${widget.partnerName}', _partnerFingerprint!),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Ces clés sont générées localement et ne quittent jamais votre appareil '
            'sans être chiffrées. Le numéro de sécurité change si vous ou '
            '${widget.partnerName} réinstallez l\'application.',
            style: context.text.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildSafetyNumber() {
    return Column(
      children: [
        Text(
          'NUMÉRO DE SÉCURITÉ',
          style: context.text.labelSmall?.copyWith(
            color: context.colors.onSurfaceVariant,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: _safetyNumber!));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Numéro de sécurité copié')),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
            decoration: BoxDecoration(
              color: Colors.green.withAlpha(20),
              border: Border.all(color: Colors.green.shade400, width: 1.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _safetyNumber!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Appuyez pour copier',
          style: context.text.labelSmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildKeyCard(String label, String b64) {
    final formatted = _formatFingerprint(b64);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_rounded, size: 16, color: context.colors.primary),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  label,
                  style: context.text.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              formatted,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                letterSpacing: 1,
                height: 1.6,
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
