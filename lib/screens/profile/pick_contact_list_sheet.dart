import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/db/app_database.dart';
import '../../core/services/local_cache_repository.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/contact_list_colors.dart';
import '../../core/utils/contact_list_display.dart';
import '../../widgets/common/common.dart';
import 'contact_lists_screen.dart';

/// Ce qu'a choisi l'utilisateur dans [showPickContactList].
///
/// `null` en retour de la feuille = elle a été refermée sans rien choisir, ce
/// qui ne veut PAS dire « aucune liste » : il fallait pouvoir distinguer
/// l'abandon du choix explicite de n'autoriser personne. D'où ce type plutôt
/// qu'un `int?` nu.
class ContactListChoice {
  /// `null` = « Personne ».
  final int? idList;

  const ContactListChoice(this.idList);
}

/// Choisir UNE liste de contacts, ou aucune.
///
/// Le dépôt avait `showContactListsSheet`, mais c'est de la navigation : elle
/// pousse un écran de détail et ne rend aucune valeur. L'API à valeur de retour
/// est celle de `showAddListMembersSheet`, qui sélectionne des membres ; il
/// manquait l'équivalent pour les listes elles-mêmes.
Future<ContactListChoice?> showPickContactList(
  BuildContext context, {
  int? selectedId,
}) {
  // Comme la feuille voisine : on lit le cache et on synchronise en fond,
  // plutôt que de faire attendre l'utilisateur devant un écran vide.
  unawaited(context.read<LocalCacheRepository>().syncContactLists());
  return showAppBottomSheet<ContactListChoice>(
    context: context,
    builder: (_) => _PickContactListSheet(selectedId: selectedId),
  );
}

class _PickContactListSheet extends StatelessWidget {
  const _PickContactListSheet({this.selectedId});

  final int? selectedId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cache = context.read<LocalCacheRepository>();

    return AppBottomSheet(
      padding: EdgeInsets.zero,
      child: StreamBuilder<List<LocalContactList>>(
        stream: cache.watchContactLists(),
        builder: (context, snapshot) {
          final lists = snapshot.data ?? const <LocalContactList>[];
          final couleurs = resolveListColors(lists);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.voicemailBypassTitle,
                      style: context.text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    AppSpacing.vGapXs,
                    Text(
                      l10n.voicemailBypassHint,
                      style: context.text.bodySmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              // Une coche plutôt qu'un RadioListTile : le choix ferme la
              // feuille immédiatement, il n'y a donc aucun groupe à maintenir
              // entre deux frames — et `RadioListTile.groupValue` est déprécié
              // au profit d'un `RadioGroup` ancêtre, qui n'apporterait rien ici.
              ListTile(
                leading: Icon(Icons.block, color: context.colors.onSurfaceVariant),
                title: Text(l10n.voicemailBypassNobody),
                trailing: selectedId == null
                    ? Icon(Icons.check, color: context.colors.primary)
                    : null,
                onTap: () =>
                    Navigator.pop(context, const ContactListChoice(null)),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final list in lists)
                      ListTile(
                        leading: ContactListFolder(
                          color: parseListColor(couleurs[list.idList]) ??
                              context.colors.primary,
                          size: AppSizes.avatarSm,
                        ),
                        title: Text(list.displayName(l10n)),
                        subtitle: Text(l10n.listMembersCount(list.memberCount)),
                        trailing: selectedId == list.idList
                            ? Icon(Icons.check, color: context.colors.primary)
                            : null,
                        onTap: () => Navigator.pop(
                            context, ContactListChoice(list.idList)),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.tune, color: context.colors.primary),
                title: Text(
                  lists.isEmpty ? l10n.createList : l10n.manageLists,
                  style: TextStyle(
                    color: context.colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ContactListsScreen()),
                  );
                },
              ),
              AppSpacing.vGapSm,
            ],
          );
        },
      ),
    );
  }
}
