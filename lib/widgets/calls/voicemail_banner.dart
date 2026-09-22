import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/services/call/voicemail_provider.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../screens/profile/voicemail_schedule_screen.dart';

/// Bandeau du répondeur actif, posé **au-dessus** de la barre de navigation,
/// au même endroit et pour la même raison que [TripBanner] : la barre est figée
/// à cinq onglets, le bandeau est donc visible depuis les cinq, et il occupe
/// l'espace déjà réservé par `kGlassNavBarSpace`.
///
/// C'est la moitié permanente du dispositif anti-oubli. L'autre moitié est la
/// notification envoyée au premier appel réellement intercepté, une fois par
/// jour au plus. Il n'existe délibérément aucune activation sans échéance :
/// un répondeur qu'on oublie d'éteindre est pire que pas de répondeur, parce
/// que son propriétaire croit son téléphone joignable.
///
/// Il ne s'affiche que si un créneau court — sinon il rend un [SizedBox.shrink]
/// et ne coûte rien.
class VoicemailBanner extends StatelessWidget {
  const VoicemailBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VoicemailProvider>();
    if (!vm.isActive) return const SizedBox.shrink();

    final l10n = context.l10n;
    final colors = context.colors;
    // Bleu, pas rouge ni orange : rien ne va mal. C'est un état choisi, et le
    // bandeau est là pour le rappeler, pas pour alarmer.
    final fond = colors.primary;
    final encre = colors.onPrimary;

    final fin = vm.deadline;
    final libelle = fin == null
        ? l10n.voicemailBannerActive
        : l10n.voicemailBannerUntil(fin);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
      child: Material(
        color: fond,
        borderRadius: AppRadius.brSm,
        shadowColor: fond.withValues(alpha: 0.5),
        elevation: 4,
        clipBehavior: Clip.antiAlias,
        // Tapoter le bandeau ouvre le réglage : c'est le geste naturel quand on
        // voit « Répondeur actif » et qu'on veut savoir pourquoi. « Désactiver »
        // reste à portée pour qui ne veut que l'éteindre.
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const VoicemailScheduleScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 2, AppSpacing.sm, 2),
            child: Row(
              children: [
                Icon(Icons.voicemail_rounded, size: 15, color: encre),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    libelle,
                    style: context.text.labelLarge
                        ?.copyWith(color: encre, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed:
                      vm.isSaving ? null : () => _desactiver(context, vm),
                  style: TextButton.styleFrom(
                    foregroundColor: encre,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: 0),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.voicemailBannerDisable),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _desactiver(BuildContext context, VoicemailProvider vm) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      // Éteint l'activation ponctuelle ET la règle récurrente. N'effacer que la
      // première laisserait le bandeau en place quand c'est le créneau
      // récurrent qui court : le bouton paraîtrait cassé.
      await vm.disable();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.voicemailDisabled),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      afficherErreur(context, e, domaine: ErrorDomain.appel);
    }
  }
}
