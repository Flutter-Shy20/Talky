/// Où en est le compte vis-à-vis d'Alanya Plus : ce que racontent la carte du
/// profil et « Mon abonnement ». Tout se déduit des droits déjà reçus avec
/// `/auth/me` — afficher le profil ne coûte aucun appel.
library;

import 'entitlements.dart';

enum PlusStatus {
  /// Droits inconnus (serveur ancien) ou compte exempté : rien à montrer.
  hidden,

  /// Interrupteur éteint : tout est gratuit pendant le lancement.
  launchFree,

  /// Payant annoncé, pas encore d'abonnement.
  grace,

  /// Abonnement payé pendant la grâce : il commence à la fin de celle-ci.
  scheduled,

  /// Payant, pas d'abonnement.
  upgrade,

  /// Abonnement en cours.
  active,

  /// Abonnement terminé, rien n'a pris le relais.
  lapsed,
}

PlusStatus plusStatusOf(Entitlements e) {
  if (!e.known || e.exempt) return PlusStatus.hidden;
  if (e.period != null) return PlusStatus.active;
  if (e.upcoming != null) return PlusStatus.scheduled;
  return switch (e.phase) {
    PlusPhase.free => PlusStatus.launchFree,
    PlusPhase.grace => PlusStatus.grace,
    PlusPhase.paid =>
      e.lapsedAt != null ? PlusStatus.lapsed : PlusStatus.upgrade,
  };
}

/// Jours restants avant [until], arrondis au-dessus : « encore 1 jour »
/// jusqu'à la dernière heure, jamais « encore 0 jour ».
int plusDaysLeft(DateTime until, DateTime now) {
  final hours = until.difference(now).inHours;
  return hours <= 0 ? 0 : (hours / 24).ceil();
}

/// L'échéance entre-t-elle dans la fenêtre de relance ? Sept jours pour un
/// abonnement au mois, trente au-delà — les mêmes seuils que les relances
/// envoyées par le serveur (plan.reminder_days).
bool plusEndsSoon(PlusPeriod period, DateTime now) {
  final end = period.endsAt;
  if (end == null) return false;
  final start = period.startsAt;
  final long = start != null && end.difference(start).inDays > 45;
  return plusDaysLeft(end, now) <= (long ? 30 : 7);
}

/// Début de la période qu'un paiement fait maintenant ouvrirait.
///
/// Même règle que le serveur : à la suite de l'abonnement en cours ou à
/// venir (renouveler en avance ne fait rien perdre), et jamais avant la fin
/// de la grâce (les jours gratuits annoncés sont préservés).
DateTime plusNextPeriodStart(Entitlements e, DateTime now) {
  var start = now;
  for (final d in [
    e.period?.endsAt,
    e.upcoming?.endsAt,
    if (e.phase == PlusPhase.grace) e.graceUntil,
  ]) {
    if (d != null && d.isAfter(start)) start = d;
  }
  return start;
}

/// [date] plus [months] mois, le jour ramené à la fin du mois s'il n'existe
/// pas (31 janvier + 1 mois = 28 ou 29 février).
DateTime plusAddMonths(DateTime date, int months) {
  final utc = date.toUtc();
  final monthIndex = utc.month - 1 + months;
  final year = utc.year + (monthIndex ~/ 12);
  final month = monthIndex % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  final day = utc.day > lastDay ? lastDay : utc.day;
  return DateTime.utc(
    year,
    month,
    day,
    utc.hour,
    utc.minute,
    utc.second,
    utc.millisecond,
  );
}
