import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

/// Formatage d'un poids de fichier, unités traduites et séparateur décimal
/// suivant la locale.
///
/// Les écrans avaient chacun leur `_formatBytes` privé, avec des unités
/// françaises en dur et une virgule décimale qui s'affichait telle quelle en
/// anglais et en chinois.
String formatBytes(int bytes, AppLocalizations l10n) {
  if (bytes < 1024) return '$bytes ${l10n.bytesUnitB}';

  final kb = bytes / 1024;
  if (kb < 1024) return '${_decimal(kb, l10n, 0)} ${l10n.bytesUnitKB}';

  final mb = kb / 1024;
  if (mb < 1024) return '${_decimal(mb, l10n, 1)} ${l10n.bytesUnitMB}';

  return '${_decimal(mb / 1024, l10n, 2)} ${l10n.bytesUnitGB}';
}

String _decimal(double value, AppLocalizations l10n, int decimals) {
  final pattern = decimals == 0 ? '#,##0' : '#,##0.${'#' * decimals}';
  return NumberFormat(pattern, l10n.localeName).format(value);
}
