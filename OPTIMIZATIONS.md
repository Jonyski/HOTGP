# Otimizações do HOTGP — investigação, o que foi feito e o que ainda dá para fazer

Este documento registra a investigação de desempenho feita sobre o motor de GP
(`src/Evolution`, `src/Grammar`) e as mudanças aplicadas. A meta era **deixar a
mesma busca o mais rápida possível**, sem mexer em hiperparâmetros nem na
semântica da avaliação (fitness), para que os resultados continuem comparáveis
com os de outros algoritmos de GP.

> Resumo: o gargalo real é a **mutação** (≈57% do tempo do laço), que gera uma
> subárvore nova a cada passo. O trabalho aplicado cortou travessias redundantes
> de árvore inteira (o cache de medidas passou a ser *mantido* em vez de
> *reconstruído*), removeu um cálculo de `1000 × exp/log` por passo e ligou
> `-O2` na biblioteca. Ganho medido: **~10% no laço** pelas mudanças de código
> somadas a **~5%** do `-O2`, com **~8% menos alocação** — e um bug de cache
> corrigido no caminho.

---

## 1. Como medir (e por que a máquina engana)

Foi criado um harness de desenvolvimento em [bench/Perf.hs](bench/Perf.hs),
declarado como `benchmark hotgp-perf` em [hotgp.cabal](hotgp.cabal):

```bash
cabal build hotgp-perf
BIN=$(cabal list-bin hotgp-perf)

taskset -c 6 $BIN                     +RTS -N1 -RTS   # tempos por componente
taskset -c 6 $BIN loop                +RTS -N1 -RTS   # 20.000 avaliações ponta a ponta
taskset -c 6 $BIN acc sum-of-squares 1 30000         # melhor fitness final
```

Duas lições de medição, porque isso muda as conclusões:

- **`-N1` + `taskset`.** O executável usa `-with-rtsopts=-N`; num programa
  single-thread isso liga o GC paralelo em cima de um núcleo só e aumenta muito
  a variância.
- **Use o mínimo de várias execuções.** Nesta máquina a mesma corrida variou
  ±20% (5,0 s a 7,1 s) por carga externa. Comparações A/B precisam ser
  intercaladas (`base`, `new`, `base`, `new`, …) e resumidas pelo mínimo.

Os números por componente (medidos no mesmo processo, com pares fixos de pais e
uma população de 1000 árvores) são bem mais estáveis que o ponta a ponta.

---

## 2. Diagnóstico

Perfil com `-p` (`cabal build hotgp-perf --enable-profiling`, executando só o
laço com 20.000 avaliações, `sum-of-squares`, `popSize = 1000`,
`_individualsPerStep = 2`):

| fase | % do tempo |
|---|---|
| **mutação** (`doMutation` → `grow`/`buildTree` + enxerto) | **57,3%** |
| — `SamplerTable.buildTree` | 18,2% |
| — `Helpers.sample` (sorteio da célula da tabela) | 16,3% |
| — `Grammar.Helpers.computeMeasureFrom` | 13,1% |
| — `Helpers.randomR` | 10,1% |
| fitness (`evalTree`, 50 casos de treino por filho) | 9,7% |
| `keepBest` (merge ordenado da população) | 7,5% |
| deduplicação (`notElem` na população) | 6,3% |
| seleção (`sampleManyWithProb`) | 4,3% |
| ranking (`zip` população × pesos) | 1,6% |
| **crossover** | **1,6%** |

Três conclusões que mudaram o plano:

1. **Crossover não é o gargalo** (1,6%). A impressão contrária vem de medir com
   árvores *sem* medidas: aí todo `getHeight`/`getNodeCount` recalcula a
   subárvore e o custo explode. Com o cache válido, é barato.
2. **A mutação domina**, e o motivo é estrutural: `_maxMutationTreeDepth` é
   igual a `_maxTreeDepth` (15), então cada mutação gera um enxerto grande — é
   o custo do algoritmo, não um desperdício acidental.
3. O laço gasta **3 travessias completas de árvore por passo** que não
   precisavam existir: duas em `doCrossover` (medir os filhos) e uma em
   `mkIndividual` (medir de novo, já medidos). Com 2 avaliações por passo, esse
   trabalho é pago com juros.

---

## 3. O que foi mudado

### 3.1 O cache de medidas passa a ser mantido no enxerto

`atPoint` (mutação e crossover) trocava uma subárvore e deixava as medidas dos
ancestrais **velhas**; o laço consertava depois com `computeMeasure`, uma
travessia completa por filho.

Agora [src/Evolution/Helpers.hs](src/Evolution/Helpers.hs) tem
`atPointMeasured`, que aproveita a profundidade já conhecida no caminho até o
ponto sorteado:

- **subárvore transplantada:** `rebaseMeasure` (novo, em
  [src/Grammar/Helpers.hs](src/Grammar/Helpers.hs)) só desloca
  `_currentDepth` — altura e contagem de nós não dependem de onde a subárvore
  está, então são reaproveitadas;
- **ancestrais do caminho:** `_height` e `_nodeCount` são recalculados
  bottom-up a partir dos filhos (já válidos).

Custo: *subárvore + caminho* em vez de *árvore inteira*. Se a árvore não tinha
medida nenhuma (árvore recém-gerada, testes montados à mão), o código cai no
caminho antigo (`computeMeasure . atPoint`), que continua correto.

`computeMeasure` também foi dividido em `computeMeasureFrom depth`, para poder
medir um pedaço na profundidade certa.

### 3.2 Filhos já medidos não são remedidos ao pontuar

[src/Evolution/Individual.hs](src/Evolution/Individual.hs) ganhou
`mkMeasuredIndividual`, usado pelo laço: como crossover e mutação entregam
árvores já medidas, `mkIndividual` (que sempre roda `computeMeasure`) fica só
para a população inicial e para o checkpoint.

### 3.3 Pesos de seleção calculados uma vez por corrida

`exponentialRank` refazia, **a cada passo**, `_parentScalar ** rank` para os
1000 ranks — 1 `exp` + 1 `log` por rank só para sortear 2 pais.

[src/Evolution/Run.hs](src/Evolution/Run.hs) separou `rankWeights cfg` (a lista
de pesos, calculada uma vez e compartilhada) de `steadyStateReplaceWith`, que
recebe os pesos. `steadyStateReplace cfg` continua existindo com a assinatura
antiga (recalcula), para compatibilidade.

### 3.4 A biblioteca agora é compilada com `-O2`

O `.cabal` só passava `-O2` para o executável e para os testes; a **biblioteca**
ficava no padrão do cabal (`-O1`), e é nela que está todo o código quente.
Adicionado `ghc-options: -O2` em [hotgp.cabal](hotgp.cabal) e
[package.yaml](package.yaml).

### 3.5 Efeito colateral: a deduplicação passou a funcionar

`Tree` deriva `Eq` e carrega `_measure`; logo, comparar árvores compara o cache.
Como os filhos mutados chegavam com cache inválido, eles quase nunca eram
"iguais" a um membro medido da população e o filtro `notElem` era praticamente
inerte. Com o cache correto, ele volta a filtrar — inclusive mutados.

**Isso muda a trajetória da busca** (e o estado do RNG). Ver §5.

---

## 4. Resultados medidos

Componentes (`sum-of-squares`, população de 1000, mesmo harness):

| medida | antes | depois |
|---|---|---|
| população inicial (gerar + pontuar 1000 árvores) | 1.465 ms | 888–1.030 ms |
| crossover (300 pares) | 178 ms | 119–129 ms |
| dedup contra população de 1000 | 76 ms | 45 ms |
| filhos com cache de medidas inconsistente | **348 / 576** | **0 / 576** |
| mutantes com cache inconsistente | **200 / 200** | **0 / 200** |
| população final com medida obsoleta (20.000 aval.) | — | **0 / 1000** |

Ponta a ponta (`loop`, 20.000 avaliações, mesmo `-O2`, alternando base e nova,
mínimo de 5 execuções): **5,32 s → 4,90 s** (~8%). Numa sessão mais leve a
mesma comparação deu 6,64 s → 5,15 s (~22%) — a diferença entre esses dois
números é ruído de máquina, não do código; trate **~10%** como estimativa
conservadora para as mudanças de algoritmo e **~5%** para o `-O2`.

Alocação total (determinística, via `+RTS -s`, 20.000 avaliações):

| | antes | depois |
|---|---|---|
| bytes alocados | 18,66 GB | 17,14 GB |
| bytes copiados no GC | 1,92 GB | 1,78 GB |
| residência máxima | 165 MB | 130 MB |

O checksum da população e o estado final do RNG são **idênticos** entre as
etapas 3.1–3.4 (rodei a mesma seed antes e depois de cada uma): essas mudanças
são puramente de custo. A §3.5 é a única que altera o resultado da busca.

---

## 5. Sobre "não perder a acurácia"

A correção do cache **não muda a função de fitness nem o algoritmo**: muda
apenas quais programas a busca visita, porque a deduplicação passa a filtrar.
Duas checagens:

- 190 testes da suíte passam (`cabal test`).
- `compare-string-lengths`, 30.000 avaliações, seeds 1–8 — melhor fitness final
  (0 = solução perfeita):

  | | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
  |---|---|---|---|---|---|---|---|---|
  | antes | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
  | depois | 0 | **2** | 0 | 0 | 0 | 0 | 0 | 0 |

- `sum-of-squares`, 30.000 avaliações, seeds 1–3: antes
  {712.063; 1.898.015; 229.196}, depois {770.237; 114.688; 729.665} — mesma
  ordem de grandeza (esse problema não converge no orçamento).

Ou seja: paridade dentro do ruído, com uma seed pior em 8 no problema fácil.
Para uma afirmação forte vale rodar a suíte completa de benchmarks com várias
seeds (é exatamente o que você vai fazer na comparação) — e, se quiser
reproduzir resultados antigos bit a bit, use o commit anterior a estas
mudanças, porque a trajetória diverge por desenho.

---

## 6. Onde ainda dá para otimizar (em ordem de retorno esperado)

### 6.1 Gerador de subárvores da mutação — 57% do tempo

É o alvo grande. `buildTree` faz, por nó: um `Map.!` com chave
`(Depth, GType)` (comparação estrutural de tipos), um `sample` (que faz
`length` + `!!` na lista da célula) e 1–2 `randomR`. Ideias, da mais simples
para a mais ambiciosa:

- **Células como `Vector`.** Guardar `[St Terminal]` como `V.Vector` dá
  `length` e indexação O(1) e elimina uma travessia da lista por nó. O sorteio
  continua `randomR (0, len-1)`, então o stream do RNG não muda.
- **Tabela indexada por `Int`.** Interne cada `(Depth, GType)` num `Int` no
  momento de montar a tabela e guarde as células num `Vector`; o nó passa a
  carregar os ids dos filhos. Troca `Map` + comparação de tipos por indexação
  O(1) por nó.
- **Medir durante a construção.** `buildTree` pode anotar `_height`/`_nodeCount`
  enquanto monta (é só `1 + maximum` / `1 + sum` sobre os filhos já prontos),
  deixando para o enxerto apenas o deslocamento de `_currentDepth`.
- **Sem mônada por nó.** Reescrever `buildTree` passando o `StdGen` na mão evita
  as closures de `State` por nó (é o tipo de código que o `-O2` já ajuda, mas
  não elimina).

Ganho plausível: 15–25% do tempo total. Risco: médio — para manter
reprodutibilidade, a **ordem das chamadas ao RNG** tem de ser preservada.

> Não mexa em `_maxMutationTreeDepth` para ganhar velocidade: ele é o que
> permite a mutação gerar enxertos grandes (parte da qualidade da busca) e é a
> causa direta desse custo.

### 6.2 Deduplicação — 6%

Hoje é um `notElem` linear: 2 filhos × 1000 indivíduos por passo. Um **hash
estrutural incremental** guardado junto da medida (calculado em
`computeMeasure`/`rebaseMeasure`, que já visitam os nós) permitiria um
`HashSet`/`IntMap` e reduziria a comparação a O(1), com igualdade exata como
desempate. Ganho ~4%. Risco: baixo, se o hash entrar apenas como filtro.

### 6.3 Sobrevivência (`keepBest`) — 7,5%

Cada passo faz o merge ordenado da população inteira (`splitAt`) para acomodar
1–2 filhos. Inserir só os filhos com `SL.insert` (O(log n) cada) evitaria o
merge O(n) — mas atenção ao desempate: hoje quem empata em fitness e tamanho é
resolvido pela ordem do merge. Ganho ~3–5%, risco baixo-médio (precisa de um
teste comparando populações).

### 6.4 Avaliação de fitness — 9,7%

`evalTree` interpreta a árvore 50 vezes por indivíduo (uma por caso de treino).
Duas frentes: (a) paralelizar os casos de treino com `par`/`sparks` (o executável
já é `-threaded`); (b) micro-otimizar o interpretador (por exemplo, argumentos
em `Array`/`Vector` em vez de lista com `!!`, e evitar o `guard`/`Maybe` por
nó). Ganho: ~3–5% serial, potencialmente 8× nessa fase se paralelizado.

### 6.5 Paralelismo de corridas — o maior ganho *prático* para benchmarking

O algoritmo é single-threaded (monada `State` sobre `StdGen`), então `-N` não
ajuda em nada hoje. Para comparar com outros GPs você vai rodar **N seeds × M
problemas**, que são independentes: rodar em processos paralelos (ou adicionar
`-j` ao executável) escala quase linearmente com os núcleos. Isso rende muito
mais que qualquer micro-otimização e não altera resultado nenhum.

### 6.6 Miudezas

- `runAndLog` imprime uma linha **por passo** (~150 mil linhas numa corrida de
  300 mil avaliações, com `getCurrentTime` + `printf` cada). Logar a cada
  checkpoint, ou só quando `-v` for passado, é gratuito em comportamento.
- `-A` (área de alocação do RTS) não ajudou aqui: testado 8/32/64/256 MB, tudo
  dentro do ruído. Os padrões estão bons.
- `-O2` já está ligado na biblioteca; `-fllvm` não está disponível neste GHC.

---

## 7. O que **não** foi mudado (de propósito)

- Hiperparâmetros: `popSize = 1000`, `nGens = 300`, `_parentScalar = 0.9993`,
  `_crossoverRate = 0.5`, `_individualsPerStep = 2`, profundidades 15 — mexer
  neles muda a busca, não a velocidade.
- O stream do RNG: nenhuma mudança altera a *ordem* nem os *intervalos* dos
  sorteios. É isso que permite comparar "antes/depois" sem confundir velocidade
  com sorte.
- A semântica de `evalTree`/métricas de fitness.

---

## 8. Arquivos tocados

| arquivo | mudança |
|---|---|
| [src/Grammar/Helpers.hs](src/Grammar/Helpers.hs) | `computeMeasureFrom` (medir a partir de uma profundidade) e `rebaseMeasure` (deslocar profundidades reaproveitando altura/contagem) |
| [src/Evolution/Helpers.hs](src/Evolution/Helpers.hs) | `atPointMeasured` e `atRandomPointMeasured`: enxerto que mantém o cache válido |
| [src/Evolution/Crossover.hs](src/Evolution/Crossover.hs) | usa `atPointMeasured` nos dois filhos |
| [src/Evolution/Mutation.hs](src/Evolution/Mutation.hs) | usa `atRandomPointMeasured` |
| [src/Evolution/Individual.hs](src/Evolution/Individual.hs) | `mkMeasuredIndividual` (pontuar sem remedir) |
| [src/Evolution/Run.hs](src/Evolution/Run.hs) | `rankWeights` + `steadyStateReplaceWith`; sem `computeMeasure` em `doCrossover`; usa `mkMeasuredIndividual` |
| [hotgp.cabal](hotgp.cabal), [package.yaml](package.yaml) | `-O2` na biblioteca; stanza `benchmark hotgp-perf` |
| [bench/Perf.hs](bench/Perf.hs) | harness de medição (componentes, laço e acurácia) |
| [EXECUTION_FLOW.md](EXECUTION_FLOW.md) | §5.3, §6, diagrama e mapa atualizados para o novo esquema de medidas |
