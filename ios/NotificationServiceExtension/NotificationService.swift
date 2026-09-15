import UserNotifications

/// Notification Service Extension — enrichit une bannière de message avec la
/// photo de l'expéditeur.
///
/// Prérequis, dans cet ordre :
/// 1. cette cible doit exister dans `Runner.xcodeproj` (elle n'y était pas :
///    le fichier n'avait jamais été compilé) ;
/// 2. App Group `group.com.alanya237.alanya`, aligné sur `Runner.entitlements` ;
/// 3. côté serveur, `IOS_RICH_NSE=true` — c'est ce qui pose `mutable-content: 1`
///    dans l'APNs, et donc ce qui réveille cette extension.
///
/// Contrat de survie : `contentHandler` DOIT être appelé sur tous les chemins.
/// Sans quoi la bannière n'apparaît qu'à l'expiration du budget (~30 s), ou pas
/// du tout. Toute défaillance ici se solde donc par la notification d'origine,
/// sans photo — jamais par une notification perdue.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?
  private var downloadTask: URLSessionTask?

  /// Au-delà, l'image n'est plus un avatar : on n'a ni le temps (~30 s) ni la
  /// mémoire (~24 Mo) d'une extension pour la traiter.
  private static let maxBytes: Int64 = 4 * 1024 * 1024

  /// Marge sous le budget système, pour rendre la main avant d'être tué.
  private static let timeout: TimeInterval = 10

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

    guard let content = bestAttemptContent else {
      contentHandler(request.content)
      return
    }

    guard let avatarUrl = content.userInfo["senderAvatar"] as? String,
          !avatarUrl.isEmpty,
          let url = URL(string: avatarUrl),
          url.scheme == "https" else {
      contentHandler(content)
      return
    }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = Self.timeout
    config.timeoutIntervalForResource = Self.timeout
    let session = URLSession(configuration: config)

    downloadTask = session.downloadTask(with: url) { [weak self] tempUrl, response, _ in
      // `self` relâché : plus personne ne peut livrer, sauf l'expiration. On
      // appelle donc le handler capturé directement.
      guard let self = self else {
        contentHandler(content)
        return
      }
      // `defer` garantit la livraison quel que soit le chemin de sortie.
      defer { self.deliver() }

      guard let tempUrl = tempUrl,
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode) else {
        return
      }
      // Une page d'erreur renvoyée en 200 passerait le test de statut ; le
      // plafond de taille et la validation de type ci-dessous l'écartent.
      if http.expectedContentLength > Self.maxBytes { return }

      let ext = Self.fileExtension(for: http.mimeType)
      let dest = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("avatar-\(UUID().uuidString).\(ext)")

      do {
        try FileManager.default.moveItem(at: tempUrl, to: dest)
        // `UNNotificationAttachment` valide le type réel du fichier : un HTML
        // renommé en .jpg est rejeté ici, et la bannière part sans photo.
        let attachment = try UNNotificationAttachment(
          identifier: "avatar",
          url: dest,
          options: nil
        )
        content.attachments = [attachment]
      } catch {
        try? FileManager.default.removeItem(at: dest)
      }
    }
    downloadTask?.resume()
  }

  override func serviceExtensionTimeWillExpire() {
    downloadTask?.cancel()
    deliver()
  }

  /// Livre au plus une fois : `serviceExtensionTimeWillExpire` peut se
  /// déclencher pendant que le téléchargement se termine.
  private func deliver() {
    guard let handler = contentHandler, let content = bestAttemptContent else { return }
    contentHandler = nil
    handler(content)
  }

  private static func fileExtension(for mimeType: String?) -> String {
    switch mimeType?.lowercased() {
    case "image/png": return "png"
    case "image/gif": return "gif"
    default: return "jpg"
    }
  }
}
