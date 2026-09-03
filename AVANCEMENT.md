# Avancement

Case cochée = vérifié, pas « écrit ». Les poids reflètent la **valeur** pour le
joueur, pas le volume de code : le socle est la majorité des lignes, la
génétique est la majorité de l'intérêt.

Recalculer avec `lua progress.lua`.

## Phase 0 — Calibration (poids 10)

- [x] Format du génome relevé en jeu (13 chromosomes, UID actif/récessif)
- [x] Étiquettes des Gene Samples verrouillées sur du réel
- [x] Numérotation des slots et `slot_offset` établis
- [x] Empreinte de template par `store` + `computeHash`
- [x] API du terminal Apiarist explorée, méthodes non documentées comprises
- [x] Topologie du transposer et des faces relevée

## Phase 1 — Le socle (poids 25)

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
- [ ] Le planificateur programme lui-même l'accumulation de drones manquants
- [x] Annonce de la fleur requise (chromosome 9) avant chaque croisement
- [ ] Couche d'exécution morte de `main.lua` supprimée

## Phase 2 — Génétique (poids 45)

- [x] Module bibliothèque de gènes écrit et testé
- [x] Parseur d'étiquettes de samples
- [x] Genetic Sampler piloté
- [ ] Genetic Transposer piloté (duplication des samples)
- [ ] Imprinter piloté
- [ ] Replicator piloté
- [ ] DNA Extractor piloté
- [ ] Protein Liquifier piloté
- [ ] Mutagen Producer piloté
- [ ] Bibliothèque réellement remplie, N copies par allèle
- [ ] Index des templates tenu et vérifié au démarrage
- [ ] Template « perfection » de 12 gènes construit
- [ ] Template complet par espèce, pour le Replicator

## Phase 3 — Campagnes (poids 20)

- [ ] Campagne « obtenir le gène Species de toutes les espèces »
- [ ] Analyse d'écart sur les profils optimaux
- [ ] Base de mutations complétée pour les feuilles actuelles
- [ ] Les deux profils génétiques tranchés avec le joueur

## Fait en jeu

- `Mystical + Common → Cultivated` : les sept étapes enchaînées seules
  (tâche #4, `complete etape 8/7`).
- Campagne d'accumulation : dix cycles d'affilée, comptage juste, reprise entre
  les passes. Rendement observé : **un drone par cycle**, pas trois.
