# Avancement

Case cochée = vérifié, pas « écrit ». Les poids reflètent la **valeur** pour le
joueur, pas le volume de code : le socle est la majorité des lignes, la
génétique est la majorité de l'intérêt.

Recalculer avec `lua progress.lua`.

**Poids rééquilibrés le 2026-09-04.** La phase 4 — le parcours joueur — n'existait
pas, et le programme était noté 93 % alors qu'aucun joueur ne savait s'en servir.
Le moteur pèse moins qu'avant parce qu'il est fini, pas parce qu'il vaut moins.

## Phase 0 — Calibration (poids 5)

- [x] Format du génome relevé en jeu (13 chromosomes, UID actif/récessif)
- [x] Étiquettes des Gene Samples verrouillées sur du réel
- [x] Numérotation des slots et `slot_offset` établis
- [x] Empreinte de template par `store` + `computeHash`
- [x] API du terminal Apiarist explorée, méthodes non documentées comprises
- [x] Topologie du transposer et des faces relevée

## Phase 1 — Le socle (poids 20)

- [x] Persistance atomique (temp + rename)
- [x] File de tâches reprenable, étapes vérifiées avant d'agir
- [x] Couche de transport AE2 + transposer
- [x] Drivers Mutatron et Apiary
- [x] Registre d'espèces interrogé au jeu
- [x] Cycle de croisement en 7 étapes
- [x] Accumulation de drones en boucle
- [x] Récolte de la sortie de l'apiary
- [x] Planificateur de chaîne vers une espèce cible
- [x] Menu groupé, expliqué, avec suggestion contextuelle
- [x] Installeur qui se met à jour lui-même
- [x] Rapport automatique non interactif
- [x] Un croisement complet réussi en jeu, de bout en bout, sans intervention
- [x] Le planificateur programme lui-même l'accumulation de drones manquants
- [x] Annonce de la fleur requise (chromosome 9) avant chaque croisement
- [x] Couche d'exécution morte de `main.lua` supprimée

## Phase 2 — Génétique (poids 30)

- [x] Module bibliothèque de gènes écrit et testé
- [x] Parseur d'étiquettes de samples
- [x] Genetic Sampler piloté
- [x] Genetic Transposer piloté (duplication des samples)
- [x] Imprinter piloté
- [x] Replicator piloté
- [x] DNA Extractor piloté
- [x] Protein Liquifier surveillé (le joueur le remplit, le programme avertit)
- [x] Mutagen Producer surveillé (le joueur le remplit, le programme avertit)
- [x] Bibliothèque réellement remplie, N copies par allèle
- [x] Sort des templates tranché : posés à la main, jamais dans le réseau
- [ ] Template « perfection » de 12 gènes construit (écriture gène par gène faite)
- [ ] Template complet par espèce, pour le Replicator

## Phase 3 — Campagnes (poids 10)

- [x] Campagne « obtenir le gène Species de toutes les espèces »
- [x] Analyse d'écart sur les profils optimaux
- [x] Les deux profils génétiques tranchés avec le joueur
- [x] Les deux templates relus en jeu, allèle par allèle, le 2026-09-05

## Phase 4 — Le parcours joueur (poids 35)

Quatre options, dans l'ordre, pour quelqu'un qui n'a rien lu. Détail et
justification dans `FEUILLE-DE-ROUTE.md`.

**4.2 d'abord** : sans le statut « en attente du joueur », les trois autres
chantiers produisent des tâches qui meurent d'un geste de cinq secondes.

- [x] 4.2 Résultat d'étape `NEEDS_PLAYER`, avec le geste exact à faire
- [x] 4.2 La file s'arrête dessus, l'affiche, reprend à la même étape après validation
- [x] 4.2 Causes branchées : entrée bouchée, cuve vide, consommable absent, abeille absente
- [x] 4.1 Contrôle des machines : chacune répond, sur la bonne face
- [x] 4.1 Contrôle des slots : la forme mesurée correspond à la config
- [x] 4.1 Contrôle des interfaces ME (par comparaison config/réseau, sans rien déplacer)
- [x] 4.1 Contrôle des cuves, ADN lu dans le bon sens
- [x] 4.1 Contrôle des consommables : labware et samples vierges au-dessus d'un seuil
- [x] 4.1 Verdict unique : validée, ou la liste des gestes à faire
- [x] 4.3 Balayage de toutes les espèces par lots, en cache, pour trouver celles sans parents
- [x] 4.3 ~~Séparation « ruche sauvage » / « autre origine »~~ — **abandonné le 2026-09-04** : suivre d'où vient une abeille n'est pas la responsabilité du programme, c'est le travail du joueur dans le monde. `config.base_origins` supprimée
- [x] 4.3 Écran « ce que tu dois attraper », ordonné par ce que chaque espèce débloque
- [x] 4.3 Le gène d'espèce est sauvé automatiquement à la fin de chaque croisement réussi
- [x] 4.3 Le programme ne rechasse pas un gène d'espèce déjà sauvé
- [x] 4.4 Plan combiné : les chaînes de tous les porteurs manquants, fusionnées
- [x] 4.4 Écran d'avancement du template : les 11 gènes, où en est chacun
- [x] 4.4 Enchaînement croisement → chasse du gène sans retour au menu
- [x] 4.4 Le craft final annoncé avec la liste exacte des samples
- [x] 4.5 « Obtenir une abeille » refuse tant que le template n'est pas assemblé, et dit quoi
- [x] 4.5 Imprint du profil élevage sur la lignée avant de lancer la chaîne
- [x] 4.5 Journal en direct des croisements, avec ce qui reste
- [x] 4.6 Menu à quatre options + file + sous-menu avancé
- [x] 4.6 Les quinze options actuelles déplacées, aucune perdue
- [x] 4.6 Chaque option principale annonce son prérequis et refuse proprement
- [x] 4.6 La suggestion en tête d'écran dit la prochaine chose à faire
- [x] 4.7 Les allèles que portent les abeilles ordinaires nommés pour ce
      qu'ils sont, au lieu de « porteur inconnu »
- [x] 4.7 Lecture du génome de tout le stock, en un passage, sans un seul
      cycle d'apiary
- [x] 4.7 L'apiary qui se plaint du climat : l'upgrade est cherché dans le
      réseau ME et posé, sinon le geste exact est demandé
- [x] 4.7 Le deuxième template annoncé dans l'option 3 : ce qu'il partage,
      ce qu'il change
- [x] 4.8 Topologie découverte plutôt que déclarée : chaque face demandée au
      Transposer
- [x] 4.8 L'option 1 détecte une configuration qui n'est pas celle de ce monde
      et propose d'écrire la sienne
- [x] 4.7 L'option 1 regarde dans les deux machines que le joueur remplit :
      un ventre vide se voit avant que la cuve ne soit sèche
- [ ] 4.8 Un monde neuf mené de l'option 1 au premier croisement, en jeu

## Fait en jeu

- `Mystical + Common → Cultivated` : les sept étapes enchaînées seules
  (tâche #4, `complete etape 8/7`).
- Campagne d'accumulation : dix cycles d'affilée, comptage juste, reprise entre
  les passes. Rendement observé : **un drone par cycle**, pas trois.
- Premiers gènes extraits en jeu : `Fertility = 2`, `Flowering = Slower`.
  Le Sampler tourne, le tirage aléatoire est confirmé.
- Campagne de gènes : `Species = Forest` obtenu en **6 abeilles** sur 13
  budgétées, arrêt automatique dès le tirage voulu.
- **Boucle complète de la phase 2 prouvée** : trois Forest Drones imprimés en
  Cultivated Drones (`x2 → x5`, `105 → 102`) avec un template posé à la main.
  Le template n'est **pas consommé** : une pose sert toutes les abeilles.
