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

### 0.1 — Un deuxième Genetic Imprinter

**Problème** : un Imprinter tient un seul template. Avec deux profils
(élevage, production), il faudrait échanger le template à chaque changement —
et le slot template ne se vide pas par automatisation.

**Solution** : deux Imprinters, un template chacun, jamais touchés ensuite.

**Où** : sur une face libre (dessus ou dessous) du transposer qui touche le
Sampler, l'Imprinter actuel et le Genetic Transposer.

**Résultat attendu** : « imprime cette abeille en profil production » devient
un choix de machine, pas une manipulation.

### 0.2 — Un coffre côté génétique

**Problème** : un template posé dans AE2 est perdu parmi ses jumeaux.

**Solution** : un coffre que le transposer voit, où chaque template occupe une
position connue.

**Où** : l'autre face libre du même transposer.

**Un coffre vanilla suffit.** Pas de Storage Drawers : les tiroirs fusionnent
les objets qui se ressemblent, et deux templates se ressemblent parfaitement.
Tu en perdrais définitivement.

### 0.3 — Un coffre côté Replicator

**Où** : une face libre du transposer qui touche le Replicator et l'extracteur
ADN (il lui en reste trois).

**Même rôle** : les templates complets d'espèce, en attente d'entrer dans la
machine.

### 0.4 — Deux templates identiques, pour l'expérience de l'étape 1

Prends deux templates vierges, ajoute-leur **le même gene sample** à la table
de craft. Tu obtiens deux templates au contenu identique, appelons-les T et T′.

- **T** → dans le réseau AE2
- **T′** → dans le coffre de l'étape 0.2

### 0.5 — Envoie-moi la topologie

```
tools/hminstall --clean
tools/discover --upload
```

**Résultat attendu** : je vois les deux coffres et le deuxième Imprinter, et je
les inscris dans la configuration.

---

## Étape 1 — L'expérience « peut-on garder les templates dans AE2 ? »

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

**L'expérience** : je photographie T′ depuis le coffre, je demande au réseau, et
je regarde ce qui arrive.

- Un template **avec un gène dedans** → ça marche, les templates peuvent rester
  dans AE2, en nombre illimité, choisis automatiquement
- Un template **vierge** → ça ne marche pas, on garde les coffres

**Résultat attendu** : une réponse oui/non qui décide de l'étape 2. Une seule
manche. Et si c'est oui, ça vaut aussi pour tout ce qui se distingue par des
données cachées, pas seulement les templates.

---

## Étape 2 — Savoir quel template est lequel

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

## Étape 3 — Le deuxième Imprinter dans la configuration

**Problème** : le programme ne connaît qu'un Imprinter.

**Solution** : deux machines déclarées, un profil associé à chacune.

**Résultat attendu** : tu choisis le profil, le programme choisit la machine.
Plus aucun échange de template.

---

## Étape 4 — Surveiller la cuve du DNA Extractor

**Problème** : je surveille les réservoirs du Mutatron, du Replicator, du
Liquifier et du Mutagen Producer — mais pas celui de l'extracteur. Or c'est
justement celui qui te dirait **qu'il y a du DNA à transférer**.

**Solution** : l'ajouter à la surveillance existante.

**Résultat attendu** : une ligne dans le menu, du genre
`DNA Extractor : 6400/8000 — il y a du DNA a prendre`.

**Coût** : quelques lignes. C'est la tâche la plus rentable du lot.

---

## Étape 5 — Poser un template automatiquement

**Problème** : aujourd'hui tu poses chaque template à la main, sans que le
programme puisse t'aider à trouver le bon.

**Solution** : une fois l'étape 2 faite, le programme prend le template
**par sa position** dans le coffre et le met dans la machine — à condition que
le slot soit **vide**.

**Résultat attendu** : « réplique une Robotic » prend le bon template dans le
coffre et le pose, au lieu de te faire chercher parmi des objets identiques.

**Limite assumée** : ça ne fonctionne que sur une machine vide. Voir la réserve
ci-dessous.

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

## Ce qui est déjà fait

Croisement piloté, accumulation de drones, planification de chaîne, lecture de
génome sans détruire l'abeille, bibliothèque de gènes avec mise à l'abri
automatique, échantillonnage, duplication, impression, campagnes de gènes,
récolte groupée par profil, réplication, alimentation de l'extracteur ADN,
surveillance des réservoirs, file de tâches reprenable après coupure.

Neuf machines reconnues, cinq transposers, trois interfaces ME.
