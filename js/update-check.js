// Vérifie au chargement si une mise à jour git est disponible et propose de l'installer.
// Backend : GET update/status -> {updateAvailable, localSha, remoteSha}
//           POST update/apply -> {success, error?}
// Chemins relatifs (pas de "/" initial) pour rester compatibles avec un préfixe de proxy.
(function () {
  const T = (s) => (window.tr ? window.tr(s) : s);

  function checkForUpdate() {
    fetch("update/status")
      .then((r) => r.json())
      .then((data) => {
        if (!data || data.updateAvailable !== true) return;
        if (!confirm(T("Une mise à jour est disponible. L'installer maintenant ?"))) return;
        applyUpdate();
      })
      .catch(() => {}); // service updater absent/down : ne rien afficher
  }

  function applyUpdate() {
    fetch("update/apply", { method: "POST" })
      .then((r) => r.json())
      .then((data) => {
        if (data && data.success === true) {
          if (confirm(T("Mise à jour installée. Rafraîchir la page maintenant ?"))) {
            location.reload();
          }
        } else {
          alert(T("Échec de la mise à jour : ") + ((data && data.error) || "erreur inconnue"));
        }
      })
      .catch(() => {
        alert(T("Échec de la mise à jour : ") + "erreur inconnue");
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", checkForUpdate);
  } else {
    checkForUpdate();
  }
})();
