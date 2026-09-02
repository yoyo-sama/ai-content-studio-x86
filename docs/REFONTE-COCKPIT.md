# Refonte "Cockpit affiné" — brief de développement

Projet distinct issu de l'exploration de refonte visuelle/ergonomique de
`ai-content-studio` (2026-09-02). Trois pistes ont été maquettées et comparées
dans un artifact de design ; celle-ci (Piste 1) a été retenue en premier pour
tenir les délais imposés au client. Les deux autres pistes (Cinema Studio,
Canvas créatif) sont consignées séparément dans `ai-content-studio-cinema/` et
`ai-content-studio-canvas/` pour un développement ultérieur.

Maquette de référence (artifact, 3 pistes comparées côte à côte) :
https://claude.ai/code/artifact/2cdc4c05-83ea-4e3a-ad89-c5b22fe7c6c3

## Pourquoi cette piste en premier

Contrairement aux deux autres, elle **reste dans les contraintes actuelles**
du projet (page statique unique, vanilla JS/CSS, aucun framework, aucun
build — voir `AGENTS.md`) : c'est un raffinement de l'existant, pas une
réécriture. Risque de régression minimal sur les pipelines déjà qualifiés
(`storyboard_v2`, `reference2video`, `campaign_full`), effort de dev le plus
faible des trois pistes.

## Ce qui change concrètement

- **Nav par profils métiers** (`PROFILES`, actuellement en pleine largeur) →
  rail compact réduit à des icônes, avec libellé au survol/sélection.
- **Formulaire Generate** (actuellement plusieurs champs empilés) → condensé
  en une seule barre horizontale (prompt + contrôles contextuels au pipeline
  actif), pour réduire la hauteur occupée avant la galerie.
- **Galerie d'assets** → cartes agrandies, meilleure hiérarchie visuelle entre
  vignette/prompt/actions.
- **Pastille d'identité visible** (inspirée du "Soul ID" de Higgsfield) :
  quand `storyboard_v2`/`reference2video` est actif, afficher en permanence
  une vignette du personnage/décor ancré (charsheet/locsheet en cours), pour
  que l'utilisateur voie tout de suite quelle identité est verrouillée sans
  rouvrir l'étape 0 du mode Réalisateur.

## Ce qui ne change pas

- Aucune logique de génération, aucun graphe ComfyUI, aucun builder JS
  (`addKrea2Shot`, `addLtx25Enhance`, `submitKeyframeJob`, etc.) — uniquement
  CSS/structure DOM/JS d'affichage. Les pièges documentés dans `AGENTS.md` /
  `docs/LESSONS.md` restent valables tels quels.
- `workflows/manifest.json`, `workflows/api/*.json` : inchangés.

## Points de vigilance

- Le mode Réalisateur de `storyboard_v2` (étapes 1/2/3, cartes keyframes
  régénérables/verrouillables) a une UI déjà qualifiée par rendu réel — toute
  modification de sa structure DOM doit être re-testée avec la méthode de
  `docs/TESTING.md` (pas seulement un contrôle visuel superficiel).
- Respecter l'i18n existante (FR/EN/ES/DE) pour tout nouveau libellé.
- Valider en clair ET en sombre, aux 4 largeurs de référence du projet
  (390/768/1250/1440 px).

## Statut

Pas encore développé — ce document sert de brief pour la planification
(tour-de-controle) à venir.
