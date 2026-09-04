# HiveMind — feuille de route

Ce document dit **ce qu'il reste à faire, dans l'ordre**, et pour qui.

Réécrite le 2026-09-04, **phase 4 codée le même jour** — voir les ✅ ci-dessous.
Les étapes 0 à 5 de l'ancienne version sont toutes faites ; ce qui en reste
utile est repris en fin de document. Avancement chiffré : `lua progress.lua`.

---

## Ce qu'on construit, en une phrase

Un joueur qui n'a jamais lu une ligne de code lance le programme, dit **« je
veux cette abeille »**, et l'obtient.

Tout le reste — croisements, gènes, machines, templates — est un moyen. Le
moteur qui pilote les machines est **fait et prouvé en jeu**. Ce qui manque,
c'est le **parcours** : l'ordre des choses, et un programme qui le connaît à la
place du joueur.

---

## Le parcours, en quatre étapes

Chacune est une option du menu principal. Chacune **refuse de démarrer** tant
que la précédente n'est pas passée, et dit pourquoi.

```
  1  Verifier l installation           machines, faces, slots, cuves, consommables
  2  Constituer la base                especes sauvages + leur gene d espece
  3  Fabriquer le template d elevage   les 11 genes, dans l ordre
  4  Obtenir une abeille               dis laquelle, je fais tout

  6  Avancer les taches en cours       journal en direct, et les gestes a faire
  9  Outils avances                    les 17 options d origine, intactes
```

**Rien n'est supprimé.** Les options d'aujourd'hui partent dans `9` et gardent
leur touche et leur comportement. Ce qui change, c'est qu'un joueur n'a plus
besoin de les connaître.

La file garde la touche `6` : treize écrans finissent par « Choisis 6 pour la
faire tourner », et la renuméroter aurait rendu chacun d'eux faux.

---

## Décisions prises le 2026-09-04

| Question | Décision |
|---|---|
| Jusqu'où va la collecte des espèces sauvages | **Toutes les espèces de base du pack.** Balayage complet |
| Comment on sauve un gène d'espèce | **Au Sampler.** Le fabrial reste en réserve |
| Quand une tâche a besoin du joueur | **Elle s'arrête, affiche le geste, attend la validation, reprend** |
| « Obtenir une abeille » avant le template | **Bloquée.** Parcours strictement guidé |

### Ce que la première décision coûte, chiffré

Compté sur `lib/data/mutations.lua` : **32 espèces de base** pour 304 espèces
produites. Le jeu en expose 329, donc il y en aura un peu plus.

Au Sampler, un gène Species coûte **~13 drones pour 65 % de chance**, ~29 pour
90 %. Pour 32 espèces : **entre 400 et 900 drones**, qu'il faut d'abord produire
espèce par espèce, à **un drone par cycle** d'apiary (rendement observé, pas
théorique).

C'est assumé, mais ça impose deux choses au code :

1. **Les espèces sont ordonnées par ce qu'elles débloquent.** Meadows ouvre 13
   espèces, Valiant et Forest 11 chacune, Ardite 1. Personne ne commence par
   Ardite.
2. **Rien n'oblige à finir.** L'étape 2 se grignote, et l'étape 3 ne l'attend
   pas — voir l'arbitrage ci-dessous.

### L'arbitrage sur l'ordre — à corriger si c'est faux

Le template d'élevage doit venir **le plus vite possible**, et l'étape 2 doit
être **exhaustive**. Les deux ensemble enfermeraient le template derrière 32
collectes, ce qui est l'inverse du but.

Donc l'étape 2 a **deux parties** :

- **obligatoire** : les espèces sauvages dont la chaîne du template a besoin.
  C'est elle, et elle seule, qui tient la porte de l'étape 3 ;
- **continue** : les 32, qu'on grignote quand on a des drones à dépenser. Elle
  ne bloque jamais rien.

### « Sans parents » n'est pas « trouvable dans la nature »

Sur les 32 espèces de base, une bonne partie ne sort d'aucune ruche sauvage :
Shulking, Deep Learner, Mad Scientist, Oblivion, Ardite, Oxygen, Sorcerous,
Armored viennent d'une quête, d'un craft ou d'un mob. **Deux listes séparées**,
sinon le programme envoie le joueur chercher l'introuvable et il ne le trouvera
jamais.

Le programme ne peut pas deviner de quel côté classer une espèce. La
répartition se fait à la main, une fois, en config — et une espèce non classée
est annoncée comme telle plutôt que rangée au hasard.

---

## Ce qu'on sait déjà faire, et qui sert directement

Le moteur n'est pas à réécrire. Ce qui suit est **prouvé en jeu** :

- l'arbre généalogique vient du jeu en direct : `listAllSpecies()` (329) et
  `getBeeParents()` (tous les chemins, avec pourcentage et conditions) ;
- `lib/planner.lua` remonte l'arbre seul jusqu'à ce qu'on possède, choisit
  entre plusieurs chemins, et repère les espèces de base absentes ;
- un croisement complet s'enchaîne sans intervention (tâche #4) ;
- une campagne de gène s'arrête au bon tirage (`Species = Forest` en 6 abeilles
  sur 13 budgétées) ;
- l'impression fonctionne : trois Forest Drones devenus Cultivated Drones ;
- la file de tâches reprend après une coupure, étape par étape.

**Trois réserves** pèsent sur ce qui suit :

1. `listAllSpecies()` est **incomplète** — une espèce absente ne sera jamais
   proposée ;
2. les parents se demandent **une espèce à la fois**, et un appel de composant
   **gèle le serveur** : un balayage complet doit se faire par lots, en cache ;
3. certains chemins ont des **conditions** (bloc de fondation, biome) que le
   Mutatron ne remplira jamais seul. Le planner les déclasse ; il faudra les
   annoncer au joueur au lieu de les subir.

---

## Phase 4 — le parcours joueur

Six chantiers. Le 4.2 conditionne les trois suivants : à faire en premier.

### ✅ 4.1 — Un seul écran de validation d'installation

**Problème** : la vérification existe, éclatée en trois outils hors menu
(`discover`, `probe`, l'option `2`) et un bandeau de cuves que personne ne lit
comme un contrôle. Un joueur qui vient de poser ses machines n'a aucun moyen de
savoir s'il a fini.

**Solution** : une option qui passe tous les contrôles et rend **un verdict**.

- chaque machine déclarée répond, et sur la bonne face ;
- la forme des slots correspond à ce que la config annonce ;
- chaque interface ME livre réellement sur son banc (une livraison test) ;
- les cuves — mutagène, protéines, ADN — ont du contenu, et l'ADN est lu dans
  le bon sens (elle se **remplit**, elle ne se vide pas) ;
- labware et samples vierges au-dessus d'un seuil ;
- verdict : « installation validée », ou la liste des gestes à faire.

**Résultat attendu** : un joueur sait en un écran s'il peut commencer.

### ✅ 4.2 — Le statut « en attente du joueur »

**Problème** : aujourd'hui une tâche qui a besoin d'une main **échoue**. Slot
d'entrée bouché, cuve vide, consommable absent : le message est juste, mais la
tâche est morte et il faut la relancer soi-même. C'est exactement ce qui rend le
programme pénible.

**Solution** : un troisième résultat d'étape, à côté de `DONE` et `FAILED`.

- `jobs.NEEDS_PLAYER`, accompagné du **geste exact** : « retire l'abeille du
  slot 2 du Sampler, puis valide » ;
- la file s'arrête dessus, l'affiche, et **reprend à la même étape** après
  validation — la persistance le garantit déjà ;
- les causes connues y sont branchées : entrée bouchée (Mutatron), cuve vide,
  labware ou sample vierge manquant, abeille absente du réseau ;
- une cause inconnue reste un échec, elle ne se déguise pas en attente.

**Résultat attendu** : plus aucune tâche ne meurt d'un geste de cinq secondes.
C'est le chantier qui rend les trois suivants supportables.

### ✅ 4.3 — Constituer la base *(sauf la table des origines)*

**Problème** : le programme sait dire « espèce de base absente » une par une,
jamais « voilà tout ce que tu dois attraper ». Et rien ne sauve le gène d'espèce
d'une abeille nouvellement obtenue : c'est une action manuelle, après coup,
qu'on oublie — et l'espèce est à refaire.

**Solution** :

- balayage de toutes les espèces, par lots, en cache disque, pour établir la
  liste des espèces sans parents ;
- séparation **ruche sauvage** / **autre origine**, depuis une table en config ;
- écran « ce que tu dois attraper », ordonné par le nombre d'espèces que chacune
  débloque, avec ce qu'elle apporte ;
- **le gène d'espèce est sauvé automatiquement** à la fin de chaque croisement
  réussi, pas sur demande ;
- le programme sait ce qui est déjà sauvé et ne le rechasse pas.

**Résultat attendu** : une espèce obtenue une fois ne se reperd plus.

### ✅ 4.4 — Fabriquer le template d'élevage

**Problème** : l'option `e` dit les gènes manquants et qui les porte ; l'option
`t` met en file les chasses. Mais les porteurs — Rocky, Wintry, Lime, Cyan —
**ne sont pas en stock**, et rien ne calcule comment les obtenir. Le planner sait
le faire pour *une* espèce, jamais pour une liste.

**Solution** :

- **plan combiné** : les chaînes de croisement de tous les porteurs manquants,
  fusionnées, dédupliquées, ordonnées ;
- écran d'avancement du template : les 11 gènes, et où en est chacun ;
- enchaînement automatique croisement → chasse du gène, sans retour au menu ;
- le geste final — l'assemblage à la table de craft — **annoncé explicitement**
  avec la liste des samples à réunir. Le mod l'impose, on ne le contournera pas.

**Résultat attendu** : le joueur choisit une fois, et ne revient que pour le
craft final.

### ✅ 4.5 — Obtenir une abeille

**Problème** : l'option `5` est déjà la plus aboutie du programme — chaîne
complète, accumulation des drones manquants programmée seule. Il lui manque
trois choses pour être *l'*option du produit.

**Solution** :

- **refus argumenté** tant que le template d'élevage n'est pas assemblé, avec
  ce qui manque exactement ;
- imprint du profil élevage sur la lignée **avant** de lancer la chaîne — c'est
  tout l'intérêt d'avoir fait le template ;
- le gène d'espèce de **chaque espèce traversée** est sauvé au passage (4.3) ;
- journal en direct des croisements, avec ce qui reste à faire.

**Résultat attendu** : « je veux Imperial » et c'est tout.

### ✅ 4.6 — Le menu

**Problème** : quinze options qui ne disent pas dans quel ordre les prendre.

**Solution** :

- quatre options principales, « avancer les tâches », un sous-menu avancé ;
- les quinze options actuelles déplacées telles quelles, **aucune perdue** ;
- chaque option principale annonce son prérequis et refuse proprement ;
- la suggestion contextuelle en tête d'écran dit la **prochaine chose à faire**.

**Résultat attendu** : un joueur qui n'a rien lu sait quoi faire.

---

## Ce que la phase 4 a donné, et ce qu'elle n'a pas donné

**Fait, avec un test qui échoue sans le correctif :**

- `lib/jobs.lua` a un troisième résultat d'étape, `NEEDS_PLAYER`. Une tâche qui
  bute sur un slot Gendustry, une cuve vide ou un consommable absent **ne meurt
  plus** : elle s'arrête, affiche le geste à l'impératif, ne consomme aucune
  tentative, et reprend à la même étape après validation. Sept causes sont
  branchées dans `genetics.lua` et `breeding.lua`.
- `lib/checkup.lua` (nouveau) passe cinq familles de contrôles et rend **un
  verdict**. Il ne déplace rien : un contrôle qui vide un slot pour voir s'il
  peut est un contrôle qui casse un banc qui marchait. Le contrôle des
  interfaces compare la config au réseau au lieu de faire une livraison test —
  même diagnostic, aucun effet de bord.
- `species.lua` sait balayer les 329 espèces **par tranches** (un appel de
  composant gèle le serveur) et en tirer la liste des espèces de base, ordonnée
  par ce que chacune débloque.
- **Le gène d'espèce part en file tout seul** à la fin de chaque croisement
  réussi, si l'espèce est nouvelle et qu'il y a assez de drones. C'est l'étape 8
  du cycle de croisement, et elle n'échoue jamais : le croisement a réussi.
- `planner.planMany` fusionne les chaînes de plusieurs cibles en une seule liste
  ordonnée, sans planifier deux fois un croisement qu'une autre branche a déjà
  fait.
- Le menu tient en **quatre options plus la file**. Les quinze anciennes sont
  sous `9`, avec leurs touches d'origine. `6` reste la file, parce que treize
  écrans finissent par « Choisis 6 » et que les renuméroter aurait rendu chacun
  faux.

**Pas fait, et pour une raison :**

- `config.base_origins` est **vide**. « Sans parents » n'est pas « trouvable en
  ruche », et rien dans l'API du jeu ne dit d'où sort une espèce. Elle se
  remplit en jeu, une observation à la fois. En attendant, l'écran affiche
  « origine a confirmer », ce qui est la vérité.

**Jamais exécuté en jeu.** Les trois nouveaux écrans tournent contre un
OpenComputers simulé, la suite de tests est verte (14 fichiers), et c'est tout
ce que ça prouve. Voir la section suivante.

---

## Le risque restant qui n'est pas du code

Sept options ont été écrites et testées hors du jeu, **jamais exécutées
dedans**. « Mesuré » n'est pas « a marché ».

| Option | Ce qu'on vérifie |
|---|---|
| `r` Fabriquer une reine | le template demandé au réseau entre dans la machine |
| `x` Détruire des drones → ADN | l'extracteur accepte une abeille et la consomme |
| `t` Chasser ce qui manque | la file se remplit avec les bonnes chasses |
| `f` sur deux Imprinters | la bonne machine reçoit l'abeille |
| `i` Chasser le gène d'espèce | une chasse par espèce en stock |
| Les cuves dans le bandeau | ADN, mutagène, protéines lus par le transposer |
| `1` Vérifier l'installation | les tailles d'inventaire réelles, et donc le verdict |
| `2` Constituer la base | le balayage des 329 espèces, par tranches, sans geler le serveur |
| `3` Fabriquer le template | la chaîne combinée sur le vrai arbre |
| Le statut « attend un geste » | qu'une tâche reprenne vraiment après validation |

**Une tâche est bloquée depuis le 2026-09-04** : `#24 replication d une reine —
rien en sortie apres 121 s`. À regarder en premier : probablement l'ADN ou le
template.

Ces vérifications sont le contenu réel du chantier 4.1 : un écran de validation
qui n'a jamais rien validé ne vaut rien.

---

## En réserve — décidé, pas abandonné

### Le fabrial, qui diviserait l'étape 2 par treize

Le pack ajoute le *Perfected Imbuement Fabrial* (`scripts/BeeSpeciesExtractor.zs`) :
drone + `gene_sample_blank` + fabrial, en craft shapeless, rend le sample
d'espèce **à coup sûr**. Un drone au lieu de treize.

**Jamais testé en automatisation** : la recette lit le NBT de l'entrée marquée,
et rien ne garantit qu'un motif AE2 le porte. Le fabrial se fabrique à la table
7×7 et coûte lui-même six gene samples précis.

**Décision du 2026-09-04 : on reste au Sampler.** Si les 400 à 900 drones de
l'étape 2 deviennent pénibles, ce test d'une heure les ramène à une trentaine.

### Le mixin qui libère le slot template

`canExtractItem` ne répond oui que pour la sortie, mesuré puis confirmé dans le
code du mod. Un mixin de vingt lignes côté serveur le changerait — le pack fait
déjà exactement ça sur l'Imprinter avec `AllowQueenImprinting.zs`.

**Décision : en attente.** Une réplication par espèce, faite à la main, ne gêne
pas. On le fera si l'échange de templates devient quotidien.

---

## Ce qui est stocké où — à lire une fois

| Objet | Où il vit | Pourquoi |
|---|---|---|
| **Gene samples** | dans AE2 | Leur nom dit leur contenu : `Bee Sample - Species: Cultivated`. **C'est ça, la bibliothèque** |
| **Abeilles** | dans AE2 | Identifiées par leur étiquette |
| **Templates** | dans un coffre, **jamais dans AE2** | Tous portent le même nom. Le programme peut en demander un précis par son empreinte, mais un template perdu dans le réseau ne se retrouve pas |
| **Labware, samples vierges** | dans AE2 | Objets ordinaires |

**Un template n'est pas une archive, c'est un consommable** : assemblé à la
table de craft à partir de samples, qui sont consommés. Les samples se
dupliquent au Genetic Transposer, donc refaire un template coûte peu. Il n'y
aura jamais 500 templates rangés quelque part — il y aura 500 gènes d'espèce
dans AE2.

---

## Les sept espèces des deux profils

Les 11 allèles des profils viennent de sept abeilles :

| Espèce | Ce qu'elle apporte |
|---|---|
| **Rocky** | Never Sleeps, Tolerates Rain, Fertility 1 — **trois d'un coup** |
| Cultivated | Lifespan Shortest |
| Wintry | Fertility 4 |
| Lime (la Forestry) | Temperature Tolerance Both 3 |
| Cyan | Humidity Tolerance Both 3 |
| Robotic | Speed Robotic |
| Temporal | Lifespan Immortal |

Les autres valeurs — Speed Fast, Flowers, Flowering Slow, Territory Average,
Effect None — sont celles d'abeilles ordinaires déjà en stock.

**Rocky et Wintry sont des espèces de base** : elles relèvent de l'étape 2.
**Robotic et Temporal sont très loin dans l'arbre** — c'est pourquoi le template
de **production** n'est pas dans le parcours principal. Il attend l'étape 4.

---

## Ce qui est déjà fait

Croisement piloté, accumulation de drones, planification de chaîne, lecture de
génome sans détruire l'abeille, bibliothèque de gènes avec mise à l'abri
automatique, échantillonnage, duplication, impression, campagnes de gènes,
récolte groupée par profil, réplication, alimentation de l'extracteur ADN,
surveillance des réservoirs, file de tâches reprenable après coupure, templates
demandables au réseau par empreinte.

Neuf machines reconnues, cinq transposers, trois interfaces ME.
