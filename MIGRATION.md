# Fiche de suivi — Migration vers les drivers Gendustry

**Projet** : HiveMind
**Objet** : intégration des drivers OpenComputers fournis par [The-Apiarist-Terminal](https://github.com/programgames/The-Apiarist-Terminal)
**Ouvert le** : 2026-09-08
**Fichier concerné** : `main.lua` (unique, ~166 Ko)

---

## 1. Contexte

HiveMind pilote aujourd'hui les machines Gendustry à l'aveugle : impulsions redstone sur minuterie
fixe, index de slots codés en dur, aucune lecture de l'état des machines. La fonction
`useGendustryAPI` (`main.lua:2751`) prétend utiliser une API mais n'appelle aucune méthode métier et
renvoie `true` inconditionnellement.

The-Apiarist-Terminal expose ces machines comme composants OpenComputers. Deux d'entre elles ont un
driver écrit à la main — `advmutatron` et `industrial_apiary` — qui donne accès à un état
qu'aucun driver générique ne peut atteindre : mutations offertes par un couple de parents, génome
réel d'une abeille, état du slot reine, erreurs Forestry, modificateurs de ruche.

## 2. Objectifs

| # | Objectif | Mesure de réussite |
|---|---|---|
| O1 | Le choix de la mutation est réellement piloté | `listMutations` + `selectAndProduce` remplacent le tir à l'aveugle |
| O2 | Aucun cycle ne repose sur une minuterie fixe | zéro `os.sleep` d'attente machine ; tout sur signaux |
| O3 | Aucune action destructrice sans vérification de cible | le BeeBee Gun ne tire que sur une reine confirmée |
| O4 | Le résultat de chaque étape est vérifié, pas supposé | l'espèce produite est comparée à l'espèce visée |
| O5 | Aucun index de slot codé en dur | tout vient de `listSlots()` |
| O6 | Dégradation propre sans le mod | le comportement actuel reste le fallback |

## 3. Décisions actées

| Réf | Décision | Justification |
|---|---|---|
| D1 | Le Mechanical User est **conservé** | Le mod n'expose aucun moyen d'écourter un cycle ; `setRedstoneMode` autorise ou interdit, il ne tue pas la reine. Le BeeBee Gun + Assassin reste le seul levier d'accélération. |
| D2 | Le Mutatron **ne reçoit pas d'impulsion** | Un seul Mechanical User, braqué sur la ruche (README, *Wiring* §2). Le Mutatron démarre seul via le tick bdlib. Les appels des phases 2 sont des tirs parasites. |
| D3 | **Pas d'upgrade Automation** sur la ruche | Il réinsère la princesse et relance un cycle, privant HiveMind du parent dont il a besoin, et rend `freed` non significatif. |
| D4 | Templates / Imprinter / Replicator / Transposer **hors périmètre** | Traités séparément par le mainteneur. |
| D5 | Genetic Sampler **hors périmètre** | Le choix du chromosome prélevé n'est pas exposé ; tout échantillonnage serait un tirage. |
| D6 | `requireAnalyzedBees` **non bloquant** | Désactivé sur le serveur cible ; `getGenome` répond sans Beealyzer. |

## 4. Points fermés

| Réf | Question | Réponse |
|---|---|---|
| Q1 | Combien de Mechanical Users ? | Un seul, face à la ruche (README) |
| Q2 | Le Mutatron a-t-il besoin d'un clic ? | Non, démarrage automatique par le tick serveur |
| Q4 | Le Mutatron sort-il une reine ? | Oui |
| Q5 | L'identification des espèces fonctionne-t-elle ? | Oui — hypothèse `stack.name` invalidée, retirée |
| Q6 | `requireAnalyzedBees` ? | `false` sur le serveur |
| Q7 | Upgrade Automation ? | À ne pas installer (D3) |

## 5. Point ouvert — bloquant pour L2-11 et L4-25

| Réf | Question | Moyen de résolution |
|---|---|---|
| Q3 | Les index de slots sont-ils 0-based (driver) ou 1-based (inventory_controller) ? | Exécuter `check_slots.lua` en jeu, ruche et Mutatron chargés, et rapporter les deux verdicts `OFFSET` |

`apiary_output_slots = {2,3,4,5,6}` (`main.lua:453`) contre `outputs = 6..14` annoncés par le
driver : les deux plages ne se recouvrent pas. Si la config est fausse, la récolte lit les slots
d'upgrades au lieu des sorties.

---

## 6. Tableau de bord

| ID | Lot | Tâche | Dép. | Risque | Statut |
|---|---|---|---|---|---|
| 01 | L1 | Corriger les noms de composants | — | faible | Appliqué |
| 02 | L1 | Résolution par adresse + `component.invoke` | 01 | faible | Appliqué |
| 03 | L1 | Wrapper d'appel `pcall` uniforme | 02 | faible | Appliqué |
| 04 | L1 | Mode dégradé si drivers absents | 03 | moyen | Appliqué |
| 28 | L1 | Rapport de diagnostic en fichier | 03 | faible | Appliqué |
| 05 | L2 | Réécrire `useGendustryAPI` sur `listMutations` | 03 | élevé | Appliqué |
| 06 | L2 | Supprimer le `return true` et le fallback sauté | 05 | élevé | Appliqué |
| 07 | L2 | Remonter les raisons textuelles du driver | 05 | faible | Appliqué |
| 08 | L2 | Base en dur = plan a priori, `listMutations` = vérité | 05 | moyen | Appliqué |
| 09 | L2 | Gérer le labware | 11 | élevé | Appliqué |
| 10 | L2 | Surveiller le mutagène via `getTank` | 03 | moyen | Appliqué |
| 11 | L2 | Index de slots via `listSlots()` | Q3 | élevé | Appliqué, Q3 |
| 30 | L3 | Supprimer les impulsions de la phase 2 | — | élevé | Appliqué |
| 12 | L3 | Attente sur `advmutatron_finished` | 14 | moyen | Appliqué |
| 13 | L3 | Attente sur `apiary_finished` | 14 | moyen | Appliqué |
| 14 | L3 | Multiplexer signaux machine et `key_down` | — | élevé | Appliqué |
| 15 | L3 | `setEventsEnabled` / `setSignalInterval` | 12 | faible | Appliqué |
| 16a | L3 | Ne tirer que sur `type == "queen"` | 13 | élevé | Appliqué |
| 17 | L3 | Vérifier `freed` après le tir, réessayer | 16a | moyen | Appliqué |
| 18 | L3 | Détecter `automated` et avertir | 13 | faible | Appliqué |
| 19 | L3 | Afficher `getErrors()` | 03 | faible | Appliqué |
| 20 | L3 | `setRedstoneMode` pendant les transferts | 03 | moyen | Appliqué |
| 21 | L3 | Chronométrer `started` → `finished` | 13 | faible | Appliqué |
| 22 | L4 | Valider l'espèce produite via `getOutput` | 05 | élevé | Appliqué |
| 23 | L4 | Accumulation pilotée par `pure` | 22 | moyen | Appliqué |
| 24 | L4 | Gérer le refus `requireAnalyzedBees` | 23 | faible | Appliqué |
| 25 | L4 | Récolte via `listOutputs()` | Q3, 11 | élevé | Appliqué, Q3 |
| 26 | L5 | Confronter la base à `listSpeciesTemplates` | 03 | moyen | Appliqué |
| 27 | L5 | Pondérer le coût par dominance | 26 | élevé | Appliqué |
| 29 | L5 | Exposer environnement et modificateurs | 03 | faible | Appliqué |

**Lots** : L1 socle · L2 mutation et ressources · L3 événements et Mechanical User · L4 validation
et récolte · L5 génétique et interface.

---

## 7. Fiches détaillées

### Lot L1 — Socle de connexion

#### 01 — Corriger les noms de composants
- **Objectif** : que la détection trouve les machines.
- **Méthode** : remplacer la liste devinée (`main.lua:62-67`) par `advmutatron` et
  `industrial_apiary`. Retirer le balayage heuristique `component.list()` (`main.lua:77-82`),
  devenu inutile.
- **Résultat attendu** : `checkGendustryAPI` détecte les deux machines quand l'Adapter est posé,
  et rien quand il ne l'est pas.
- **Vérification** : `check_slots.lua`, bloc *Components present*.

#### 02 — Résolution par adresse
- **Objectif** : ne pas dépendre d'un proxy périmé.
- **Méthode** : `component.list(kind, true)()` puis `component.invoke`, jamais
  `component.advmutatron`. OpenOS met en cache un proxy par adresse dans un état Lua qui survit au
  rechargement du monde.
- **Résultat attendu** : après une mise à jour du mod, les nouvelles callbacks sont visibles sans
  redémarrer l'ordinateur.
- **Vérification** : appeler une callback récente après un `/reload`.

#### 03 — Wrapper d'appel uniforme
- **Objectif** : une erreur de composant ne doit jamais interrompre le programme.
- **Méthode** : helper renvoyant `nil, raison` sur `pcall` échoué, sur le modèle de `breed.lua`.
  Tous les appels driver passent par lui.
- **Résultat attendu** : un Adapter retiré en cours de route produit un message, pas un crash.
- **Vérification** : casser l'Adapter pendant un cycle.

#### 04 — Mode dégradé
- **Objectif** : le programme reste utilisable sans le mod.
- **Méthode** : un drapeau `has_drivers` calculé une fois. Chaque nouvelle capacité teste ce
  drapeau et retombe sur le chemin actuel (redstone + `inventory_controller`).
- **Résultat attendu** : sans Adapter, le comportement est celui d'aujourd'hui, corrections de
  bugs comprises.
- **Vérification** : `test_planning.lua` doit passer dans les deux modes.

#### 28 — Rapport de diagnostic
- **Objectif** : remplacer le `print` de `checkGendustryAPI` (`main.lua:2726`) par un rapport
  exploitable.
- **Méthode** : rapport écrit dans un fichier, sur le modèle de `survey.lua` — composants, slots,
  énergie, réservoirs, erreurs. Lisible avec `edit`.
- **Résultat attendu** : un fichier suffit à diagnostiquer une installation à distance.
- **Vérification** : le rapport identifie une installation volontairement incomplète.

### Lot L2 — Choix de la mutation et ressources

#### 05 — Réécrire `useGendustryAPI`
- **Objectif** : sélectionner réellement la mutation cible.
- **Méthode** : `listMutations()` → correspondance sur `label` ou `name` avec l'espèce visée →
  `selectAndProduce(index)`. Les trois paramètres aujourd'hui inutilisés (`parent1`, `parent2`,
  `target`) deviennent significatifs.
- **Résultat attendu** : la mutation lancée est celle demandée, ou un refus explicite.
- **Vérification** : demander une cible impossible pour le couple chargé ; la liste des mutations
  réellement offertes doit s'afficher.

#### 06 — Supprimer le `return true` et le fallback sauté
- **Objectif** : ne plus déclarer un succès qui n'a pas eu lieu.
- **Méthode** : `main.lua:2777` renvoie aujourd'hui `true` dès qu'un composant nommé « mutatron »
  existe, ce qui fait sauter le fallback redstone en `main.lua:3886-3894`. Propager le vrai
  résultat de `selectAndProduce`.
- **Résultat attendu** : un échec de sélection déclenche le fallback ou une erreur, jamais un
  silence.
- **Vérification** : couper l'alimentation du Mutatron et lancer un cycle.

#### 07 — Remonter les raisons textuelles
- **Objectif** : diagnostiquer en une ligne.
- **Méthode** : `selectAndProduce` renvoie `false` plus l'une de `missing parent 1`,
  `missing parent 2`, `missing labware`, `output full`,
  `not enough mutagen: X of Y mB`. Router vers `drawGUI` et `handleError`.
- **Résultat attendu** : la GUI affiche la cause exacte.
- **Vérification** : retirer le labware et lancer.

#### 08 — Base en dur contre `listMutations`
- **Objectif** : que le pack fasse foi, pas la base codée en dur.
- **Méthode** : la base `mutations` (`main.lua:99+`) sert à planifier ; `listMutations()` valide à
  l'exécution. Divergence = avertissement nommant les deux, pas un échec muet.
- **Résultat attendu** : une recette désactivée par le pack est signalée à l'étape concernée.
- **Vérification** : viser une espèce absente du pack.

#### 09 — Gérer le labware
- **Objectif** : le Mutatron ne peut pas démarrer sans.
- **Méthode** : `loadMutatron` (`main.lua:2602`) alimente aussi `listSlots().labware`. Aucune
  occurrence de « labware » dans `main.lua` aujourd'hui.
- **Résultat attendu** : un cycle démarre sans intervention manuelle.
- **Vérification** : chaîne de plusieurs croisements sans toucher au coffre.

#### 10 — Surveiller le mutagène
- **Objectif** : ne pas attendre un signal qui ne viendra pas.
- **Méthode** : `getTank()` avant chaque cycle ; en dessous du besoin, attendre en affichant le
  niveau plutôt que de lancer.
- **Résultat attendu** : une panne de mutagène est annoncée, pas subie.
- **Vérification** : vider le réservoir.

#### 11 — Index de slots via `listSlots()` — **bloqué par Q3**
- **Objectif** : supprimer `mutatron_input_slots`, `mutatron_output_slot`, `apiary_input_slot`,
  `apiary_output_slots` (`main.lua:449-453`).
- **Méthode** : lire `listSlots()` au démarrage, appliquer l'offset déterminé par `check_slots.lua`,
  stocker le résultat dans `config` au lieu de valeurs littérales.
- **Résultat attendu** : le programme suit un éventuel réordonnancement de slots par Gendustry.
- **Vérification** : `check_slots.lua`, bloc *VERDICT ON main.lua CONFIG*, tout en `OK`.

### Lot L3 — Événements et Mechanical User

#### 30 — Supprimer les impulsions de la phase 2
- **Objectif** : arrêter de tirer sur la ruche en croyant démarrer le Mutatron.
- **Méthode** : retirer les appels `activateMechanicalUser()` de `main.lua:3892` et `3894`. Le
  Mutatron démarre seul (D2). Retirer aussi l'appel à `waitForBeebeeGun()` là où l'arme n'a rien à
  faire.
- **Résultat attendu** : plus de tir parasite. Une princesse encore en ruche n'est plus abattue.
- **Vérification** : lancer un croisement avec une princesse dans la ruche ; elle doit survivre.
- **Note** : bug le plus coûteux identifié — perte silencieuse de lignée.

#### 12 — Attente sur `advmutatron_finished`
- **Objectif** : supprimer le sondage du slot de sortie (`main.lua:2645-2652`).
- **Méthode** : `event.pull(timeout, "advmutatron_finished")` puis `getOutput()`. En cas de
  timeout, distinguer `isWorking()` vrai (cycle long) de faux (machine bloquée).
- **Résultat attendu** : la reine est récupérée dès qu'elle existe.
- **Vérification** : mesurer le délai entre fin de cycle et transfert.

#### 13 — Attente sur `apiary_finished`
- **Objectif** : supprimer la boucle `os.sleep` fixe (`main.lua:3904`, `apiary_wait_time = 30`).
- **Méthode** : `event.pull(timeout, "apiary_finished")` puis `getPrincessStatus()`.
- **Résultat attendu** : plus d'attente inutile ni de récolte prématurée.
- **Vérification** : comparer la durée d'un cycle avant et après.

#### 14 — Multiplexer les signaux — **prérequis de 12 et 13**
- **Objectif** : garder pause et abandon opérants pendant les attentes.
- **Méthode** : `checkContinue` (`main.lua:3099`) consomme `key_down`. Un `event.pull` filtré sur
  un signal machine jette les `key_down` de la file. Passer à un `event.pull` court non filtré avec
  dispatch manuel.
- **Résultat attendu** : la touche d'abandon répond pendant un cycle de plusieurs minutes.
- **Vérification** : abandonner en plein cycle.

#### 15 — Contrôle des signaux
- **Objectif** : éviter la noyade sous les signaux `_output`.
- **Méthode** : `setSignalInterval(ticks)` et `setEventsEnabled` selon le besoin. `_started` et
  `_finished` ne sont jamais étranglés ; seul le balayage des sorties l'est.
- **Résultat attendu** : pas de perte d'événement, pas de saturation.
- **Vérification** : compter les signaux sur dix cycles.

#### 16a — Ne tirer que sur une reine
- **Objectif** : ne jamais gaspiller une lignée.
- **Méthode** : avant l'impulsion, `getPrincessStatus()`. Tirer si `type == "queen"`. Sur
  `princess`, attendre la fécondation. Sur `none`, le cycle est déjà fini. Sur `other`, signaler.
- **Résultat attendu** : plus aucune princesse non fécondée abattue.
- **Vérification** : insérer une princesse sans drone et lancer un cycle.

#### 17 — Vérifier que le tir a porté
- **Objectif** : distinguer un BeeBee Gun déchargé d'un cycle qui continue.
- **Méthode** : relire `freed` après l'impulsion ; si faux et `type` toujours `queen`, réessayer un
  nombre borné de fois puis remonter l'erreur.
- **Résultat attendu** : une arme vide est nommée, pas devinée.
- **Vérification** : retirer les munitions.

#### 18 — Détecter `automated`
- **Objectif** : diagnostiquer en trois secondes une ruche mal équipée.
- **Méthode** : lire `automated` au démarrage et l'afficher en avertissement (D3).
- **Résultat attendu** : l'upgrade Automation est signalé avant le premier cycle.
- **Vérification** : poser l'upgrade et démarrer.

#### 19 — Afficher `getErrors()`
- **Objectif** : remplacer « No products collected » (`main.lua:3918`).
- **Méthode** : sur récolte vide, lire `getErrors()` et afficher les états Forestry.
- **Résultat attendu** : la cause réelle apparaît — climat, énergie, sortie pleine.
- **Vérification** : mettre la ruche hors climat.

#### 20 — Geler la ruche pendant les transferts
- **Objectif** : ne pas lire un inventaire qui bouge.
- **Méthode** : `setRedstoneMode("NEVER")` avant transfert, restauration du mode initial après.
  Préférer `ALWAYS` / `NEVER` à `RS_ON` / `RS_OFF` pour ne pas coupler l'état de la ruche au signal
  du Mechanical User.
- **Résultat attendu** : récolte cohérente, pas de course.
- **Vérification** : récolter pendant un cycle actif.

#### 21 — Chronométrer un cycle
- **Objectif** : chiffrer le gain du BeeBee Gun et calibrer les timeouts.
- **Méthode** : horodater `apiary_started` et `apiary_finished`, journaliser avec
  `getModifiers().lifespan` et le chromosome `lifespan` de la reine.
- **Résultat attendu** : une durée mesurée remplace `apiary_wait_time = 30`.
- **Vérification** : dix cycles, écart-type raisonnable.

### Lot L4 — Validation et récolte

#### 22 — Valider l'espèce produite
- **Objectif** : `validateMutatronOutput` (`main.lua:3221`) vérifie aujourd'hui qu'un stack existe,
  pas ce qu'il contient.
- **Méthode** : `getOutput()` et comparaison à l'espèce visée. **Le contrôle s'insère avant**
  `moveQueenToApiary` (`main.lua:2638`) : une fois la reine en ruche, la rejeter coûte un cycle.
- **Résultat attendu** : une mutation ratée est détectée immédiatement.
- **Vérification** : forcer une mutation à faible probabilité.

#### 23 — Accumulation pilotée par la pureté
- **Objectif** : remplacer un compteur arbitraire par un critère génétique.
- **Méthode** : `getGenome("queen").chromosomes.species.pure` ; boucler tant que faux.
- **Résultat attendu** : l'accumulation s'arrête quand le trait se transmet, ni avant ni après.
- **Vérification** : comparer le nombre de cycles avant et après sur une même cible.

#### 24 — Refus `requireAnalyzedBees`
- **Objectif** : message clair si l'option est réactivée un jour.
- **Méthode** : `getGenome` renvoie `false` plus une raison ; l'afficher telle quelle et retomber
  sur l'identification par nom d'item.
- **Résultat attendu** : dégradation propre, pas de blocage.
- **Vérification** : activer l'option en config.

#### 25 — Récolte via `listOutputs()` — **bloqué par Q3**
- **Objectif** : supprimer `apiary_output_slots` (`main.lua:453`).
- **Méthode** : `listOutputs()` renvoie les slots non vides avec leur index. **Attention** : le
  champ s'appelle `count`, alors que `collectApiaryProducts` (`main.lua:2683`) lit `stack.size`.
  Unifier aussi la reconnaissance : `collectApiaryProducts` (`main.lua:2700-2710`) ne matche que
  `queen` et `drone`, alors que `scanInventory` (`main.lua:541`) matche aussi `princess` — or c'est
  une princesse que produit une fin de cycle.
- **Résultat attendu** : toutes les sorties récoltées, princesses comprises.
- **Vérification** : `check_slots.lua` puis une récolte comptée à la main.

### Lot L5 — Génétique et interface

#### 26 — Confronter la base à `listSpeciesTemplates`
- **Objectif** : détecter les écarts entre la base codée en dur et le pack réel.
- **Méthode** : au démarrage, `listSpeciesTemplates()` et comparaison avec `available_bees`.
  Signaler les deux sens. La liste vient du registre d'allèles Forestry, donc les espèces des
  autres mods y figurent avec leur propre préfixe.
- **Résultat attendu** : un rapport d'écart au lieu d'échecs de planification tardifs.
- **Vérification** : restreindre `enabled_mods` et observer le rapport.

#### 27 — Pondérer le coût par dominance
- **Objectif** : un trait récessif coûte plusieurs générations, un dominant une seule.
- **Méthode** : `getSpeciesTemplate` donne `dominant` par chromosome. Injecter cette pondération
  dans le calcul de chemin. **À faire en dernier et isolément** : cela change les chemins calculés,
  donc les résultats de `test_planning.lua`.
- **Résultat attendu** : les chemins privilégient les croisements courts.
- **Vérification** : `test_planning.lua` mis à jour, écarts justifiés un par un.

#### 29 — Exposer environnement et modificateurs
- **Objectif** : rendre visible ce qui conditionne la réussite.
- **Méthode** : `getEnvironment()` et `getModifiers()` dans la GUI, en mettant `mutation` en avant
  — il multiplie directement la chance de croisement.
- **Résultat attendu** : l'utilisateur voit pourquoi un croisement traîne.
- **Vérification** : comparer deux ruches équipées différemment.

---

## 7 bis. Bugs préexistants découverts pendant la conception

Non prévus au périmètre, remontés par les agents et **vérifiés**. Ils sont antérieurs à la
migration et la précèdent en priorité.

| ID | Bug | Vérification | Gravité |
|---|---|---|---|
| B1 | `control_state` est déclaré `local` en `main.lua:3046`, mais utilisé en `main.lua:2499`, `2616`, `2622` et `2631`. En Lua, un `local` de portée fichier n'est pas visible des fonctions définies plus haut : ces quatre sites lisent un global `nil` et `control_state.abort_requested` lève. | `grep -n control_state` : quatre usages avant la déclaration | **Critique** |
| B2 | `validateMutatronOutput` (`main.lua:3222`) et `validateApiarySpace` (`main.lua:3231`) appellent `inventory_controller`, qui n'existe pas. Le local s'appelle `inv_controller` (`main.lua:50`). Les deux fonctions lèvent à coup sûr. | `grep -n "inventory_controller\."` : deux occurrences, aucune déclaration | **Critique** |
| B3 | `status_colors` et `gui_state` sont déclarés `local` tardivement. **Vérifié : aucun usage antérieur, donc pas un bug existant** — seulement une contrainte pour le code neuf. Déclarés en tête par précaution. | `grep` : zéro usage avant déclaration | Sans objet |
| B4 | `extractSpecies` (`main.lua:624`) parcourt `available_bees` trié alphabétiquement et renvoie la **première** espèce dont le nom apparaît dans la chaîne. « Uncommon Queen » renvoie donc « Common ». Il faut retenir la correspondance la plus longue. | lecture de la fonction | Élevé |
| B5 | `collectApiaryProducts` (`main.lua:2700`) teste `item_name:find("queen")` sans passer en minuscules, alors que `scanInventory` (`main.lua:541`) le fait. | comparaison des deux sites | Moyen |

**B1 et B2 sont sur le chemin d'exécution nominal.** `waitForBeebeeGun` (`main.lua:2499`) est appelée
par chaque `activateMechanicalUser()`, donc dès la première impulsion. Cela suggère que le chemin
d'exécution n'a jamais été parcouru de bout en bout en jeu — ce que corrobore le fait que la suite de
tests ne couvre que la planification.

**Correctif** : remonter les déclarations `local` de `control_state`, `gui_state` et `status_colors`
avant la première fonction qui les utilise (soit avant `main.lua:2499`), et renommer les deux appels
`inventory_controller` en `inv_controller`. À faire **avant** tout patch de migration.

## 8. Risques

| Réf | Risque | Impact | Parade |
|---|---|---|---|
| R1 | Q3 non tranché : offset d'index faux | Récolte lisant les mauvais slots | `check_slots.lua` avant tout code sur L2-11 et L4-25 |
| R2 | `event.pull` filtré mange les `key_down` | Perte du contrôle clavier | Tâche 14 traitée avant 12 et 13 |
| R3 | Fichier unique de 166 Ko | Conflits d'édition | Lots à zones disjointes, application séquentielle |
| R4 | Tâche 27 change les chemins calculés | Régression silencieuse du planificateur | Isolée, faite en dernier, tests revus un par un |
| R5 | Le mod peut être absent | Programme inutilisable | Tâche 04, mode dégradé, testé dans les deux sens |

## 9. Journal

| Date | Événement |
|---|---|
| 2026-09-08 | Analyse de l'usage actuel du driver Gendustry : aucun appel métier, `useGendustryAPI` est un stub |
| 2026-09-08 | Lecture de The-Apiarist-Terminal, extraction des capacités utilisables |
| 2026-09-08 | D1 à D6 actées ; Q1, Q2, Q4, Q5, Q6, Q7 fermées ; Q3 ouverte |
| 2026-09-08 | `check_slots.lua` livré ; fiche de suivi ouverte |
| 2026-09-08 | Workflow 5 agents (un par lot) : 31 patchs conçus, 5 lots sur 5, 0 échec |
| 2026-09-08 | Bugs préexistants B1 à B5 découverts et vérifiés ; B1 et B2 critiques, à corriger avant la migration |
| 2026-09-08 | Ordre d'application arrêté à partir des conflits déclarés (§10) |
| 2026-09-08 | 31 patchs appliqués ; deux défauts d'intégration corrigés (§11) |
| 2026-09-08 | Suite de tests rendue déterministe : 97/97 artefacts stables (§14) |
| 2026-09-08 | Pondération par dominance couverte par 10 vérifications (§15) |
| 2026-09-08 | `extractSpecies` sur mot entier (§16). Seul Q3/H1 reste ouvert. |

## 10. Ordre d'application

Dérivé des conflits déclarés par les agents. Le fichier étant unique, l'ordre est contraignant.

| Rang | Patchs | Motif |
|---|---|---|
| 0 | B1, B2 (+ B3, B4, B5) | Correctifs préexistants, indépendants de la migration |
| 1 | L1-01a | Définit le contrat partagé dont dépendent les quatre autres lots |
| 2 | L3-01, L1-01b, L2-11a, L5-29a | Bloc `config` : ajouts uniquement, chacun reprend l'état courant de la fin de table |
| 3 | L3-02 | Remonte `control_state` — converge avec B1 |
| 4 | L1-28a | `checkGendustryAPI`, ancre disjointe de `useGendustryAPI` |
| 5 | L2-05a, L2-09a, L2-06a | `useGendustryAPI`, `loadMutatron`, phase 2 |
| 6 | L3-03, L3-04, L3-05, L3-06, L3-07 | Multiplexage des signaux puis attentes ; L3-05 après L2-06a |
| 7 | L4-25, puis L3-08, L3-09, L3-10 | `collectApiaryProducts` réécrit avant que L3 encadre ses sites d'appel |
| 8 | L4-22a, L4-22b, L4-23a, L4-23b, L4-23c | Validation et accumulation, après L2 et L3 |
| 9 | L5-26a, L5-29b, L5-26b | Registre d'espèces, GUI, exports |
| 10 | L5-27a à L5-27d, ensemble | Optimiseur. Puis `test_planning.lua` : avec `dominance_weighting = false`, aucun résultat ne doit bouger. Toute divergence est une erreur d'application, pas un effet de la pondération. |

**Contrainte de portée signalée par L3** : `advCall`, `apiaryCall` et les champs de `gendustry`
doivent être déclarés dans la zone `main.lua:52-98`, sinon le bloc d'aides de L3 (inséré vers 3195)
les verra `nil`. C'est exactement le mécanisme de B1.

**Règle à diffuser** : plus aucun `event.pull` filtré dans le fichier, ni sur `key_down` ni sur un
signal machine. Tout passe par `checkContinue` ou `waitForMachineSignal`.

## 11. Vérification de l'application

### Résultat

24 patchs sur 31 se sont appliqués sur ancre. Les 7 échecs étaient tous prévus par l'analyse de
conflits des agents et ont été repris à la main : quatre visaient la même fin de table `config`
(fusionnés en un bloc), deux avaient leur ancre invalidée par les correctifs B1 et B2, un était
couvert par un patch appliqué plus tôt.

### Deux défauts d'intégration trouvés à l'assemblage

| Défaut | Correction |
|---|---|
| La validation d'espèce (L4-22b) s'insérait **avant** l'attente de fin de cycle, qui vivait dans `moveQueenToApiary` (L3-06). `selectAndProduce` rend la main immédiatement, donc la validation lisait une sortie vide et échouait à tous les coups. | L'attente est extraite en `waitForMutatronOutput()`, appelée avant la validation puis réutilisée par `moveQueenToApiary`. Elle rend la main tout de suite si la sortie est déjà là. |
| Le socle L1 lit `config.slot_offset` alors que `refreshGendustrySlots` est écrit **au-dessus** de `local config`. Même mécanisme que B1 : `config` y était un global `nil`, l'offset retombait silencieusement à 1 et toute valeur configurée était ignorée. | `config` est déclaré en tête du fichier, avec `gui_state`, `control_state` et `status_colors`. |

### La suite de tests est non déterministe

`test_planning.lua` produit des artefacts qui diffèrent **entre deux exécutions du même code** :
87 fichiers sur 97 en comparaison brute, 64 sur 97 après tri. La cause est l'ordre d'itération de
`pairs()`, qui décide quel chemin équivalent l'optimiseur retient.

Conséquence : le garde-fou proposé pour la tâche 27 — « aucun artefact ne doit changer » — **est
inapplicable en l'état**. Il aurait signalé une régression à chaque exécution.

### L'invariant utilisé à la place

Extrait de chaque `*_analysis.txt` : `Total steps`, `Can execute`, le verdict de plan, l'ensemble
trié des princesses de départ et les lignes de besoins. Soit 578 lignes.

| Comparaison | Résultat |
|---|---|
| Même code, deux exécutions | identique — l'invariant est fiable |
| Référence avant migration vs après | **identique** — aucune régression de planification |

C'est ce contrôle qu'il faut rejouer, et non la comparaison d'artefacts, le jour où
`config.dominance_weighting` passera à `true`.

### Contrôles complémentaires

- `luac -p` : syntaxe valide après chaque étape.
- `test_planning.lua` : vert avant, pendant et après.
- 28 fonctions inter-lots vérifiées : chacune définie une fois et effectivement appelée.
- Balayage des `local` de portée fichier : plus aucun usage antérieur à la déclaration.

### Ce qui reste à valider en jeu

Rien de tout ceci ne remplace un passage en jeu. Les hypothèses non vérifiées sont listées en §12.

## 12. Hypothèses à valider en jeu

Livrées dans le code, mais non vérifiées. Chacune est isolée à un endroit.

| # | Hypothèse | Où | Comment trancher |
|---|---|---|---|
| H1 | `config.slot_offset = 1` (drivers 0-based, `inventory_controller` 1-based) | `config` | `check_slots.lua`, verdicts `OFFSET`. Le rapport de diagnostic imprime aussi les deux numérotations côte à côte. |
| H2 | L'index passé à `selectAndProduce` est la clé de boucle de `pairs()`, comme dans `breed.lua`, et non `entry.index` | `findMutationIndex` | Un `print` de `listMutations()` avec deux parents chargés |
| H3 | Le `label` d'une mutation est le nom de l'espèce résultante, pas une forme « A + B → C » | `findMutationIndex` | Même `print` |
| H4 | `config.mutagen_reserve_mb = 1000` couvre un cycle | `waitForMutagen` | Lire le `Y` dans `not enough mutagen: X of Y mB` |
| H5 | La ruche émet `apiary_finished` quand la reine est tuée au BeeBee Gun, pas seulement en fin de vie naturelle | `waitForApiaryCycle` | Un cycle observé ; le code couvre déjà les deux cas via `freed` |
| H6 | `config.beebee_gun_retries = 3` à une seconde d'intervalle dépasse le temps de rechargement du Mechanical User | `killQueenWithBeebeeGun` | Observer un tir |
| H7 | `listSpeciesTemplates().name` est le nom d'affichage anglais | registre d'espèces | L'audit au démarrage ; un écart massif signifie qu'il faut n'indexer que l'`uid` |
| H8 | `config.recessive_step_weight = 2` reflète le vrai surcoût d'un trait récessif | pondération | Les mesures de la tâche 21 |
| H9 | La reine sort du Mutatron déjà fécondée | `waitForMatedQueen` | Si non, `apiary_mating_timeout` absorbe le délai |

## 13. Reste à faire

- **Exécuter `check_slots.lua` en jeu et reporter l'offset (H1).** C'est le seul point ouvert.

Les trois chantiers de code sont terminés — voir §14.

## 14. Déterminisme de la suite de tests

`test_planning.lua` produisait des artefacts différents à chaque exécution, ce qui la rendait
incapable de détecter une régression. Cinq sources, toutes dues à `pairs()` dont l'ordre n'est pas
défini et dont le hachage des chaînes est réamorcé à chaque processus Lua.

| Source | Effet | Correction |
|---|---|---|
| `starting_princesses` construit par `pairs()` (`main.lua`) | l'ordre des espèces de départ changeait | tri après construction |
| Fallback des nœuds primaires par `pairs(species_found)` (`executeBreedingTree`) | **l'ordre d'exécution des sous-arbres indépendants changeait** — le tri topologique conserve l'ordre d'entrée entre nœuds qu'il ne peut pas départager | parcours en ordre trié |
| Liste des besoins d'exécution (`test_planning.lua`) | lignes réordonnées | tri des clés |
| Arguments de `drawGUI` dans le journal | clés réordonnées | tri avant concaténation |
| Liste des réutilisations manquées | lignes réordonnées | tri des clés |

Deux valeurs volatiles ont par ailleurs été sorties des fichiers vers la console : la durée de
planification et l'horodatage `Generated:`. Les artefacts étant versionnés, l'horodatage faisait
apparaître 97 fichiers modifiés à chaque exécution et noyait le seul qui comptait.

**Résultat** : 97 artefacts sur 97 identiques octet à octet entre deux exécutions. Un simple
`diff -r` sur `Artifacts/` est désormais un contrôle de régression valide, et l'invariant du §11
n'est plus nécessaire au quotidien.

L'invariant reste identique à la référence d'avant migration : ces tris n'ont rien changé aux plans
calculés, seulement à leur présentation et à l'ordre d'exécution de sous-arbres indépendants.

## 15. Couverture de la pondération par dominance

`testDominanceWeighting` dans `test_planning.lua`, 10 vérifications, sans aucun composant
Gendustry : `setSpeciesTemplateOverride` alimente directement le cache de templates.

- `countTreeCost` est exactement `countTreeSteps` tant que `config.dominance_weighting` est `false`
  — c'est cette égalité qui rend les 97 artefacts valides.
- Une espèce récessive pèse `recessive_step_weight`, une dominante pèse 1.
- Le poids est bien relu depuis la config, pas figé.
- Une espèce inconnue du registre n'est pas pénalisée.
- Le démontage restaure le drapeau et vide les surcharges, sinon tout le reste de la suite
  calculerait des plans différents.

## 16. Correspondance de mot entier

`extractSpecies` passe désormais par `speciesMatchesItem`, le test de mot entier déjà utilisé pour
valider la sortie du Mutatron. La correspondance la plus longue est conservée, donc une espèce en
deux mots l'emporte sur l'espèce en un mot qu'elle contient. Les trois appelants —
`scanInventory` et les deux boucles de comptage de récolte — en bénéficient sans modification.
