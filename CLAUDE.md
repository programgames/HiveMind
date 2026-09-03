# HiveMind — mémoire du projet

Automatisation de la génétique des abeilles (Forestry / Gendustry) pilotée par un
ordinateur OpenComputers, dans MeatballCraft 1.12.2.

Ce fichier existe pour qu'une nouvelle session reparte sans rien redécouvrir.
**Tout ce qui est écrit ici a été vérifié en jeu**, souvent au prix d'un bug.
Ne rien y ajouter qui n'ait pas été constaté.

---

## 1. Comment on travaille

Le joueur est sur un **serveur** : le monde local (`saves/New World`) date de
juillet et ne contient aucun dossier `opencomputers`. **Impossible de lire les
fichiers de l'ordinateur depuis le disque.** Tout passe par le réseau.

Boucle de travail :

```bash
tools/hminstall                                  # met à jour depuis GitHub
tools/autoreport --run --upload                  # collecte, agit, publie
```

`autoreport` remplace les captures d'écran : il sort l'état des machines,
l'inventaire du réseau, la file avec ses erreurs, les slots bruts, et exécute la
file si on lui donne `--run`. Options : `--cancel <id>`, `--multiply Espece:N`,
`--upload`, `--mailbox`.

Les outils vivent dans `tools/` qui **n'est pas dans le PATH d'OpenOS** : il faut
écrire `tools/autoreport`, jamais `autoreport`.

### Conventions de code

- Commentaires et docstrings **en anglais**, messages utilisateur **en français
  sans accents** (la police d'OpenComputers ne les rend pas).
- Chaque correctif vient avec un test qui **échoue sans lui** — le vérifier en
  restaurant temporairement l'ancien fichier.
- Les commentaires expliquent *pourquoi*, avec le symptôme réel observé.
- Aucun `.md` de compte rendu créé sans demande ; la doc vit ici et dans
  `FEUILLE-DE-ROUTE.md`.

---

## 2. Pièges d'OpenComputers vérifiés

| Fait | Conséquence |
|---|---|
| Les méthodes de composants sont des **tables avec `__call`**, pas des fonctions | Ne jamais tester `type(x) == "function"` ; laisser `pcall` décider |
| `os.time()` rend l'heure Minecraft (~72× le temps réel) | Utiliser `computer.uptime()` pour tout délai |
| `package.loaded` persiste **toute la session du shell** | Purger `hivemind` *et* `lib.*` avant de recharger, sinon on lit l'ancienne version |
| `loadfile` préfixe le chunk avec `=` et non `@` | `source:match("^[@=](.*)$")` pour retrouver le fichier courant |
| Le shell n'a ni boucle `for` ni `&&` | D'où l'installeur en Lua |
| `filesystem.makeDirectory` exige un chemin **absolu** et ne crée pas les parents | Résoudre via `shell.resolve` |
| `install` est une commande OpenOS existante | Notre installeur s'appelle `hminstall` |
| **Un appel de composant bloque le SERVEUR, pas seulement l'ordinateur** | Ne jamais passer un long délai à `waitForPrincess` ou `selectAndProduce` : le monde s'arrête, le watchdog tue l'hôte. Démarrer, puis **sonder** |
| Un répertoire du même nom masque un programme | L'état va dans `/home/hivemind-state`, pas `/home/hivemind` |
| Le CDN de GitHub sert des fichiers périmés plusieurs minutes, **par fichier** | Chaque téléchargement porte `?nocache=<jeton unique>` |

---

## 3. Faits Forestry / Gendustry vérifiés

- **Génome** : 13 chromosomes, `Slot` 0..12, `UID0` actif / `UID1` récessif,
  bloc `Mate` sur les reines. Lisible même avec `IsAnalyzed:0b` — aucun
  Beealyzer nécessaire. Chromosome 9 = `FLOWER_PROVIDER`, affiché « Flowers ».
- **Étiquette d'un Gene Sample** : `Bee Sample - <Chromosome>: <Allèle>`.
  Séparateur ` - `, pas `: `.
- **Les Genetic Templates sont opaques** : même id, même étiquette, ne diffèrent
  que par le NBT. Identifiables uniquement par `transposer.store` +
  `database.computeHash` (SHA-256). Ils ne doivent **jamais** entrer dans le
  réseau ME.
- **Les slots d'entrée des machines Gendustry refusent l'extraction
  automatisée.** Une abeille laissée dans l'entrée du Mutatron par une tâche
  échouée ne peut être retirée que **à la main**. C'est une contrainte du mod,
  pas un bug à corriger.
- **Le Sampler tire un chromosome au hasard sur 13** : ~13 drones par gène
  Species visé, mais les 12 tirages ratés enrichissent quand même le pool.
- **`waitForPrincess()` échoue si l'apiary porte l'upgrade Automation.**
  L'apiary piloté ne doit pas l'avoir ; celui de production, si.
- **Le Replicator produit toujours de l'Ignoble**, et l'Imprinter tue parfois
  les Ignoble → réplication réservée aux drones.
- **MeatballCraft a réécrit l'arbre** : Common = basalte + eau (15 %),
  Cultivated = Mystical + Common (12 %). Ne pas se fier au wiki Forestry.
- Le driver de l'apiary expose trois méthodes non documentées :
  `listAllSpecies()` (329 entrées, **incomplet**), `getBeeParents(name)`
  (plusieurs chemins par espèce, avec chance et conditions spéciales), et
  `getBeeBreedingData()` qui rend `nil`.

---

## 4. Topologie réelle

Deux transposers depuis que le banc de génétique existe. **L'ordre compte** :
les machines nomment un transposer par son index.

| Transposer | Index | Machines |
|---|---|---|
| `65d3da44` | 1 | Sampler (5), Genetic Transposer (3), Imprinter (2), ME Interface (4) |
| `95625858` | 2 | Mutatron (5), Apiary (3), coffre à templates (4), ME Interface (2) |

**Une ME Interface par banc, et chacune doit avoir un Adapter.** Approvisionner
un quai ne marche que sur l'interface à laquelle ce quai appartient : configurer
l'une en surveillant le quai de l'autre fait que l'objet n'arrive jamais, et
l'échec se lit comme « la machine refuse cet objet ». `config.interfaces`
associe un index de transposer à une adresse (un préfixe suffit).

Les correspondances de slots du banc de génétique viennent de la documentation
Gendustry et **la première lecture réelle les a démenties**. Rien ne doit s'y
fier avant confirmation par le diagnostic.

Un seul transposer `95625858`, en `lib/config.lua` :

| Élément | Face machine | Face source |
|---|---|---|
| Mutatron (`advmutatron`) | 5 | 2 |
| Apiary de croisement (`industrial_apiary`) | 3 | 2 |
| Coffre à templates | 4 | — |

**`slot_offset = 1`** : le driver du terminal compte les slots depuis 0,
OpenComputers depuis 1. Se tromper décale tout sans lever d'erreur.

Chaîne AE2 : `me.store(filtre, db, slot)` → `setInterfaceConfiguration(quai, db,
entrée, taille)` → `transposer.transferItem`. Attention :

- `store()` renvoie si le slot de base était **déjà occupé**, pas le succès.
- `store()` rend `false` quand le filtre ne correspond à rien.
- Il faut vider le slot de base, écrire, puis **relire pour comparer**.

Les sept machines génétiques sont déclarées `enabled = false` : rien n'est câblé.

---

## 5. Architecture

```
hivemind.lua        menu, bootstrap, actions
lib/config.lua      topologie, slots, réglages
lib/genome.lua      lecture NBT, chromosomes, étiquettes de samples
lib/state.lua       persistance atomique (temp + rename)
lib/species.lua     registre vivant interrogé au jeu, index inverse
lib/jobs.lua        file persistante, étapes vérifiées avant d'agir
lib/transport.lua   couche AE2 + transposer
lib/machines.lua    Machine, Mutatron, Apiary
lib/library.lua     bibliothèque de gènes, index des templates
lib/breeding.lua    croisement en 7 étapes
lib/multiply.lua    accumulation de drones, en boucle
lib/planner.lua     chaîne de croisements vers une espèce cible
```

**Le principe qui rend la reprise fiable** : chaque étape déclare `verify()`
avant `run()`. Le numéro d'étape enregistré n'est qu'un indice ; c'est le monde
qui décide. Une coupure entre « la reine est produite » et « je l'ai noté » fait
sauter l'étape au lieu de dépenser une seconde dose de mutagène.

`RETRY` veut dire « attends », pas « échec » : la tâche est mise de côté et la
file **continue avec les suivantes**. Seule une panne définitive arrête la passe.

---

## 6. Pièges internes déjà payés

- `findAll` ignorait `spec.label` alors que `find` le respectait → compter les
  « Common Drone » comptait tous les drones du réseau (37 au lieu de 4).
- Les abeilles laissées dans la sortie de l'apiary sont **invisibles aux
  tâches**, qui cherchent dans le réseau ME et les déclarent manquantes.
  D'où la récolte systématique avant toute exécution.
- Deux abeilles différentes ne partagent pas un slot : livrer sans vider
  d'abord ne déplace rien, et l'erreur accuse le mauvais coupable.
- Une étape sautée par `verify` laissait la tâche marquée `running` sur disque.
- `capture()` dans `autoreport` avalait « attempt to call a nil value » : une
  section vide se lit comme « rien à signaler » alors que l'appel n'a pas eu
  lieu. Toujours remonter l'échec.

---

## 7. Décisions verrouillées avec le joueur

| Sujet | Décision |
|---|---|
| Transport | Réseau AE2 déjà en place |
| Objectif | Gène Species de chaque espèce + un jeu optimal des 12 autres |
| Autonomie | File de tâches persistante, reprenable après crash |
| Machines | Imprinter prioritaire, Replicator en second |
| Profils | Deux templates (élevage / production), allèles à trancher ensemble |
| Énergie | Pas de gestion active : on attend, on signale si c'est long |
| Matériel | Tier max, autant d'apiaries et d'upgrades que nécessaire |

Restent à trancher : **Lifespan**, **Flower Provider**, **Effect**.

---

## 8. Où en est le projet

Voir `AVANCEMENT.md`, mis à jour à chaque étape.
