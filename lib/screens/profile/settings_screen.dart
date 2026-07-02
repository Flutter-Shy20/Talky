import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../core/crypto/media_cipher_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../providers/auth_provider.dart';
import '../../talky_api_client.dart';
import '../../talky_models.dart';
import '../../widgets/common/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  User? _user;
  bool _isLoading = true;
  bool _mediaTestRunning = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final cached =
        Provider.of<AuthProvider>(context, listen: false).currentUser;
    if (cached != null && mounted) {
      setState(() {
        _user = cached;
        _isLoading = false;
      });
    }

    try {
      final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
      final data = await apiClient.getMe();
      if (!mounted) return;
      setState(() {
        _user = User.fromJson(data);
        _isLoading = false;
      });
    } catch (_) {
      if (mounted && _user == null) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Paramètres'),
      ),
      body: ListView(
        children: [
          AppSpacing.vGapLg,
          // User Info Section
          Container(
            color: context.colors.surface,
            padding: AppSpacing.card,
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AppAvatar(
                            imageUrl: _user?.avatarUrl,
                            name: _user?.nom ?? 'U',
                            size: AppSizes.avatarSm,
                          ),
                          AppSpacing.hGapLg,
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _user?.nom ?? 'User',
                                  style: context.text.titleLarge,
                                ),
                                AppSpacing.vGapXs,
                                Text(
                                  '@${_user?.pseudo ?? 'pseudo'}',
                                  style: context.text.bodyMedium?.copyWith(
                                      color: context.colors.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      AppSpacing.vGapLg,
                      Container(
                        padding: AppSpacing.card,
                        decoration: BoxDecoration(
                          color: context.semantic.surfaceMuted,
                          borderRadius: AppRadius.brSm,
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.phone,
                                color: context.colors.primary,
                                size: AppIconSize.sm),
                            AppSpacing.hGapMd,
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Téléphone Alanya',
                                  style: context.text.labelSmall?.copyWith(
                                      color: context.colors.onSurfaceVariant),
                                ),
                                Text(
                                  _user?.alanyaPhone ?? 'Non défini',
                                  style: context.text.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          AppSpacing.vGapXxl,
          _buildThemeGroup(),
          AppSpacing.vGapXxl,
          _buildSettingsGroup(
            title: 'Général',
            items: [
              _buildSettingsItem(Icons.chat, 'Discussions',
                  'Thème, fonds d\'écran, historique des discussions'),
              _buildSettingsItem(Icons.notifications, 'Notifications',
                  'Sonneries de message, groupe et appel'),
              _buildSettingsItem(Icons.data_usage, 'Stockage et données',
                  'Utilisation du réseau, téléchargement auto'),
            ],
          ),
          AppSpacing.vGapXxl,
          _buildSettingsGroup(
            title: 'Compte',
            items: [
              _buildSettingsItem(Icons.security, 'Sécurité',
                  'Vérification en deux étapes'),
              _buildSettingsItem(Icons.lock, 'Confidentialité',
                  'Bloquer les contacts, messages éphémères'),
              _buildSettingsItem(Icons.delete_outline, 'Supprimer le compte',
                  '',
                  isDestructive: true),
            ],
          ),
          if (kDebugMode) ...[
            AppSpacing.vGapXxl,
            _buildSettingsGroup(
              title: 'Debug',
              items: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
                  leading: const Icon(Icons.science_outlined),
                  title: const Text('Tester chiffrement média (round-trip)'),
                  subtitle: const Text(
                      'Chiffre → upload → download → déchiffre → compare'),
                  trailing: _mediaTestRunning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  onTap: _mediaTestRunning ? null : _runMediaCipherRoundTripTest,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _runMediaCipherRoundTripTest() async {
    setState(() => _mediaTestRunning = true);
    final messenger = ScaffoldMessenger.of(context);
    final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
    // Chunk volontairement petit (64 Ko) sur un payload ~1.2 Mo : exerce le
    // chiffrement par chunks (§4.4 MEDIAS_E2EE.md) sur ~19 chunks, dont un
    // dernier partiel, sans avoir besoin d'un vrai gros fichier de test.
    const chunkSize = 64 * 1024;
    File? tmpFile;
    try {
      final original =
          List<int>.generate(1200 * 1024, (_) => Random.secure().nextInt(256));
      final tmpDir = await getTemporaryDirectory();
      tmpFile = File(p.join(tmpDir.path, 'e2ee_test_${DateTime.now().millisecondsSinceEpoch}.bin'));
      await tmpFile.writeAsBytes(original);

      final cipher = MediaCipherService();
      final mediaKey = await cipher.newMediaKey();
      final encryptedLength = MediaCipherService.encryptedLengthFor(original.length, chunkSize);
      final encryptedStream =
          cipher.encryptFileStreaming(tmpFile, mediaKey, chunkSize: chunkSize);

      final uploaded = await apiClient.uploadEncryptedStream(encryptedStream, encryptedLength);
      final downloadedStream = apiClient.downloadMediaBlobStreaming(uploaded['id']);

      final decrypted = <int>[];
      await for (final chunk in cipher.decryptStreaming(downloadedStream, mediaKey)) {
        decrypted.addAll(chunk);
      }

      final bytesMatch = MediaCipherService.bytesEqual(original, decrypted);

      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(bytesMatch
            ? '✅ Round-trip OK (streaming) — $encryptedLength octets chiffrés, id=${uploaded['id']}'
            : '❌ Échec : le fichier déchiffré ne correspond pas à l\'original'),
        backgroundColor: bytesMatch ? Colors.green : Colors.red,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('❌ Erreur round-trip : $e'),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (tmpFile != null && await tmpFile.exists()) {
        await tmpFile.delete();
      }
      if (mounted) setState(() => _mediaTestRunning = false);
    }
  }

  Widget _buildThemeGroup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
          child: Text(
            'Apparence',
            style: context.text.labelMedium?.copyWith(
                color: context.colors.primary, fontWeight: FontWeight.bold),
          ),
        ),
        Container(
          color: context.colors.surface,
          padding: AppSpacing.card,
          child: Consumer<ThemeController>(
            builder: (_, tc, __) => SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                minimumSize: const Size(0, AppSizes.buttonHeight),
              ),
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.wb_sunny_outlined),
                  label: Text('Clair'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.nights_stay_outlined),
                  label: Text('Sombre'),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('Système'),
                ),
              ],
              selected: {tc.mode},
              onSelectionChanged: (s) => tc.setMode(s.first),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsGroup(
      {required String title, required List<Widget> items}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
          child: Text(
            title,
            style: context.text.labelMedium
                ?.copyWith(color: context.colors.primary, fontWeight: FontWeight.bold),
          ),
        ),
        Container(
          color: context.colors.surface,
          child: Column(children: items),
        ),
      ],
    );
  }

  Widget _buildSettingsItem(IconData icon, String title, String subtitle,
      {bool isDestructive = false}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
      leading: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: isDestructive ? AppColors.errorContainer : context.semantic.surfaceMuted,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: isDestructive
              ? context.colors.error
              : context.colors.onSurfaceVariant,
          size: AppIconSize.md,
        ),
      ),
      title: Text(
        title,
        style: context.text.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: isDestructive ? context.colors.error : context.colors.onSurface,
        ),
      ),
      subtitle: subtitle.isNotEmpty
          ? Text(
              subtitle,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            )
          : null,
      onTap: () {},
    );
  }
}
