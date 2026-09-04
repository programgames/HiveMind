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

Les trois outils publient par **`lib/publish.lua`** : boîte aux lettres fixe si
elle répond, sinon repli sur paste.rs avec l'URL affichée à recopier une fois.
`config.report_mailbox` est **`nil`** depuis le 2026-09-04 : l'ancienne adresse
webhook.site a épuisé son quota. En créer une nouvelle rétablit la boucle
automatique.

`autoreport` remplace les captures d'écran : il sort l'état des machines,
l'inventaire du réseau, la file avec ses erreurs, les slots bruts, et exécute la
file si on lui donne `--run`. Options : `--cancel <id>`, `--multiply Espece:N`,
`--upload`, `--mailbox`.

`probe` exige **`--yes`** pour déplacer quoi que ce soit ; sans lui c'est une
simulation. Il accepte des noms de machines (`probe replicator dna_extractor
--yes`) : sonder un banc déjà mesuré dérange quelque chose qui marche. Il saute
les machines sans `source`, qu'on ne pourrait de toute façon pas atteindre.

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
| **Deux copies de l'installeur dérivent** | `/home/hminstall.lua` et `tools/hminstall.lua` peuvent avoir des listes de fichiers différentes, donc installer des choses différentes. En cas de doute, lancer **`tools/hminstall`** : c'est celle qui vient d'être téléchargée |
| **Un appel de composant bloque le SERVEUR, pas seulement l'ordinateur** | Ne jamais passer un long délai à `waitForPrincess` ou `selectAndProduce` : le monde s'arrête, le watchdog tue l'hôte. Démarrer, puis **sonder** |
| Un répertoire du même nom masque un programme | L'état va dans `/home/hivemind-state`, pas `/home/hivemind` |
| Le CDN de GitHub sert des fichiers périmés plusieurs minutes, **par fichier** | Chaque téléchargement porte `?nocache=<jeton unique>` |
| **Une requête qui aboutit peut avoir échoué** | La boîte aux lettres a répondu **429** (quota d'URL gratuite webhook.site épuisé) toute une soirée pendant que chaque outil annonçait « déposé ». Lire le **statut**, pas seulement le corps. `lib/publish.lua` le fait pour les trois outils et bascule sur paste.rs quand la boîte refuse |
| **`internet.request()` ne fait que CRÉER la requête** | Rien n'est envoyé tant que le handle n'est pas lu. `pcall(internet.request, ...)` puis « envoyé ! » a menti silencieusement dans `discover` et `probe` : les rapports n'arrivaient jamais et rien ne le disait. Toujours `for chunk in handle do end` |

---

## 3. Faits Forestry / Gendustry vérifiés

- **Génome** : 13 chromosomes, `Slot` 0..12, `UID0` actif / `UID1` récessif,
  bloc `Mate` sur les reines. Lisible même avec `IsAnalyzed:0b` — aucun
  Beealyzer nécessaire. Chromosome 9 = `FLOWER_PROVIDER`, affiché « Flowers ».
- **Le génome donne des UID, les samples donnent des noms d'affichage.**
  `forestry.toleranceUp1` dans le génome, `Temperature tolerance: Up 1` sur
  l'étiquette. Comparer les deux exige un test de **suffixe** : en sous-chaîne,
  `floweringSlowest` répond pour `Slow`, soit la valeur opposée. Et tous les
  chromosomes ne suivent pas cette règle (Fertility affiche `2`, son UID dit
  autre chose) — ne jamais conclure sans le dire.
- **L'apiary ne rend pas son slot drone.** Une abeille posée pour lecture y
  reste jusqu'à un retrait manuel ou le prochain cycle.
- **Étiquette d'un Gene Sample** : `Bee Sample - <Chromosome>: <Allèle>`.
  Séparateur ` - `, pas `: `.
- **La bibliothèque, ce sont les gene samples, pas les templates.** Un sample
  porte son contenu dans son nom (`Bee Sample - Species: Cultivated`) : AE2 le
  range, le programme le retrouve, aucun problème. Un **template est un
  consommable** assemblé à la table de craft à partir de samples, qui sont
  consommés. Donc on n'archive pas 500 templates : on garde 500 samples dans
  AE2 et on fabrique un template au besoin. Un coffre vanilla suffit pour les
  quelques templates en cours d'usage.
- **ON PEUT DEMANDER UN OBJET PRÉCIS À AE2, NBT COMPRIS.** Vérifié le
  2026-09-04 par `tools/nbtprobe`, avec contrôle : deux templates de contenus
  différents, deux demandes, deux livraisons exactes. Un pont aveugle aurait
  rendu le même objet aux deux.

  La chaîne : `transposer.store(face, slot, database, page)` photographie un
  objet **qu'on tient physiquement**, NBT compris ; puis
  `me_interface.setInterfaceConfiguration(quai, database, page, 1)` demande au
  réseau **exactement** cet objet. AE2 range par (id, dégâts, NBT) et honore le
  filtre.

  Ce qui bloquait n'était pas AE2 mais **le point de départ** : `me.store(filtre,
  …)` part d'un filtre qui ne sait nommer qu'un id, donc le réseau rend un objet
  quelconque et la photo est celle de ce quelconque. Partir d'un objet en main
  lève tout.

  Conséquences : les templates **peuvent** vivre dans AE2, en nombre illimité.
  Le coffre devient un confort (poser, empreinter, nommer), plus une obligation.
  Et le principe vaut pour tout ce qui ne se distingue que par son NBT — une
  abeille au génome précis, pas seulement « une abeille de cette espèce ».

  Limite : il faut **tenir l'objet une fois** pour le photographier. On ne peut
  pas désigner ce qu'on n'a jamais eu en main.
- **Les Genetic Templates sont opaques** : même id, même étiquette, ne diffèrent
  que par le NBT. Identifiables uniquement par `transposer.store` +
  `database.computeHash` (SHA-256). Ils ne doivent **jamais** entrer dans le
  réseau ME.
- **Les slots d'entrée des machines Gendustry refusent l'extraction
  automatisée.** Vrai sur le Mutatron **et sur les trois machines de
  génétique** : seule la sortie peut être vidée. Un job qui exige une machine
  entièrement vide demande l'impossible et échoue alors qu'il a réussi. Ce qui
  reste en entrée n'est d'ailleurs pas un déchet : un labware ou un sample
  vierge laissé là est exactement ce dont le run suivant a besoin.
- **Le Genetic Transposer rend son slot source** (vérifié en jeu :
  « entree liberee »), le Sampler non. Toujours **essayer l'extraction avant**
  de conclure qu'un slot est bloqué : le comportement diffère d'une machine à
  l'autre et rien ne le documente.
- **Toutes les machines ne consomment pas ce qu'elles lisent.** Le Sampler
  détruit l'abeille ; le **Genetic Transposer garde son sample source** — c'est
  ce qui rend la duplication sûre, et c'est aussi pourquoi faire tourner la
  machine ne libère jamais ce slot. Essayer, puis abandonner vite et le dire.
- **Un slot d'entrée bloqué se vide en laissant la machine le consommer**,
  quand elle le consomme.
  C'est la seule issue, et elle est productive : on fournit les consommables
  manquants, la machine finit, le slot se libère et on récupère un gène de plus.
  Le Mutatron fait exception — une mutation avec les mauvais parents peut ne
  rien produire, donc là le retrait manuel reste nécessaire.
- **Toujours inspecter toutes les entrées avant d'en charger une seule.**
  Fournir les consommables d'abord complète les besoins de la machine autour de
  l'abeille déjà présente, et elle démarre sur la mauvaise avant qu'on ait
  remarqué quoi que ce soit.
- **Les gènes d'une abeille sont fixés à la naissance.** Croiser Wintry × Wintry
  ne créera jamais un allèle qu'aucun parent ne porte. Un meilleur allèle vient
  d'un autre individu sauvage ou d'une autre espèce — **une seule fois** : une
  fois en sample, la bibliothèque le garde et l'Imprinter le propage à toute une
  lignée.
- **Un génome lu est mémorisé** (`library:recordGenome`), allèle dominant et
  récessif. AE2 masque le NBT : cette information ne s'obtient qu'en posant
  l'abeille dans l'apiary, donc elle est écrite sur disque et ne se relit
  jamais. `library:carriersOf(slot, allele)` répond ensuite « qui porte ça »
  sans aucune liste écrite à la main.
- **`x32 — 1 genome(s)` dans le rapport veut dire que les 32 sont identiques.**
  Les échantillonner en boucle ne peut sortir que les mêmes treize allèles.
  Lire le génome (option `g`) avant d'y dépenser treize abeilles.
- **Le pack dit lui-meme quelle espece porte quel allele.** La chaine de
  quetes BetterQuesting 1205-1216, 2269 et 443310250 nomme le porteur de chaque
  allele qu'elle juge optimal. C'est la reponse du pack a « ou trouver ca », et
  elle prime sur tout wiki Forestry. Recopiee dans `config.gene_carriers` :
  Rocky en porte quatre a lui seul (nocturne, vol sous la pluie, cavernicole,
  fertilite 1), Wintry la fertilite 4, Cultivated Lifespan Shortest, Temporal
  Immortal, Robotic la vitesse Robotic, Blizzy Fastest et Longest, Jaded
  Flowering Maximum, Vindictive Territory Largest, Lime la tolerance thermique
  Both 3, Cyan l'hygrometrique, Common les deux tolerances None, Gorgon les
  fleurs « buche ».
  Chercher `bee` dans les quetes ne donne que du bruit ; **chercher `allele`
  trouve les quatorze fichiers en une fois**.
- **`grep -rlo allele config/betterquesting/DefaultQuests/Quests`** donne aussi
  la carte chromosome -> role de ce pack, verifiee : 1 vitesse, 2 longevite,
  3 fertilite, 4 tolerance thermique, 5 nocturne, 6 tolerance hygrometrique,
  7 vol sous la pluie, 8 cavernicole, 9 fleurs, 10 floraison, 11 territoire.
- **Le pack ajoute un raccourci pour le gene Species** : le *Perfected
  Imbuement Fabrial* (`scripts/BeeSpeciesExtractor.zs`), craft shapeless
  drone + `gene_sample_blank` + fabrial, rend **a coup sur** le sample Species
  de ce drone. Cela remplace les ~13 drones que coute un tirage au Sampler.
  Le fabrial se fabrique a la table de craft etendue 7x7 et coute lui-meme six
  gene samples precis. **Pas encore teste en automatisation** : la recette lit
  le NBT de l'entree marquee, donc rien ne garantit qu'un motif AE2 la porte.
- **Le Sampler tire un chromosome au hasard sur 13** : ~13 drones par gène
  Species visé, mais les 12 tirages ratés enrichissent quand même le pool.
- **`waitForPrincess()` échoue si l'apiary porte l'upgrade Automation.**
  L'apiary piloté ne doit pas l'avoir ; celui de production, si.
- **Le partage des roles avec le joueur est trance** : le programme pilote le
  DNA Extractor (il y envoie le surplus de drones) et le Replicator (template
  complet -> abeille). Le **Protein Liquifier** et le **Mutagen Producer** sont
  a la charge du joueur ; le programme se contente de **lire leurs reservoirs
  et d'avertir**. Un `transposer.getFluidInTank(face)` suffit : ces machines
  n'exposent aucun composant, mais le transposer qui deplace deja leurs objets
  voit leurs cuves.
- **Un template pour le Replicator doit etre COMPLET, 13 chromosomes sur 13**,
  gene Species compris — c'est lui qui decide quelle abeille sort. Ce n'est pas
  le meme objet que les templates de profil (11 chromosomes, sans Species), qui
  servent a l'Imprinter.
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

**Cinq transposers** depuis le 2026-09-04, relevés par `tools/discover` :

| Transposer | ME Interface | Machines |
|---|---|---|
| `65d3da44` | `983cd2bd` (4) | Sampler (5), Genetic Transposer (3), Imprinter (2), **Imprinter 2** (1) |
| `95625858` | `4c447a5c` (2) | Mutatron (5), Apiary (3), coffre à templates (4) |
| `c33193aa` | `3418c8dc` (3) | Replicator (2), DNA Extractor (5) |
| `a142f36b` | aucune | Protein Liquifier (4), **coffre à templates** (1, 108 slots) |
| `d28c3d3d` | aucune | Mutagen Producer (2) |

**Deux Imprinters, un profil chacun** (`imprinter` = élevage, face 2, celui
d'origine ; `imprinter_2` = production, face 1). C'est ce qui supprime tout
échange de template : chacun garde le sien à demeure.

⚠️ **`discover` nomme les Imprinters dans l'ordre des faces (0 à 5)**, donc
celui du dessus s'appelle `imprinter` dans son rapport et celui d'origine
`imprinter_2` — l'inverse de la config. Les faces sont la vérité, pas les noms
qu'il génère.

**Le coffre à templates est sur `a142f36b`**, avec le Liquifier, et sans aucune
interface ME. C'est volontaire et suffisant : un template n'est **jamais** tiré
d'AE2 ni livré à une machine (le slot template ne se vide pas). Le programme
ne fait que **regarder** ce coffre pour empreinter son contenu, et regarder
n'exige qu'un transposer.

**Les deux derniers n'ont pas besoin d'interface** : le programme ne leur livre
jamais rien, il lit seulement leur cuve — et un transposer lit une cuve sans
aucune interface. C'est le partage de rôles tranché avec le joueur.

**Les trois interfaces sont identifiées par élimination** : `discover` liste les
`me_interface` adressables (section « INTERFACES ME ADRESSABLES ») mais ne peut
pas dire quel transposer chacune touche. Deux étaient déjà attribuées, donc la
troisième (`3418c8dc`) est celle du banc replicator. Ne jamais deviner : une
mauvaise adresse fait échouer chaque livraison sous la forme « la machine refuse
cet objet ».

**Jamais d'index de position en config** : ajouter un transposer au réseau les
renumérote tous et chaque machine pointe alors vers le mauvais voisin, sans
aucune erreur. Tout se désigne par préfixe d'adresse.

**Adapter ≠ Transposer.** Le transposer déplace des objets ; l'Adapter rend un
bloc adressable comme composant. Une ME Interface sans Adapter est invisible, et
chaque livraison échoue en donnant l'impression que la machine refuse l'objet.

**Un template se remplit dans une TABLE DE CRAFT, pas dans une machine.** Le
mod le dit lui-même (`gendustry.label.template.crafting`) : « Genetic Samples
can be added to a Template. Combine them in any crafting table. Multiple samples
can be added at once. » C'est pourquoi aucun slot d'aucune machine n'accepte un
`gendustry:gene_template`, et pourquoi il n'existe **pas** d'item « template
vierge » : un template vierge est un template à zéro chromosome. Un seul item :
`gendustry:gene_template`.

L'Imprinter refuse un template **vide** — d'où les deux slots qui « refusaient
tout » à la sonde. Avec un template rempli, il entre au **driver 0**, comme la
symétrie le laissait penser. Disposition confirmée : 0 template, 1 labware,
2 abeille, 3 sortie.

**Le template n'est pas consommé par l'Imprinter** (vérifié : il est resté en
slot 0 après trois imprints). Une pose sert toutes les abeilles suivantes.

**Le programme peut maintenant aller chercher un template précis dans le
réseau** — mais jamais par son nom, uniquement par son empreinte, et il vérifie
ce qui arrive avant de le mettre dans une machine. Comparer l'étiquette ne
prouverait rien : elles sont toutes identiques.

Chaîne : le template est posé dans le coffre → le transposer écrit sa **fiche
complète** (NBT inclus) dans un slot du **Database upgrade** → on nomme le
template, l'empreinte et le numéro de slot sont écrits sur disque → plus tard,
le slot de configuration de l'interface ME est réglé **depuis cette fiche**, et
AE2 rend exactement ce template.

**Le nombre de templates demandables = le nombre de slots libres du Database.**
Écrire une fiche exige d'avoir l'objet en main, ce qui n'est plus vrai une fois
qu'il est dans le réseau : la fiche doit donc être prise pendant que le template
est dans le coffre, et y rester. Six slots partent dans les sas de chargement
(`config.docks`), un sert de brouillon → **tier 1 : 2 templates, tier 2 : 18,
tier 3 : 74**. En réduire le nombre de sas libère autant de slots.

**Le slot de brouillon ne doit jamais servir de fiche durable** : l'empreintage
y écrit à chaque passage, donc la fiche précédente serait écrasée et le template
deviendrait indemandable sans le moindre message.

**Un template ne doit jamais entrer dans le réseau ME** — même id, même
étiquette, il y serait perdu parmi les vierges. Pas besoin de coffre pour
autant : les trois machines de génétique partagent un transposer, donc le
template va directement de la sortie du Genetic Transposer vers son entrée,
puis vers l'Imprinter. Un transposer sait déplacer un objet **à l'intérieur du
même inventaire**.

**Une ME Interface par banc, et chacune doit avoir un Adapter.** Approvisionner
un quai ne marche que sur l'interface à laquelle ce quai appartient : configurer
l'une en surveillant le quai de l'autre fait que l'objet n'arrive jamais, et
l'échec se lit comme « la machine refuse cet objet ». `config.interfaces`
associe un index de transposer à une adresse (un préfixe suffit).

**Les trois machines de génétique ont la même forme, mesurée par `tools/probe`** :

| driver | rôle |
|---|---|
| 0 | ce dans quoi on écrit (sample vierge, template) |
| 1 | labware |
| 2 | ce dont on lit (abeille, sample source) |
| 3 | sortie |

La documentation Gendustry disait labware en 3 et sortie en 4 — un slot qui
n'existe pas dans un inventaire de quatre. Ne jamais s'y fier.

**Et la symétrie ne se généralise pas non plus.** Mesuré le 2026-09-04 :
le **Replicator** et le **DNA Extractor** n'ont que **DEUX slots**.

| Machine | driver 0 | driver 1 |
|---|---|---|
| Replicator | template | **sortie** (une *Common Queen* y était) |
| DNA Extractor | abeille (entrée) | labware |

Le Replicator n'a **aucun slot labware**. Il sort une **reine**, pas un drone,
en Ignoble Stock. Le DNA Extractor n'a pas de sortie : l'ADN part en fluide,
seule l'entrée est à alimenter.

Ce qui distingue une entrée d'une sortie ici : la reine est ressortie quand on
l'a demandée, le template est resté. Les entrées Gendustry refusent l'extraction
automatisée, les sorties non — c'est le seul test fiable.

Ancien paragraphe conservé pour mémoire : les correspondances venaient de la documentation
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

Tranché par le guide du pack
(https://gist.github.com/mathisto/5cd71747d14432896007a01450ae48ff), encodé
dans `config.profiles` : **Lifespan** Shortest en élevage / Immortal en
production, **Flowers** = `Flowers`, **Effect** = `None`.

Trois valeurs y contredisent « le maximum partout », volontairement :
Flowering **Slow** (un Industrial Apiary se moque de la pollinisation, et plus
lent = moins de mises à jour de blocs), Territory **Average** (le territoire ne
fait rien dans un apiary), tolérances **Both 3** (Both 5 existe mais coûte
beaucoup pour une amplitude dont rien n'a besoin ici).

**Les deux profils sont ceux du Discord de MeatballCraft**, confirmes trait
pour trait par le joueur, et epingles par un test. Ils ne sont pas a
« ameliorer » : chaque amelioration evidente a une raison de ne pas se faire.
Vitesse **Fast** en elevage (une lignee qui meurt vite n'a pas besoin de
Robotic, qui coute une abeille de plus a attraper), Floraison **Slow**,
Territoire **Average**, tolerances **Both 3** des deux cotes.

**Both 3 supprime les specialty drops** (quetes 1212/1213 : ils exigent un
climat exactement identique, et toute tolerance les empeche). La communaute
choisit quand meme Both 3. Une ligne dediee aux drops rares demanderait un
**troisieme** template, en tolerance None (Common) — ce n'est pas un correctif a
apporter aux deux existants.

**Cave dwelling (chromosome 8) est absent des deux profils**, volontairement :
c'est le treizieme chromosome que la liste ne nomme pas, alors que Nocturne et
Vol-sous-la-pluie y sont. L'ajouter est une modification de la reponse du pack,
pas une correction de la notre.

**Species reste vide** dans les deux profils : c'est ce qui permet d'appliquer
un template à n'importe quelle espèce sans l'écraser. Cave dwelling est absent
du guide aussi ; l'abeille garde le sien.

---

## 7 bis. Ce que dit le code du mod (lu avec javap, pas supposé)

Le jar `mods/gendustry-1.6.5.8-mc1.12.2.jar` s'ouvre comme une archive, et
`javap -p -c` (JDK dans `C:\Program Files\Eclipse Adoptium\...`) liste champs,
méthodes et bytecode. Relevé le 2026-09-04, en accord parfait avec `tools/probe` :

| Tile | Slots déclarés, dans l'ordre |
|---|---|
| `TileImprinter` | `inTemplate`, `inLabware`, `inIndividual`, `outIndividual` |
| `TileReplicator` | `inTemplate`, `outIndividual` |
| `TileExtractor` | `inIndividual`, `inLabware` |

`TileReplicator.canExtractItem` (`func_180461_b`) se réduit à
`index == slots.outIndividual()` — **une seule comparaison** bloque la sortie du
template. Rien de plus subtil.

**Le pack sait patcher ces classes en ZenScript.** `scripts/mixin/` contient
`AllowQueenImprinting.zs`, qui s'injecte au début de
`TileImprinter.isItemValidForSlot` et fait `cir.setReturnValue(true)` : la règle
d'origine n'est jamais exécutée. Le même geste sur `canExtractItem` libérerait
le slot template. Pas de Java, pas de jar — un fichier `.zs`, **côté serveur
uniquement** (l'extraction est décidée là). En réserve, décision du joueur.

## 8. Où en est le projet

Voir `AVANCEMENT.md`, mis à jour à chaque étape.
