# HiveMind — feuille de route

Ce document liste **ce qu'il reste à faire, dans l'ordre**. Chaque tâche dit le
problème, la solution, et ce qu'on attend comme résultat.

À jour du 2026-09-04. Avancement chiffré : voir `AVANCEMENT.md`.

---

## Ce qui est stocké où — à lire une fois, ça évite les malentendus

| Objet | Où il vit | Pourquoi |
|---|---|---|
| **Gene samples** | dans AE2 | Leur nom dit leur contenu : `Bee Sample - Species: Cultivated`. Le programme les distingue sans effort. **C'est ça, la bibliothèque.** |
| **Abeilles** | dans AE2 | Identifiées par leur étiquette |
| **Templates** | dans un coffre, **jamais dans AE2** | Tous portent le même nom. Dans le réseau, le programme ne saurait pas lequel il prend |
| **Labware, samples vierges** | dans AE2 | Objets ordinaires, aucun problème |

**Un template n'est pas une archive, c'est un consommable.** On l'assemble à la
table de craft à partir de samples, qui sont consommés. Les samples se
dupliquent au Genetic Transposer, donc refaire un template coûte peu.

Conséquence : le coffre ne contient que **les templates du moment** — quelques
unités. Il n'y aura jamais 500 templates rangés quelque part, il y aura 500
gènes d'espèce dans AE2 et des templates fabriqués au besoin.

---

## Étape 0 — Ce que tu poses en jeu

**Rien ne peut avancer sans ça.** Quatre choses, toutes sur des faces déjà
libres. Aucune machine à déplacer.

### ✅ 0.1 — Un deuxième Genetic Imprinter

**Problème** : un Imprinter tient un seul template. Avec deux profils
(élevage, production), il faudrait échanger le template à chaque changement —
et le slot template ne se vide pas par automatisation.

**Solution** : deux Imprinters, un template chacun, jamais touchés ensuite.

**Où** : sur une face libre (dessus ou dessous) du transposer qui touche le
Sampler, l'Imprinter actuel et le Genetic Transposer.

**Résultat attendu** : « imprime cette abeille en profil production » devient
un choix de machine, pas une manipulation.

### ✅ 0.2 — Un coffre côté génétique

**Problème** : un template posé dans AE2 est perdu parmi ses jumeaux.

**Solution** : un coffre que le transposer voit, où chaque template occupe une
position connue.

**Où** : l'autre face libre du même transposer.

**Un coffre vanilla suffit.** Pas de Storage Drawers : les tiroirs fusionnent
les objets qui se ressemblent, et deux templates se ressemblent parfaitement.
Tu en perdrais définitivement.

### 0.3 — ✅ ~~Un coffre côté Replicator~~ — annulé

**Ne le pose pas.** Je l'avais mis par symétrie, il ne sert à rien.

Un coffre là-bas n'aurait servi qu'à **poser le tout premier template** dans un
Replicator vide. Or le slot template ne se vide jamais par automatisation : une
fois posé, il y reste. Donc ce coffre servirait exactement une fois, pour un
geste qui te prend cinq secondes à la main.

Et si l'expérience de l'étape 1 réussit, il devient inutile même pour ça : les
templates viendraient d'AE2, et **le Replicator a déjà sa propre interface ME**.

### ✅ 0.4 — Deux templates identiques, pour l'expérience de l'étape 1

Prends deux templates vierges, ajoute-leur **le même gene sample** à la table
de craft. Tu obtiens deux templates au contenu identique, appelons-les T et T′.

- **T** → dans le réseau AE2
- **T′** → dans le coffre de l'étape 0.2

### ✅ 0.5 — Envoie-moi la topologie

```
tools/hminstall --clean
tools/discover --upload
```

**Résultat attendu** : je vois les deux coffres et le deuxième Imprinter, et je
les inscris dans la configuration.

---

## Étape 1 — ✅ TRANCHÉE : oui, on peut

**Résultat du 2026-09-04**, avec contrôle : deux templates de contenus
différents, deux demandes, **deux livraisons exactes**. Un réseau aveugle au NBT
aurait rendu le même objet aux deux.

```
slot 1   07a7cfccdb655dba...  ->  EXACT
slot 2   213820db1ec84096...  ->  EXACT
```

**Ce que ça change** : les templates peuvent vivre dans AE2, en nombre
illimité, et le programme peut demander précisément celui qu'il veut. Le coffre
devient l'endroit où on **pose, empreinte et nomme** un template — pas un
entrepôt.

Et le principe vaut pour tout ce qui ne se distingue que par son NBT : une
abeille au génome précis, pas seulement « une abeille de cette espèce ».

**La seule limite** : il faut tenir l'objet une fois pour le photographier. On
ne désigne pas ce qu'on n'a jamais eu en main.

### L'expérience, pour mémoire

**Problème** : tous les templates portent le même nom. Quand le programme en
demande un au réseau, AE2 lui en donne un au hasard. Sur le Replicator, ça
fabriquerait n'importe quelle espèce.

**Ce qu'on sait** : AE2, lui, **sait** les distinguer — il range les objets en
tenant compte de leurs données cachées. C'est le pont OpenComputers qui ne me
montre que le nom.

**L'idée** : ne pas partir du réseau, mais d'un template qu'on tient. Le
transposer sait en faire une « photographie » complète, données cachées
comprises, et la ranger dans un Database upgrade. On demande ensuite au réseau
l'objet décrit par cette photographie.

**L'expérience** : `tools/nbtprobe`. Il photographie T′ depuis le coffre,
demande le même au réseau, et compare les **empreintes** — pas les étiquettes,
qui sont identiques par construction.

```
tools/nbtprobe --upload          liste le coffre, ne bouge rien
tools/nbtprobe --yes --upload    tente la demande
```

Sans `--yes` il ne fait que lister le coffre avec l'empreinte de chaque
template, ce qui est déjà utile. Avec `--yes`, un template sort du réseau et y
est **rendu ensuite, quel que soit le verdict**.

- Un template **avec un gène dedans** → ça marche, les templates peuvent rester
  dans AE2, en nombre illimité, choisis automatiquement
- Un template **vierge** → ça ne marche pas, on garde les coffres

**Résultat attendu** : une réponse oui/non qui décide de l'étape 2. Une seule
manche. Et si c'est oui, ça vaut aussi pour tout ce qui se distingue par des
données cachées, pas seulement les templates.

---

## Étape 2 — ✅ FAIT : savoir quel template est lequel

**Problème** : même dans un coffre, si tu déplaces un template à la main, mon
index devient faux **en silence**, et j'imprime n'importe quoi sur tes abeilles.

**Solution** : chaque template reçoit une **empreinte** — un code calculé à
partir de son contenu réel, différent pour deux templates différents. Le
mécanisme est déjà vérifié en jeu. Au démarrage je recalcule les empreintes et
je compare à ce que j'avais noté.

**Résultat attendu** : le programme sait dire « slot 3 = template complet
Robotic », et **refuse d'imprimer** si le coffre ne correspond plus à son index,
au lieu d'écrire des gènes au hasard sur une abeille.

---

## Étape 3 — ✅ FAIT : le deuxième Imprinter

**Problème** : le programme ne connaît qu'un Imprinter.

**Solution** : deux machines déclarées, un profil associé à chacune.

**Fait** : l'option `f` demande quelle machine, affiche le profil de chacune et
dit laquelle a son slot template vide. La tâche retient la machine choisie —
sans ça, elle imprimait toujours le même profil quoi qu'on demande.

---

## Étape 4 — ✅ FAIT : surveiller la cuve du DNA Extractor

**Problème** : je surveille les réservoirs du Mutatron, du Replicator, du
Liquifier et du Mutagen Producer — mais pas celui de l'extracteur. Or c'est
justement celui qui te dirait **qu'il y a du DNA à transférer**.

**Solution** : l'ajouter à la surveillance existante.

**Fait**, avec une nuance qui manquait : cette cuve **se remplit** au lieu de se
vider. La signaler comme « plus d'ADN » aurait été exactement l'inverse de la
vérité. Trois états distincts :

- `DNA Extractor : 6400 de ADN a transferer` — il y a de quoi prendre
- `DNA Extractor : cuve pleine — il ne produira plus rien tant que tu n auras pas vide`
- rien du tout si elle est vide, ce qui est normal

---

## Étape 5 — ✅ FAIT : poser un template automatiquement

**Problème** : aujourd'hui tu poses chaque template à la main, sans que le
programme puisse t'aider à trouver le bon.

**Solution** : une fois l'étape 2 faite, le programme prend le template
**par sa position** dans le coffre et le met dans la machine — à condition que
le slot soit **vide**.

**Fait** : le Replicator **et** les deux Imprinters proposent la liste des
templates nommés quand leur slot est vide, et vérifient l'empreinte de ce qui
arrive avant de le laisser entrer dans la machine.

**Limite assumée** : ça ne fonctionne que sur une machine vide, puisque le slot
template ne se vide jamais. Voir la réserve ci-dessous.

---

## En réserve — le mixin qui libère le slot template

**Problème** : le Replicator refuse de rendre son template. Mesuré en jeu, puis
confirmé dans le code du mod : `canExtractItem` répond oui **uniquement** pour
le slot de sortie. Donc changer un template reste manuel.

**Solution possible** : un fichier de vingt lignes dans `scripts/mixin/` du
serveur, qui intercepte cette décision et répond oui aussi pour le template.
Ton pack fait **déjà exactement ça** sur l'Imprinter, avec
`AllowQueenImprinting.zs` — le modèle existe et fonctionne.

**Ce que ça coûte** :
- ça change le comportement du mod pour tout le monde sur le serveur
- ça vit dans les fichiers du serveur, pas chez toi
- un mixin mal ciblé empêche le jeu de démarrer (réversible : on retire le
  fichier)

**Décision** : en attente. Tu as dit qu'une réplication par espèce, faite une
fois à la main, ne te gênait pas. Dans ce cas ce fichier résout un problème que
tu n'as pas. On le fera si l'échange de templates devient une corvée
quotidienne.

---

## Le vrai travail restant : attraper sept espèces

Aucun code ne remplace ça. Les 11 allèles des deux profils viennent de sept
abeilles :

| Espèce | Ce qu'elle apporte |
|---|---|
| **Rocky** | Never Sleeps, Tolerates Rain, Fertility 1 — **trois d'un coup** |
| Cultivated | Lifespan Shortest |
| Wintry | Fertility 4 |
| Lime (la Forestry) | Temperature Tolerance Both 3 |
| Cyan | Humidity Tolerance Both 3 |
| Robotic | Speed Robotic |
| Temporal | Lifespan Immortal |

Les quatre autres valeurs — Speed Fast, Flowers, Flowering Slow, Territory
Average, Effect None — sont celles d'abeilles ordinaires que tu as déjà.

**Dès que tu as les drones**, l'option `t` du menu met en file toutes les
campagnes nécessaires, d'un coup.

---

## Ce qu'il reste, au 2026-09-04

**La feuille de route est terminée.** Toutes les étapes 0 à 5 sont faites, et le
mixin reste en réserve sur ta décision. Il ne reste que trois choses, dont une
seule est du code.

### 1. Vérifier en jeu ce qui n'a jamais tourné

Sept options ont été écrites et testées hors du jeu, **jamais exécutées dedans** :

| Option | Ce qu'on vérifie |
|---|---|
| `n` Nommer les templates | ✅ déjà fait, les empreintes sortent |
| `r` Fabriquer une reine | le template demandé au réseau arrive et entre dans la machine |
| `x` Détruire des drones → ADN | l'extracteur accepte une abeille et la consomme |
| `t` Chasser ce qui manque | la file se remplit avec les bonnes chasses |
| `f` sur deux Imprinters | la bonne machine reçoit l'abeille |
| `i` Chasser le gène d'espèce | une chasse par espèce en stock |
| Les cuves dans le bandeau | ADN, mutagène, protéines lus par le transposer |

C'est le seul risque réel restant : les slots sont mesurés, mais « mesuré » n'est
pas « a marché ».

**Une tâche est déjà bloquée** : `#24 replication d une reine — rien en sortie
apres 121 s`. À regarder en premier, c'est probablement l'ADN ou le template.

### 2. Attraper sept espèces — c'est le gros du travail restant

Aucun code ne remplace ça. Voir la section ci-dessous.

### 3. Assembler les deux templates

À la table de craft, une fois les gènes réunis. Les deux dernières cases de
`AVANCEMENT.md`, et elles ne se cochent que par de la collecte.

---

## Ce qui est déjà fait

Croisement piloté, accumulation de drones, planification de chaîne, lecture de
génome sans détruire l'abeille, bibliothèque de gènes avec mise à l'abri
automatique, échantillonnage, duplication, impression, campagnes de gènes,
récolte groupée par profil, réplication, alimentation de l'extracteur ADN,
surveillance des réservoirs, file de tâches reprenable après coupure.

Neuf machines reconnues, cinq transposers, trois interfaces ME.
