# HiveMind — feuille de route

Ce document dit **ce qu'on fait, comment, et ce qu'on attend comme résultat**.
Il est en français parce que c'est la langue de travail du projet ; le code et
les commits restent en anglais.

## Objectif final

Obtenir et conserver le patrimoine génétique de toutes les abeilles du pack,
puis pouvoir imprimer n'importe quelle espèce à volonté avec des traits
optimaux.

Concrètement, en trois capacités :

1. **Découvrir** — croiser jusqu'à obtenir chaque espèce atteignable.
2. **Conserver** — extraire le gène d'espèce de chacune, le dupliquer, ne jamais
   pouvoir le perdre.
3. **Produire** — fabriquer à la demande une abeille de n'importe quelle espèce,
   avec les meilleurs traits connus.

## Principe de conception

**Le programme ne devine rien qu'il puisse mesurer.** La topologie est découverte
(`discover`), les espèces viennent du jeu (`listAllSpecies`), les mutations
possibles sont demandées au Mutatron, les génomes sont lus dans le NBT. Rien
n'est spécifique à une installation : quelqu'un d'autre lance `discover` puis
`hivemind`.

Corollaire pour les allèles : ils ne sont **pas** listés à l'avance. Un profil
génétique est un *ordre de préférence* par chromosome — « le plus rapide que tu
connaisses » — et le programme choisit parmi ce qu'il a réellement observé. Sa
connaissance s'enrichit à chaque abeille lue et à chaque sample collecté.

---

## Phase 0 — Calibration ✅ terminée

**Fait** : quatre passages en jeu ont fixé le format du génome NBT, l'étiquette
des Gene Samples, les noms de chromosomes, la numérotation des slots, et prouvé
que les templates peuvent être empreintés.

**Résultat** : plus aucun parseur écrit sur une supposition.

## Phase 1 — Le socle ✅ presque terminée

**Fait** : lecture de génome, persistance atomique, registre d'espèces,
file de tâches reprenable, transport AE2, drivers machines, bibliothèque de
gènes, point d'entrée. Un cycle de croisement complet a tourné en jeu.

**Reste** : brancher le planificateur d'arbre, qui existe et est testé mais
n'est relié à rien. Aujourd'hui on programme un croisement à la fois.

**Comment** : le planificateur (dans `main.lua`, hérité) construit l'arbre des
croisements d'une espèce cible, avec réutilisation et cycles d'accumulation de
drones. Il faut le sortir de `main.lua`, le brancher sur la file de tâches, et
supprimer l'ancienne couche d'exécution qui est morte.

**Résultat attendu** : tu demandes `Imperial`, le programme met en file les huit
croisements intermédiaires dans le bon ordre et les enchaîne seul.

## Phase 2 — La génétique ⬜ pas commencée

Nécessite les sept machines Gendustry restantes, contre un second Transposer.
Aucune n'est remplaçable par du logiciel : chacune est le seul moyen d'accomplir
son opération.

| Étape | Machine | Ce qu'on obtient |
|---|---|---|
| Échantillonner | Genetic Sampler | un gène, tiré au hasard sur 13, l'abeille meurt |
| Sauvegarder | Genetic Transposer | une copie du sample |
| Construire | Genetic Transposer | un template assemblé à partir de samples |
| Améliorer | Genetic Imprinter | une abeille existante mise au profil |
| Créer | Genetic Replicator | une abeille neuve depuis un template complet |
| Alimenter | DNA Extractor, Protein Liquifier, Mutagen Producer | les fluides |

**Comment** : chaque opération devient un type de tâche, avec ses étapes
vérifiables, comme le croisement. La bibliothèque de gènes et l'index de
templates sont déjà écrits et testés.

**Résultat attendu** : le gène d'espèce de chaque abeille croisée est capturé et
dupliqué automatiquement, et un template de production permet d'imprimer
n'importe quelle espèce déjà archivée.

**Point clé** : l'Imprinter accepte les templates incomplets, et un template
n'est pas lié à une espèce. Donc **un seul template de 12 gènes, sans chromosome
Species, rend parfaite n'importe quelle abeille**. Les templates complets par
espèce ne servent qu'au Replicator.

## Phase 3 — Les campagnes ⬜ pas commencée

**Comment** : une campagne est un objectif de haut niveau qui alimente la file
en continu — « obtiens le gène Species de toutes les espèces atteignables ».
Boucle : croiser une espèce, accumuler ses drones à l'apiary, échantillonner
jusqu'à tomber sur le chromosome Species, archiver, passer à la suivante.

**Résultat attendu** : le programme tourne seul pendant des heures et ne
t'interpelle que pour ce qu'il ne peut pas faire — une ruche sauvage à ramasser,
une fleur à poser, un réservoir à remplir.

---

## Décisions ouvertes

**Les deux profils génétiques.** Trois chromosomes demandent un arbitrage :

- **Lifespan** — courte pour itérer vite en élevage, longue pour espacer les
  changements de reine en production.
- **Flowers** — voir ci-dessous.
- **Effect** — certains sont utiles, d'autres nuisibles.

Les dix autres sont des maximums sans ambiguïté, et le programme les choisira
seul une fois exprimés en ordre de préférence.

## Contraintes connues

**Les fleurs.** Chaque espèce exige un fournisseur de fleurs particulier ; ce
pack en compte neuf, dont des blocs personnalisés. Pendant le croisement on ne
peut rien y faire — mais `listMutations` donne le génome du résultat, donc le
programme peut annoncer la fleur nécessaire *avant* de lancer. Après, l'Imprinter
uniformise le fournisseur sur toute la production : une seule fleur à fournir.

**Les abeilles répliquées sont toujours Ignoble**, et l'Imprinter tue parfois les
Ignoble. La réplication est donc réservée aux drones, consommables ; les lignées
de princesses viennent du croisement naturel.

**Les templates sont illisibles.** Même item, même étiquette, NBT inaccessible.
Ils vivent dans un coffre dédié, un par slot, suivis sur disque et vérifiés par
empreinte SHA-256. C'est le seul endroit du système où une intervention manuelle
casse l'état.

**AE2 ne distingue pas les génomes.** Plusieurs abeilles de la même espèce mais
génétiquement différentes portent la même étiquette. On ne choisit pas laquelle
le réseau nous donne. Sans conséquence pour l'espèce visée ; il faudra en tenir
compte quand la pureté comptera.

## Où en est le code

| Module | Rôle | Tests |
|---|---|---|
| `lib/genome.lua` | lecture NBT, étiquettes de samples, pureté, profils | 41 |
| `lib/state.lua` | persistance atomique | 28 |
| `lib/species.lua` | registre alimenté par le jeu, index inverse | 59 |
| `lib/jobs.lua` | file reprenable, étapes idempotentes | 40 |
| `lib/transport.lua` | AE2 → Database → quai → Transposer | 69 |
| `lib/machines.lua` | interface unique, politique d'énergie | 69 |
| `lib/library.lua` | bibliothèque de gènes, empreinte de templates | 49 |
| `lib/breeding.lua` | le cycle de croisement en sept étapes | 34 |
| `lib/config.lua` | topologie déclarée, découverte par `discover` | — |
| `hivemind.lua` | démarrage, menu, reprise | — |

Outils : `hminstall` (installation et mise à jour), `calibrate` (diagnostic),
`discover` (topologie), `upload` (envoi de rapport).
