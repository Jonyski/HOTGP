# UNDERSTAND_THE_CODE — Guia completo do HOTGP

> **HOTGP — Higher-Order Typed Genetic Programming**
> Sistema de Programação Genética em Haskell que evolui programas funcionais
> (com lambdas / ordem superior) e **tipados** para problemas de síntese de
> programas. Paper de referência: <https://doi.org/10.1145/3583131.3590464>.

Este documento explica, módulo por módulo, como o sistema funciona — tanto as
**decisões de programação genética** (representação, tipagem, operadores,
seleção, fitness, controle de bloat) quanto os **idiomas e truques de Haskell**
(GADTs, tipos existenciais, pattern synonyms, monads, monoides, lazy arrays,
serialização etc.) que a implementação usa.

---

## Sumário

1. [Visão geral e arquitetura](#1-visão-geral-e-arquitetura)
2. [O pipeline de uma execução, fim a fim](#2-o-pipeline-de-uma-execução-fim-a-fim)
3. [Camada `Grammar` — a linguagem buscada pela GP](#3-camada-grammar--a-linguagem-buscada-pela-gp)
   - [`Pretty` (raiz) e `Grammar.hs`](#pretty-raiz-e-grammarhs)
   - [`Grammar.Core`](#grammarcore)
   - [`Grammar.Types`](#grammartypes)
   - [`Grammar.Eval`](#grammareval)
   - [`Grammar.Helpers`](#grammarhelpers)
   - [`Grammar.Pretty`](#grammarpretty)
   - [`Grammar.Simplify`](#grammarsimplify)
4. [Camada `Evolution` — o motor de busca](#4-camada-evolution--o-motor-de-busca)
   - [`Evolution.Core`](#evolutioncore)
   - [`Evolution.Config`](#evolutionconfig)
   - [`Evolution.Fitness`](#evolutionfitness)
   - [`Evolution.Individual`](#evolutionindividual)
   - [`Evolution.SamplerTable`](#evolutionsamplertable)
   - [`Evolution.Generate`](#evolutiongenerate)
   - [`Evolution.Helpers`](#evolutionhelpers)
   - [`Evolution.Mutation`](#evolutionmutation)
   - [`Evolution.Crossover`](#evolutioncrossover)
   - [`Evolution.Run`](#evolutionrun)
   - [`Evolution.Checkpoint`](#evolutioncheckpoint)
   - [`Evolution.Pretty`](#evolutionpretty)
5. [Camada `Benchmark` — problemas, dados e execução](#5-camada-benchmark--problemas-dados-e-execução)
   - [`Benchmark.Core`](#benchmarkcore)
   - [`Benchmark.Problems` + `Benchmark.Problems.*`](#benchmarkproblems--benchmarkproblems)
   - [`Benchmark.Download`](#benchmarkdownload)
   - [`Benchmark.Parse`](#benchmarkparse)
   - [`Benchmark.Dataset`](#benchmarkdataset)
   - [`Benchmark.Metrics`](#benchmarkmetrics)
   - [`Benchmark.Helpers`](#benchmarkhelpers)
   - [`Benchmark.BenchmarkToConfig`](#benchmarkbenchmarktoconfig)
   - [`Benchmark.Run` / `Benchmark.RunSearch`](#benchmarkrun--benchmarkrunsearch)
   - [`Benchmark.Log`](#benchmarklog)
6. [`Prune` — pós-processamento guloso](#6-prune--pós-processamento-guloso)
7. [`app/Main.hs` — a CLI](#7-appmainhs--a-cli)
8. [`test/` — a suíte de testes](#8-test--a-suíte-de-testes)
9. [Conceitos de Programação Genética implementados](#9-conceitos-de-programação-genética-implementados)
10. [Truques e idiomas de Haskell usados no código](#10-truques-e-idiomas-de-haskell-usados-no-código)
11. [Armadilhas, código morto e particularidades](#11-armadilhas-código-morto-e-particularidades)
12. [Como estender o sistema](#12-como-estender-o-sistema)

---

## 1. Visão geral e arquitetura

O projeto é uma biblioteca Haskell (`src/`) + um executável (`app/Main.hs`),
organizada em **três camadas** mais dois módulos de topo:

```
app/Main.hs                 CLI: <benchmark> <seed>  |  prune
src/
  Grammar/                  A LINGUAGEM: tipos, AST, avaliador, tipagem, pretty
  Evolution/                O MOTOR: geração, seleção, crossover, mutação, laço
  Benchmark/                OS PROBLEMAS: datasets, métricas, configs, logging
  Prune.hs                  Pós-processamento (poda gulosa de soluções)
  Pretty.hs                 A classe `Pretty` compartilhada por tudo
```

Dependências (setas = "importa"):

```
        Pretty
          ^
          |_______________________________________
          |                  |                   |
   Grammar.Core --> Grammar.Types --> Grammar.Eval
          ^   \        ^                 |
          |    \       |                 |
   Grammar.Helpers  Grammar.Pretty   Grammar.Simplify
          ^                                  ^
          |__________________________________|
                       Grammar (umbrella)
                          ^
                          |
   Evolution.Core --> Evolution.Config --> Evolution.SamplerTable
          ^    \            ^   \               ^
          |     \           |    \              |
   Evolution.Helpers   Evolution.Fitness   Evolution.Generate
          ^                  ^                   ^
          |                  |                   |
   Evolution.Mutation  Evolution.Individual  Evolution.Crossover
                                ^                  ^
                                |__________________|
                                Evolution.Run --> Evolution.Checkpoint
                                       ^
                                       |
   Benchmark.Core --> Benchmark.Problems.* --> Benchmark.Metrics
          ^   \                                  ^
          |    \                                 |
   Benchmark.Parse  Benchmark.Download   Benchmark.Helpers
          ^                                   ^
          |                                   |
   Benchmark.Dataset --> Benchmark.BenchmarkToConfig --> Benchmark.Log
                                       ^
                                       |
                        Benchmark.Run / Benchmark.RunSearch
                                       ^
                                       |
                              Benchmark.Problems (registro)
                                       ^
                                       |
                            app/Main.hs    e    Prune.hs
```

Convenções transversais importantes:

- **Menor é melhor** em toda a busca: a `Ord` da população é crescente e a
  cabeça é o melhor indivíduo. Métricas retornam "quão errado" está a resposta.
- **Nada de aleatoriedade em `IO`**: toda a aleatoriedade vive num `State
  StdGen` puro, o que torna cada `(problema, seed)` exatamente reproduzível.
- **Tipos nos construídos, não no verificado**: as árvores são geradas
  tipadas por construção (tabela de amostragem dirigida por tipos); o
  type-checker existe mas, na busca, só é usado indiretamente (ver
  §11 — `typeCheck` só aparece em testes).
- **Cache de medidas** (`depth`/`height`/`nodeCount`) embutido em cada nó,
  porque o laço evolutivo consulta tamanho o tempo todo.

---

## 2. O pipeline de uma execução, fim a fim

`cabal run hotgp-exe -- sum-of-squares 42` executa, nesta ordem:

1. **`app/Main.hs`** — `parseArgs` valida que o 1º argumento está em
   `allProblemIds` e que o 2º é `Int`; cria `./checkpoint/` e chama
   `runProblem "./" 42 "sum-of-squares"`.
2. **`Benchmark.Problems.runProblem`** — faz lookup existencial do problema
   (`getProblem` → `MkProblem bench`) e chama `Benchmark.Run.runBenchmark`.
3. **`Benchmark.Run.runBenchmark`**
   - monta o identificador de arquivos (`<timestamp>_s<seed>_<problema>`);
   - `prepareLogFiles` cria `./output/` e `./checkpoint/` e abre o
     `<id>.log.csv` com cabeçalho;
   - `loadTrainAndTestSet` → `downloadBenchmark` (curl + gzip + `sort -R`,
     só na primeira vez) e depois `readJson` de `*-edge.json` e `*-random.json`,
     concatenando **edge primeiro** e cortando `_trainCases` / `_testCases`;
   - `makeConfig trainSet benchmark` produz o `Config`;
   - `evalStateT (runAndLog cfg logToFile checkpoint) (mkStdGen seed)`.
4. **`Evolution.Run.runAndLog`**
   - existe checkpoint? `loadCheckpoint` (retoma população + RNG) senão
     `ramped` + `mkIndividual` (população inicial, custa `_popSize` avaliações);
   - laço: `steadyStateReplace` → imprime progresso → checa
     `isPerfectSolution` ou esgotamento de orçamento → checkpoint a cada
     múltiplo de 1000 avaliações.
5. De volta a `runBenchmark`: fecha o log e escreve
   `<id>.result.csv` (um caso de teste por linha, esperado vs. obtido) e
   `<id>.result.json` (resumo do melhor programa, incluindo `showTree`, que o
   `prune` lê depois).

Hiperparâmetros fixos do experimento, todos em
`src/Benchmark/BenchmarkToConfig.hs:58-60`:

```haskell
popSize   = 1000     -- indivíduos
nGens     = 300      -- => _nEvaluations = 1000 * 300 = 300000
treeDepth = 15       -- profundidade máxima (inicial, geral e de mutação)
-- além disso: _individualsPerStep = 2, _parentScalar = 0.9993, _crossoverRate = 0.5
```

---

## 3. Camada `Grammar` — a linguagem buscada pela GP

### `Pretty` (raiz) e `Grammar.hs`

**`src/Pretty.hs`** (16 linhas) define a classe tipo-classe usada em todo o
projeto para "transformar em texto legível":

```haskell
class Pretty a where
  pretty :: a -> String
```

Não há dependência de biblioteca de pretty-printing — cada camada declara seu
próprio `instance` ao lado do tipo (`Grammar.Pretty` para valores da gramática,
`Evolution.Pretty` para populações).

**`src/Grammar.hs`** é um *umbrella module*: re-exporta `Grammar.Core`,
`Helpers`, `Pretty`, `Eval` e `Types`. De propósito **não** re-exporta
`Grammar.Simplify` (passo opcional de pós-processamento, usado só por
`Prune` e testes) para não poluir nomes.

---

### `Grammar.Core`

`src/Grammar/Core.hs` — define **a linguagem**. Três conceitos:

#### 3.1.1 `GType` — o sistema de tipos da linguagem

```haskell
data GType
  = GInt | GFloat | GBool | GChar
  | GPair !GType !GType      -- par homogêneo
  | GPoly !Int               -- VARIÁVEL de tipo (de Bruijn-ish): 0 = 'a', 1 = 'b'
  | GList !GType
  | GLambda FunctionType     -- funções são de primeira classe!
  deriving (Show, Eq, Ord, Read, Generic)
```

`GPoly n` é o que faz o sistema ser **polimórfico**: `map :: (a -> b) ->
[a] -> [b]` é escrito com `GPoly 0`/`GPoly 1` e é instanciado/unificado em
tempo de execução (ver `Grammar.Types`). Nota: `GFloat` é `Float` (32 bits)
de propósito, porque os datasets esperam `Float`.

Derivar `Ord` em `GType` é **funcional, não cosmético**: `GType` é parte da
chave de `Data.Map` na tabela de amostragem (`Map (Depth, OutputType) ...`) e
aparece em `Set GType` (`_relevantTypes`).

#### 3.1.2 `FunctionType`, `Lit`, `Tree`

```haskell
data FunctionType = MkFunctionType { _argTypes :: !ArgTypes, _outType :: !OutputType }
type ProgramType   = FunctionType     -- alias didático
type ProgramArgTypes = ArgTypes

data Lit
  = IntLit !Int | FloatLit !Float | BoolLit !Bool | CharLit !Char
  | PairLit !Lit !Lit
  | ListLit !GType ![Lit]        -- GType = tipo do ELEMENTO (para [] saber o tipo)
  | LambdaLit !TypedTree         -- lambda = valor cujo corpo é OUTRA árvore

data Terminal = Arg !Int          -- referência ao n-ésimo argumento (0-based)
              | Literal !Lit      -- constante embutida (ERC)

data Tree = Leaf { _measure :: !(Maybe Measure), _terminal :: !Terminal }
          | Node { _measure :: !(Maybe Measure), _operation :: !Operation, _args :: ![Tree] }

data TypedTree = MkTypedTree { _tree :: !Tree, _type :: !FunctionType }
```

Pontos técnicos:

- **`LambdaLit !TypedTree` é o "higher-order" do HOTGP.** Um lambda é um
  literal cujo corpo é um programa completo, que precisa lembrar da sua
  assinatura (para `map` saber o tipo do resultado). Ou seja: a linguagem
  **constrói e consome outros programas**.
- **`Measure` dentro de cada nó** (campo `_measure :: Maybe Measure`, com
  `_currentDepth`, `_height`, `_nodeCount`) é um **cache memoizado de
  tamanho**. `Maybe` porque uma árvore recém-construída/mutada pode não ter
  medida válida. Ver `Grammar.Helpers`.
- **A árvore não carrega tipo.** Os tipos só são materializados quando
  necessário (`TypedTree`, no corpo de lambda). Isso mantém a cópia de árvores
  barata durante a evolução.
- A aridade dos `Node` é **implícita**: é a lista `_args`, e o número correto
  de filhos é fixado por `opType` e assumido em todo lugar (quebrar isso
  produz `error` no avaliador/pretty-printer).

#### 3.1.3 `Operation` — o vocabulário fixo

O enum `Operation` **é a gramática**: 44 construtores (`AddInt`, `SubInt`,
`MultInt`, `DivInt`, `ModInt`, `MaxInt`, `MinInt`, `And`, `Or`, `Not`, `If`,
operações float, `EqChar`/`IsLetter`/`IsDigit`, `IntToFloat`/`Floor`,
comparações inteiras, listas (`Len`, `Reverse`, `Singleton`, `Cons`, `Head`,
`Range`, `Map`, `Filter`, `Concat`, `Zip`, `Take`, somas/produtos,
`Unlines`, `ShowInt`, pares `ToPair`/`Fst`/`Snd`).

Derivar `(Enum, Bounded)` permite enumerar "todos os operadores" com
`[(minBound :: Operation) .. maxBound]` — é exatamente o que
`BenchmarkToConfig.operationsFromTypes` faz.

Adicionar um primitivo exige **quatro** lugares: o construtor aqui, a
assinatura em `opType`, o caso em `eval` (e opcionalmente regras em
`Simplify` e nome em `Grammar.Pretty`).

#### 3.1.4 Atalhos sintáticos (truque de legibilidade)

```haskell
(<|) :: Operation -> [Tree] -> Tree
(<|) = Node Nothing                            -- AddInt <| [a, b]

(->>) :: ArgTypes -> OutputType -> FunctionType
(->>) = MkFunctionType                         -- '[GInt] ->> GBool

pattern LeafLit :: Lit -> Tree                  -- bidirecional!
pattern LeafLit a <- Leaf _ (Literal a) where LeafLit a = Leaf Nothing (Literal a)

pattern LeafArg :: Int -> Tree
pattern LeafArg i <- Leaf _ (Arg i) where LeafArg i = Leaf Nothing (Arg i)

{-# COMPLETE LeafArg, LeafLit, Node #-}
```

**Truques de Haskell aqui:**

- **Pattern synonyms bidirecionais**: `LeafLit` serve tanto para *casar* quanto
  para *construir*; assim `case t of LeafLit (IntLit n) -> ...` e
  `LeafLit (IntLit 5)` funcionam com a mesma sintaxe.
- **`{-# COMPLETE ... #-}`** avisa o GHC que `LeafArg`, `LeafLit` e `Node`
  cobrem todos os `Tree`s — sem isso, todo `case` usando os synonynms seria
  considerado inexaustivo e geraria warning (o executável compila com `-Wall`).
- `compOp [Not, Not] [t]` encadeia operadores unários
  (`compOp (x:xs) ts = x <| [compOp xs ts]`), evitando aninhamento manual em
  testes/definições de problemas. É **código de conveniência**, sem uso no laço.

---

### `Grammar.Types`

`src/Grammar/Types.hs` — responde "qual a assinatura de cada primitivo?" e
"esta árvore está bem tipada?".

#### 3.2.1 `opType` — a tabela de assinaturas (fonte única de verdade)

```haskell
opType :: Operation -> FunctionType
opType If     = [GBool, GPoly 0, GPoly 0] ->> GPoly 0
opType Map    = [GLambda ([GPoly 0] ->> GPoly 1), GList (GPoly 0)] ->> GList (GPoly 1)
opType Zip    = [GList (GPoly 0), GList (GPoly 1)] ->> GList (GPair (GPoly 0) (GPoly 1))
opType Filter = [GLambda ([GPoly 0] ->> GBool), GList (GPoly 0)] ->> GList (GPoly 0)
...
```

Detalhe crucial: `If` usa o **mesmo índice de variável** nas duas branches, o
que é como o verificador aprende que elas devem concordar. Essa tabela é lida
pelo type-checker, pelo sampler dirigido por tipos **e** pelo pruner.

Há um `{-# LANGUAGE OverloadedLists #-}` no topo do arquivo. Na prática é
inócuo aqui (as listas têm tipo concreto `[GType]`, e a instância
`IsList [a]` do GHC produz a mesma lista), mas é um resquício interessante.

#### 3.2.2 `litType` e `getType`

- `litType` dá o tipo de um literal. Literais são **monomórficos**; a única
  exceção é `ListLit`, que carrega o tipo do elemento justamente para `[]`
  saber o que contém.
- `getType` resolve o tipo de uma **folha** no contexto do programa: `Arg n` →
  `pgTypes !! n`, literal → `litType`. Nós internos pegam o tipo direto de
  `opOutput`, independente de contexto.

#### 3.2.3 `unifyTypes` — unificação estrutural simplificada

```haskell
unifyTypes :: GType -> GType -> Maybe GType
unifyTypes (GPoly n) x = Just x          -- variável unifica com qualquer coisa
unifyTypes x (GPoly n) = Just x
unifyTypes (GPair a b) (GPair x y) = GPair <$> unifyTypes a x <*> unifyTypes b y
unifyTypes (GList a) (GList x)     = GList <$> unifyTypes a x
unifyTypes (GLambda f1) (GLambda f2) = ... zipWithM ... -- estrutural
unifyTypes a b = if a == b then Just a else Nothing
```

É Hindley-Milner **monomórfico**: não há `forall` na linguagem, então não há
generalização nem ambiente de substituição — o resultado *é* o tipo concreto.
Note o uso de `Maybe` + `<$>`/`<*>`/`zipWithM` como monadificação estrutural
(isso é *unificação por pattern matching*, não o algoritmo de Robinson com
substituição).

#### 3.2.4 `typeCheck` — verificação top-down

```haskell
typeCheck :: ProgramType -> Tree -> Maybe OutputType
```

Algoritmo (top-down, unificando conforme desce):

1. Unifica o tipo exigido com o que o nó produz. Para uma folha `Arg n`, isso
   *instancia* a variável exigida.
2. Para um `Node`, pega `opArgTypes op`. Se a **saída** do operador era
   variável (ex.: `if` retornando `a`), substitui a variável pela saída já
   instanciada em **todos** os argumentos (é assim que as branches de `if`
   são forçadas a concordar).
3. Recorre nos filhos com `typeCheckArgs`, que anda par a par (tipo esperado,
   filho) e **propaga a instanciação da esquerda para a direita**: quando o
   tipo esperado era `GPoly n` e o filho decidiu `Int`, os argumentos
   seguintes passam a esperar `Int`. É assim que `map f [1,2,3]` descobre
   que `f` precisa ser `Int -> ...`.

```haskell
typeCheckArgs (expectedType : ets) (t : ts) = case typeCheck (pgArgs ->> expectedType) t of
  Nothing    -> False
  Just gt -> case expectedType of
    GPoly n -> typeCheckArgs (replace (GPoly n) gt ets) ts  -- propaga
    et      -> typeCheckArgs ets ts
  where replace old new = map (\el -> if el == old then new else el)  -- substituição em lista
```

> **Observação importante (ver §11):** `typeCheck` **não é chamado no laço
> evolutivo**. Ele é usado nos testes (`test/EvolutionSpec/Helpers.hs`).
> A garantia de tipo na busca vem da *construção* (sampler) + de
> `inferOutputType` nos operadores. `typeCheck` é a especificação formal
> contra a qual os geradores são testados.

#### 3.2.5 `inferOutputType` — a dual bottom-up

```haskell
inferOutputType :: ProgramArgTypes -> Tree -> OutputType
```

Em vez de "cabe isso no tipo exigido?", pergunta "qual é o tipo desta árvore?".
Para folhas é imediato; para nós, infere o tipo de cada filho, **pareia** o
tipo esperado de cada argumento com o real (`learnTypes`) e substitui a
variável de saída do nó pelo que a pareação revelou. É o que mutation e
crossover usam para saber "qual tipo este subtree produz?".

`learnTypes :: (GType, GType) -> [(GType, GType)]` descende em containers e
devolve os vínculos implícitos; o `=<<` sobre a lista de pares em
`inferOutputType` **junta (pool) todos os vínculos de todos os argumentos**:

```haskell
learnTypes (GList a, GList b) = learnTypes (a, b)
learnTypes (x, y)             = [(x, y)]
-- learnTypes ([a], [Int]) == [(a, Int)]
```

---

### `Grammar.Eval`

`src/Grammar/Eval.hs` — o interpretador. `evalTree :: [Lit] -> Tree -> Maybe Lit`.

**Semântica:**

- `LeafArg i` → `args !! i` (com `error` se fora de range: árvore malformada).
- `LeafLit v` → `v`.
- `Node` → **call-by-value**: avalia todos os filhos primeiro
  (`sequence $ evalTree args <$> opArgs` — o `Maybe` curto-circuita no
  primeiro `Nothing`), depois aplica `eval f evaluatedArgs`.
- Se o resultado for `FloatLit x` com `isNaN x` → `Nothing`
  (**guard via `Control.Monad.guard`**), para que NaN nunca pareça fitness
  bom.

`Maybe Lit` é o contrato central: `Just v` = programa produziu valor;
`Nothing` = **falha de runtime** (divisão por zero, `head []`, NaN, ...). A
fitness trata `Nothing` como erro, nunca como valor plausível.

**Escolhas defensivas em `eval`** (todas documentadas no cabeçalho do módulo):

| Caso | Comportamento | Por quê |
|---|---|---|
| `DivInt/ModInt` por 0 | `Nothing` | não lançar exceção; contar como erro |
| `DivInt x (-1)` | `negate x` | `div` do GHC estoura em `minBound div (-1)` |
| `Range` | guards: `start==stop` → `[start]`; step 0 ou contrário → `[]`; `take 5000` | impedir alocação infinita / OOM em candidatos malucos |
| `Sqrt` | `sqrt (abs f)` | domínio real; casa com expectativas dos benchmarks |
| `If` | **ambas branches já avaliadas** | efeito colateral do call-by-value: branch não escolhida pode derrubar o programa |
| `Map` | `mapM (evalLambda f) l` | falha em 1 elemento falha o `map` inteiro |
| `Concat` | `foldl' append []` | evitar cadeia de thunks em listas longas |
| `Filter` | `error` se o predicado não for Bool | "bug interno", o type-checker deveria ter pegado |

`evalLambda f l = evalTree [l] (_tree f)` — **o parâmetro do lambda vira
`Arg 0` dentro do corpo**, substituindo (sobrepondo) os argumentos do programa.
Consequência de projeto: **o corpo de um lambda não enxerga os argumentos do
programa externo** — o escopo é trocado, não encadeado.

Ao final, os extratores parciais `extractInt/extractFloat/extractChar/
extractString/extractList` são "escape hatches" que `error`am na forma errada:
depois do type-check, forma errada = bug em outro lugar, e falhar alto é melhor
que retornar 0 em silêncio. `extractString` mostra o encoding: `String` do
Haskell é `ListLit GChar` nesta linguagem.

---

### `Grammar.Helpers`

`src/Grammar/Helpers.hs` — dois grupos.

#### Construtores inteligentes / builders de literais

`mkLeaf`, `litT`, `arg`, `stLit` (String → `ListLit GChar`), `pairLit`,
`lambdaLit`, `listLitOf` (inferido — **parcial**, falha em `[]`),
`tListLitOf` (tipo explícito), e as variantes com `T` que já devolvem folha:
`iLitT`, `fLitT`, `bLitT`, `chLitT`, `stLitT`, `pairLitT`, `lambdaLitT`.

```haskell
listConsNode gType = foldr (\acc t -> Cons <| [acc, t]) (litT $ ListLit gType [])
```

Nota de `foldr`: os elementos mais externos ficam como cabeças, então
`listConsNode GInt [1,2]` avalia para `[1,2]` na ordem certa.

#### O cache de medidas

```haskell
data Measure = MkMeasure { _currentDepth :: !Int, _height :: !Int, _nodeCount :: !Int }
```

- `computeMeasure :: Tree -> Tree` — **uma única travessia bottom-up** anota
  tudo: `height = 1 + maximum (heights dos filhos)`, `nodeCount = 1 + soma`,
  `currentDepth` é repassado de cima (+1 por nível).
- `getMeasure` lê o cache e, se faltar, calcula **mas não escreve de volta**
  (Haskell é imutável — o valor é descartado pelo chamador). Por isso a
  recomendação: `computeMeasure` uma vez, leia muitas.
- `resetMeasure` invalida tudo (usado quando a forma muda: crossover,
  leitura de checkpoint via `read`, etc.). Uma medida velha reportaria
  tamanhos errados silenciosamente.
- `getHeight`/`getNodeCount`/`getCurrentDepth` são os getters usados por
  tudo (limites de profundidade, desempate por parsimônia, logging).

**Por que memoizar?** profundidade/altura/tamanho são consultados em cada
indivíduo, a cada passo; recalcular dominaria o runtime. O preço é a
disciplina de invalidar (`resetMeasure`) ou recomputar (`computeMeasure`)
nos pontos de mutação da árvore — `mkIndividual` faz isso automaticamente.

---

### `Grammar.Pretty`

`src/Grammar/Pretty.hs` — renderiza valores da gramática em algo próximo de
Haskell. Servem dois públicos: humanos lendo logs/soluções e **testes** que
comparam strings. Não é alvo de parser (nada lê essas strings de volta).

Estratégia de impressão de nós (`instance Pretty Tree`), em ordem de
prioridade:

1. `if` → layout ternário especial `if c then a else b`;
2. operador com símbolo infixo (`binaryOperatorMap`: `+ - * / > < == && || :`)
   → impressão infixa com parênteses só onde um filho é nó;
3. nome amigável (`customNameMap`: `Len → length`, `DivInt → div`,
   `IntToFloat → fromIntegral`, ...);
4. `ToPair` → `(a,b)`;
5. fallback: `lowerFirst (show x)` + argumentos → `Singleton xs` vira
   `singleton xs`.

Outros detalhes:

- `ListLit GChar` imprime como string Haskell (`"abc"`) — é o que os
  benchmarks lidam.
- **Lambda imprime `\y -> ...`**: o corpo foi escrito com `x0` para o
  parâmetro, então `replace "x0" "y"` renomeia na impressão (evita o
  `\x0 -> x0` confuso). `replace` é programação sobre listas com
  `stripPrefix` (guarda `from` vazio para não loopar infinitamente).
- `args = (' ' :) . unwords . map parensIfNeeded` — seção inicial `' ' :` é
  um ponto idiomático.
- `pretty (GPoly n) = [toEnum (fromEnum 'a' + n)]` — `GPoly 0` vira `"a"`.
- **Truque de instances:** `instance {-# OVERLAPPABLE #-} Pretty a => Pretty
  [a]` para listas genéricas; o pragma faz a instância `Pretty Lit`
  (que trata `ListLit GChar` especialmente) vencer quando aplicável.

---

### `Grammar.Simplify`

`src/Grammar/Simplify.hs` — regras de reescrita **que preservam semântica**,
para encolher programas sem mudar o que eles fazem.

Por que: a GP gera `x + 0`, `if True then a else b`, `(x+0)*1`. Isso gasta
orçamento de profundidade e faz a população encher de clones disfarçados.

**`simplifyTree`** (bottom-up; entra também em corpos de lambda):

1. simplifica os filhos;
2. se **todos** os filhos viraram literais → *constant folding*: avalia o nó
   com `evalTree []` e substitui pelo resultado (`Nothing` = mantém o nó);
3. senão, se o operador é comutativo (`AddInt, MultInt, AddFloat, MultFloat,
   And, Or, EqInt, EqChar`) → testa **todas as permutações** dos filhos e
   fica com a de menor `nodeCount` (forma canônica, ajuda deduplicação);
4. senão → `applyRules`.

**`applyAssociativeRules`** reassocia `a op (b op x)` / `(a op x) op b` para
`(a op b) op x`, aproximando constantes para que as regras de identidade
 possam dobrá-las (`1 + (x + 2)` → `(1+2) + x` → `x + 3`).

**`applyRules`** é a tabela de regras — uma guarda por equação em `go`:

- *condicionais*: `if True then a else b = a`, `if c then a else a = a`,
  `if not c then a else b = if c then b else a`;
- *reflexividade*: `x == x = True`, `x < x = False`, `x - x = 0`, `x `div` x = 1`...;
- *identidades/aniquiladores*: `x+0 = x`, `x*0 = 0`, `x/1 = x`, `x `mod` 1 = 0`;
- *cancelamento*: `(a*b)/a = b`, `(a*b) `mod` a = 0`;
- *projeção de par*: `fst (a,b) = a`;
- *álgebra booleana*: curto-circuito de `&&`/`||` com operando literal;
- *leis de lista*: `length [..]` (dobra), `length (singleton x) = 1`,
  `length (x:xs) = 1 + length xs`, `length (reverse x) = length x`,
  `head (singleton x) = x`, `reverse (reverse x) = x`,
  `take (length x) x = x`, `range s s _ = singleton s`;
- *(if c then a else b) == r* com `a,b,r` literais → colapsa para `c`,
  `not c` ou `False` (`applyEqualIfRule`), decidindo **sem avaliar** a branch
  não tomada.

`isLit` decide se o folding constante pode disparar. Como toda regra preserva
semântica, o `Prune` pode rodá-la sobre soluções já validadas.

---

## 4. Camada `Evolution` — o motor de busca

### `Evolution.Core`

`src/Evolution/Core.hs` — 4 aliases que fazem as assinaturas lerem como o
algoritmo de um livro texto:

```haskell
type Point    = Int                      -- índice em travessia pré-ordem (1-based)
type St a     = S.State R.StdGen a       -- TODO cálculo estocástico
type Depth    = Int
type PopSize  = Int
type Mutation = Tree -> St Tree
```

**`St` é a espinha dorsal.** Manter o gerador num `State` (em vez de
aleatoriedade global de `IO`) é o que torna a corrida reproduzível a partir
de uma única seed. A aleatoriedade nunca sai de `System.Random` puro.

---

### `Evolution.Config`

`src/Evolution/Config.hs` — todos os knobs da busca num registro **GADT**:

```haskell
{-# LANGUAGE GADTs #-}

data Config a where
  MkConfig :: Ord a =>
    { _programType :: !ProgramType,      -- tipos de entrada/saída desejados
      _fullTable   :: !SamplerTable,     -- amostragem para geração "full"
      _growTable   :: !SamplerTable,     -- amostragem para geração "grow"
      _maxTreeDepth :: !Depth,           -- 15: limite global
      _maxMutationTreeDepth :: !Depth,   -- limite do subtree gerado na mutação
      _maxInitialDepth :: !Depth,        -- limite da população inicial
      _popSize :: Int,                   -- 1000
      _individualsPerStep :: Int,        -- 2 pais por passo
      _nEvaluations :: Evaluations,      -- 300000 = "combustível" da corrida
      _fitnessFunction :: Tree -> a,     -- puro => fitness determinística
      _parentScalar :: Double,           -- 0.9993: decaimento da seleção
      _crossoverRate :: Double           -- 0.5
    } -> Config a
```

**Por que GADT e não record comum?** O campo `_fitnessFunction :: Tree -> a`
junto com a restrição `Ord a` que a máquina de ordenação
(`Evolution.Individual`) exige. Num record Haskell2010 semanântica de
existencial, você não consegue anexar `Ord a` junto com o valor que o
necessita; o GADT **empacota a constraint com o valor**, e quem constrói o
`Config` a satisfaz no momento da construção. Quem lê `mkIndividual` ganha a
constraint de graça.

`Evaluations` é a moeda do orçamento: **cada indivíduo já pontuado conta**,
inclusive duplicatas e falhas.

---

### `Evolution.Fitness`

`src/Evolution/Fitness.hs` — a classe que o laço genérico precisa sem saber
o tipo concreto da métrica:

```haskell
class (Ord a, Show a, Read a) => Fitness a where
  logFitness          :: a -> String     -- como escrever no CSV
  isPerfectSolution   :: a -> Bool       -- quando parar a busca
```

Instâncias:

| Instância | `logFitness` | `isPerfectSolution` |
|---|---|---|
| `Int` | `show` | `<= 0` |
| `Integer` | `show` | `<= 0` |
| `Float` | `show` | `< 1e-3` (tolerância: 0 exato é inalcançável) |
| `Sum a` | do componente | do componente (perfeito só se todos perfeitos) |
| `Result a` | `Result x → logFitness x`; `Error → "nan"` | `Error → False` |

Convenção: **menor é melhor**, 0 = perfeito. É isso que faz a `Ord` da
população significar "melhor primeiro".

O `instance Fitness a => Fitness (Result a)` é o que permite o laço ser
genérico sobre `Result (Sum Integer)` (problemas inteiros),
`Result (Sum Float)` (floats) etc., sem saber o tipo de baixo nível.

---

### `Evolution.Individual`

`src/Evolution/Individual.hs` — candidato + população.

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}

data Individual a where
  MkIndividual :: (Fitness a) => { _indTree :: !Tree, _fitness :: a } -> Individual a

type SortedPop a = SL.SortedList (Individual a)
```

- **GADT de novo**, agora guardando `Fitness a` junto do valor — é isso que
  permite `deriving instance Fitness a => Show (Individual a)` via
  *standalone deriving* sob demanda.
- `SortedPop` usa a biblioteca `sorted-list`, um tipo **abstrato** que mantém
  a invariante de ordenação: quem chama não consegue desordenar por acidente.
  Assim "melhor indivíduo" é sempre `head`, e truncar no top-N é `SL.take`.

**Instâncias que carregam a heurística da GP:**

```haskell
instance Eq (Individual a) where
  i1 == i2 = _indTree i1 == _indTree i2    -- fitness ignorado (é função da árvore)

instance Ord (Individual a) where
  compare i1 i2 = case compare (_fitness i1) (_fitness i2) of
    EQ -> compare (getNodeCount $ _indTree i1) (getNodeCount $ _indTree i2)  -- desempate!
    x  -> x
```

O desempate por **menor número de nós** é **pressão de parsimônia**: programas
bloated perdem para os compactos quando acertam igual. Isso é um pilar do
controle de bloat do sistema.

`mkIndividual` faz `computeMeasure` **antes** de pontuar, garantindo que a
árvore guardada sempre tenha cache de medida válido (profundidade, desempate,
logging podem confiar).

---

### `Evolution.SamplerTable`

`src/Evolution/SamplerTable.hs` — **o coração do "typed" em HOTGP**. 347
linhas que resolvem: *"preciso de uma árvore de profundidade d produzindo o
tipo t — qual nó ponho na raiz?"*

#### O problema

Escolher um operador aleatório produz lixo (`head` onde é preciso `Int`,
aridade errada...). A tabela **pré-computa**, para cada combinação
(profundidade restante, tipo de saída exigida), a lista de escolhas legais.

#### A tabela

```haskell
type SamplerTable = M.Map (Depth, OutputType) SamplerTableRow
type SamplerTableRow = (UsesInput, [Either (St Terminal) (St (Operation, FunctionType))])
```

- chave = `(profundidade restante, tipo exigido)`;
- valor = flag `UsesInput` + alternativas. Cada alternativa é ou uma **ação**
  que produz um terminal (`Left`) ou uma **ação** que devolve operador + a
  *instanciação da assinatura* que faz caber nesta célula (`Right`).
- Ser ação, e não valor, é essencial: **literais aleatórios (ERCs) ficam
  adiados** até o momento em que o nó é de fato amostrado.

```haskell
data UsesInput = UsesInput | DoesNotUseInput
instance Semigroup UsesInput where
  DoesNotUseInput <> DoesNotUseInput = DoesNotUseInput
  _ <> _ = UsesInput
instance Monoid UsesInput where mempty = DoesNotUseInput
```

**Truque de Haskell:** um *semigrupo de dois pontos* customizado. `mconcat`
sobre a lista de escolhas de uma célula responde "esta linha **pode** produzir
árvore que lê seus inputs?" — usado para rejeitar lambdas **vazios** (cujo
corpo ignora o parâmetro).

#### `buildTree` — a descida recursiva

```haskell
buildTree :: SamplerTable -> Depth -> OutputType -> St Tree
buildTree table depth outputType = do
  node <- sample $ snd $ table M.! (depth, outputType)   -- escolha uniforme
  case node of
    Left stTerm -> mkLeaf <$> stTerm
    Right st -> do
      (op, fType) <- st
      args <- sequence $ buildTree table (depth - 1) <$> _argTypes fType
      return $ op <| args
```

Como a tabela **já** garantiu legalidade, a amostragem é uma descida simples.
Cada filho recebe `depth - 1`, logo a árvore não excede a profundidade pedida.
`sequence` no list monad combina as ações dos filhos.

#### `buildTableForLevel` — como a tabela é montada

Parâmetros: `currentLambdaLevel` (0 = topo do programa), `TermsAndOps`,
`maxDepth`, `forceFullTree`.

```haskell
data TermsAndOps = MkTermsAndOps
  { _arguments :: !(M.Map OutputType [Int])    -- tipo -> índices de argumentos
  , _literals  :: !(M.Map OutputType [St Lit]) -- ERCs (ações!)
  , _operations:: !(M.Map OutputType [Operation])
  }
```

- `terms = M.unionWith (<>) argMap litMap` — junta argumentos (marcados
  `UsesInput`) com constantes (`DoesNotUseInput`). Usa o `Semigroup` da
  tupla, que combina os dois componentes.
- `mapping` materializa células para `depth <- [0..maxDepth]` e
  `outputType <- relevantTypes` (**comprehension de lista como monad**:
  `M.fromList $ do depth <- ...; outputType <- ...; return (...)`).
- `buildTableRow`:
  - `(0, GLambda ft)` → só um lambda literal construído da tabela **aninhada**
    (operações não produzem tipo função aqui);
  - `(0, outType)` → apenas terminais (no fundo tudo deve parar);
  - `(depth, outType)` → terminais (**só em modo grow**; em modo `full` a
    linha de terminais é `mempty`, forçando a árvore a descer até o fundo)
    **mais** operadores legais.
- Para cada operador: `instantiateArgs` lista instanciações viáveis, filtra as
  que têm pelo menos uma escolha legal em cada filho (`areArgsValid` via
  `guard` no list monad), e monta `(op, argTypes ->> outType)`.
  - `rowsToCheck` reflete a diferença full/grow: em `full` o filho é fixado
    exatamente em `mDepth`; em `grow` qualquer profundidade `0..mDepth` serve.
  - `mappingUsesInput`/`doArgsUseInput` propagam a flag `UsesInput` da sublinha
    para cima (`foldMap` — `foldMap` do `Monoid UsesInput`).

#### Lambdas de ordem superior

```haskell
maxLambdaDepthAtEachLevel = [3, 0]
maxLambdaLevel = 2
```

- Nível 0 (lambda externo): corpo até profundidade 3.
- Nível 1 (lambda dentro de lambda): profundidade 0 — o corpo só pode ser algo
  estilo identidade; e o filtro `head (_argTypes ft) /= _outType ft` descarta
  assinaturas `a -> b` com `a /= b` (só `a -> a` é possível com "id").
- Aninhamento é limitado porque o número de células cresce e lambdas muito
  profundos raramente são úteis.

`lambdaMappings` constrói, **uma tabela aninhada por tipo de lambda**
relevante, com `buildTableForLevel (level+1)` e os **parâmetros do lambda no
lugar dos argumentos do programa** (`typesToArgMap (_argTypes ft)`). Uma
assinatura é rejeitada se: a profundidade é inatingível, o corpo **não usaria
o parâmetro** (`DoesNotUseInput`), ou não há o que amostrar.

`generateLambda` ainda **re-tenta** até o corpo conter um `LeafArg` — a tabela
sabe se o corpo *poderia* usar input, não se *esta* amostra usou. O teste
(`hasInput`) é sintático puro.

#### `instantiateArgs` — a instanciação de tipos

```haskell
instantiateArgs relevantTypes desiredOutputType op =
  case unifyTypes desiredOutputType (opOutput op) of
    Nothing -> []
    Just gt -> getPossibilities (opArgTypes op) relevantTypes (learnTypes (opOutput op, gt))
```

Usa a **list-monad como monad de escolha não-determinística** com threading de
restrições:

- `Just xs` (argumento já decidido por vínculo anterior) → ramifica só entre os
  tipos relevantes que unificam com `xs`, estendendo `constraints`;
- `Nothing` (ainda não decidido) → ramifica entre todo tipo relevante que
  unifique, acrescentando o vínculo novo;
- `checkConstraints` aplica os vínculos acumulados a um tipo (descendo em
  `GList`/`GPair`/`GLambda`), devolvendo o tipo concreto ou `Nothing` se
  conflitar.

Exemplo: pedir `[Int]` de `map :: (a->b) -> [a] -> [b]` produz todas as
instâncias cujos tipos são "relevantes" para o benchmark — a restrição de
gramática do problema.

---

### `Evolution.Generate`

`src/Evolution/Generate.hs` — população inicial (Koza).

```haskell
full  cfg = buildTree (_fullTable cfg)   -- toda ramificação vai até o fundo
grow  cfg = buildTree (_growTable cfg)   -- pode parar cedo com terminais
```

Ambos só delegam: a legalidade tipada já está na tabela.

**`ramped` — "ramped half-and-half"** (a inicialização padrão de Koza):

```haskell
ramped cfg = go [] (_popSize cfg) 2
  where
    go pop 0 _ = return pop
    go pop nPop minDepth = do
      treesFull <- replicateM half     (full cfg minDepth outputType)
      treesGrow <- replicateM (half+r) (grow cfg minDepth outputType)
      go (treesFull <> treesGrow <> pop) (nPop - n) (minDepth + 1)
      where
        range = maxDepth - minDepth + 1
        n     = nPop `div` range
        (half, r) = quotRem n 2
```

Leitura: começando na profundidade 2 e subindo até `_maxInitialDepth`, cada
rodada é responsável por uma fatia da população (`n = nPop / faixas
restantes`), metade `full` metade `grow`; o resto da divisão (`r`) vai para
`grow`. A recursão para quando a população está cheia. Com `popSize=1000`,
`maxInitialDepth=15`, a última rodada tem `range = 1` e absorve todo o resto
— logo a população fecha exata.

`outputType` é sempre a **saída do programa** (todo candidato precisa produzi-la).

---

### `Evolution.Helpers`

`src/Evolution/Helpers.hs` — aleatoriedade + "aplicar numa posição".

**Aleatoriedade** (wrappers finos sobre `System.Random` dentro de `St`):

```haskell
random   = S.state R.uniform
randomR  = S.state . R.uniformR
randoms  = S.state (\g -> let (g1,g2) = R.split g in (R.randoms g1, g2))  -- avança 1x
sample [] = error "Sampling empty list!"
sample xs = do idx <- randomR (0, length xs - 1); return (xs !! idx)
```

`sample` em lista vazia é sempre bug do chamador (ex.: pedir parceiro de
crossover num pool vazio), então `error` é aceitável.

**Endereçamento por posição:**

```haskell
atRandomPoint :: Mutation -> Mutation
atRandomPoint f tree = do
  point <- randomR (1, getNodeCount tree)   -- uniforme: cada nó é igualmente provável
  atPoint point f tree
```

```haskell
atPoint :: Point -> Mutation -> Mutation
atPoint n f t@Leaf {} = f t
atPoint point f t@(Node measure v ch)
  | point <= 1 = f t                                     -- achou
  | otherwise  = Node measure v <$> changeChildren (point - 1) f ch
  where
    changeChildren p f (t:ts) =
      if n < p then (t :) <$> changeChildren (p - n) f ts   -- pula este filho
               else (: ts) <$> atPoint p f t                -- desce nele
      where n = getNodeCount t
```

É a **navegação por pré-ordem 1-indexada**: o índice conta nós em travessia
DFS à esquerda (ex.: `1 [2 [3,4], 5, [6,7]]`). A mágica é usar
`getNodeCount` de cada filho para decidir "o alvo está antes deste filho
(subtraio) ou dentro dele (desço)". `Node measure v <$> changeChildren ...` é
`fmap` sobre a **tupla/functor implicitamente** — na verdade `<$>` sobre o
`St`, combinando o reconstruimento do nó com a ação monádica dos filhos.

`tossCoin`-like helpers e `tupleToList (x,y) = [x,y]` (alimenta `mapM`) também
vivem aqui.

**`hoistState`** é a ponte entre mundos:

```haskell
hoistState :: Monad m => S.State s a -> S.StateT s m a
hoistState = S.state . S.runState
```

Leva um cálculo **puro** de estado para o mundo `StateT StdGen IO` do laço de
execução (que também precisa de log e arquivos), **mantendo o mesmo
gerador**. É o adaptador que deixa os operadores genéticos puros e o loop com
IO.

---

### `Evolution.Mutation`

`src/Evolution/Mutation.hs` — substituição de subtree (clássica de Koza):

1. sorteia um nó do pai (`atRandomPoint`);
2. gera uma subtree nova (`grow`) de profundidade máxima limitada;
3. substitui a subtree sorteada;
4. se a profundidade resultante estourar `_maxTreeDepth`, usa o pai ou
   recomeça (aqui: o orçamento já foi calculado para não estourar).

```haskell
replaceSubtree config tree =
  grow config
    (min (_maxMutationTreeDepth config)
         (_maxTreeDepth config - getCurrentDepth tree))   -- orçamento restante!
    (inferOutputType argTypes tree)                       -- MESMO tipo do substituído
```

Duas restrições, ambas essenciais:

- **tipo**: `inferOutputType` descobre o que a subtree substituída produzia, e
  o gerador só constrói algo daquele tipo — o pai permanece bem tipado;
- **profundidade**: `min (maxMut) (maxTree - profundidadeAtual)` significa que
  uma mutação **perto do fundo de uma árvore profunda é forçada a ser rasa**.
  É o que impede o crescimento sem limite (bloat).

Sem isso, "substituir subtree aleatória por subtree aleatória" produziria
programas mal tipados quase sempre, desperdiçando o orçamento de avaliações.

---

### `Evolution.Crossover`

`src/Evolution/Crossover.hs` — troca de subtree **sem quebrar tipos**.

Algoritmo (`crossOver`):

1. sorteia um nó do progenitor 1 (`randomR (1, getNodeCount t1)`);
2. `getBranchAt p1 t1` recupera a subtree (mesma navegação por contagem de nós
   de `atPoint`, mas **pura** — devolve a árvore, não a reconstrói);
3. `getAllMatchingSubtrees cfg b1 t2` coleta **todas** as subtrees do progenitor
   2 cujo tipo de saída casa **e** cuja profundidade cabe nos dois sentidos;
4. se nenhuma casar → `Nothing` (o chamador mantém os pais — **nenhuma
   avaliação é desperdiçada**);
5. senão sorteia uma delas e faz a troca bidirecional (`atPoint` duas vezes).

```haskell
satisfies candidateBranch =
  inferOutputType argTypes candidateBranch == desiredOutType   -- tipos casam
    && candidateBranch `fitsIn` branch                          -- cabe no 1
    && branch `fitsIn` candidateBranch                          -- cabe no 2

fitsIn src dest = getCurrentDepth dest + getHeight src <= _maxTreeDepth cfg
```

O teste de encaixe é **bidirecional** porque cada pai tem orçamento de
profundidade diferente.

A coleta é uma travessia pré-ordem que devolve `(Point, Tree)` junto, para a
troca não precisar de segunda busca:

```haskell
go n t@Node {_args = trs} = (nChildren, this ++ children)
  where
    this = [(n, t) | satisfies t]
    (nChildren, children) = foldl' f (n + 1, []) trs
    f (p, ls) tr = (ls ++) <$> go p tr        -- <-- functor da TUPLA
```

**Truque de Haskell:** `(ls ++) <$> go p tr` aplica `(ls ++)` ao *segundo*
elemento da tupla retornada por `go` — `(<$>)` sobre `(,) e`. Evita
desempacotar manualmente. Os dois `TODO: Write tests` no módulo são honestos:
`getAllMatchingSubtrees` e `getBranchAt` ainda não têm testes dedicados.

---

### `Evolution.Run`

`src/Evolution/Run.hs` — **o laço evolutivo**. Exporta
`runAndLog`, `runEvolution` e os seletores `Individual (_indTree, _fitness)`.

#### Modelo: *steady-state*, não generacional

- a população **nunca** é substituída por inteiro;
- cada iteração ("passo") amostra alguns pais, gera filhos, **mescla** com a
  população e mantém só os melhores `_popSize` (`keepBest`);
- elitismo **por construção**: o melhor jamais cai;
- o número de avaliações cresce suavemente → bom para checkpoint e para
  plotar fitness vs. orçamento.

#### `runAndLog` (a usada pelos benchmarks)

```haskell
runAndLog :: (Show a, Fitness a)
          => Config a -> LoggingFunction s a -> FilePath
          -> S.StateT StdGen IO (SortedPop a, Int)
```

1. `doesCheckpointExist`? → `loadCheckpoint` (retoma avaliação + população +
   RNG) senão `startFromScratch` (`hoistState $ initPop cfg`).
2. Loop `go maybeStatsCache nEvals pop`:
   - se `nEvals mod 1000 == 0` → `saveCheckpoint`;
   - `hoistState $ steadyStateReplace cfg pop` → `totalNEvals`;
   - imprime `timestamp  n/total (pct%)` com `printf`;
   - se `isPerfectSolution (_fitness (bestIndividual newPop))` → imprime
     `"Perfect solution found! <programa>"` e retorna;
   - senão se `totalNEvals >= _nEvaluations` → retorna;
   - senão → recursão.

**A pilha de monads:** o gerador vive em `StateT StdGen IO` — `IO` para log e
arquivos, `State` para aleatoriedade reprodutível; `hoistState` move as
contas puras entre os dois, `S.liftIO` para o IO.

> **Nota (ver §11):** as chamadas ao `loggingFunction` estão **comentadas**
> (`-- go (Just statsCache) ...` / `-- newStatsCache <- ...`). Por isso o
> `.log.csv` sai só com o cabeçalho — o mecanismo existe e está correto, mas
> está desligado.

#### `steadyStateReplace` — um passo

```haskell
steadyStateReplace cfg pop = do
  let rankedPop = exponentialRank cfg pop
  parents  <- inPairs . map _indTree <$> sampleManyWithProb (_individualsPerStep cfg) rankedPop
  children <- concat <$> mapM (doCrossover cfg) parents
  xMen     <- mapM (doMutation cfg) children
  let popTrees = map _indTree $ SL.fromSortedList pop
      withoutDuplication = filter (`notElem` popTrees) xMen
      evaluations = length children
      newPop = keepBest cfg pop (mkIndividual cfg <$> withoutDuplication)
  return (evaluations, newPop)
```

Passo a passo:

1. **Seleção por rank exponencial.** `exponentialRank` dá ao rank `i`
   (0 = melhor, pois a lista já está ordenada) o peso `_parentScalar ** i`.
   `sampleManyWithProb` é a *roleta* (veja abaixo). Com `_parentScalar =
   0.9993` o melhor é só ~1.0007× mais provável que o segundo: **seleção
   quase uniforme**, preservando diversidade genética enquanto ainda prefere
   melhores programas. É seleção proporcional à fitness *expressa por rank*
   — robusta a escalas malucas de fitness (só a ordem importa).
2. **Emparelhamento**: `inPairs` agrupa de 2 em 2 (elemento ímpar solto não
   procria). Com `_individualsPerStep = 2`, dá **1 par por passo**.
3. **Crossover** com prob. `_crossoverRate` (`doCrossover`); o complemento é
   passado adiante.
4. **Mutação** com prob. `1 - _crossoverRate` (`doMutation`).
5. **Deduplicação**: filhos que já existem na população são descartados
   (avaliá-los de novo seria orçamento jogado fora).
6. **`keepBest`**: `SL.take _popSize (oldPop <> toSortedList children)` —
   merge ordenado + truncamento. Elitismo puro.

`doCrossover`/`doMutation` usam `tossCoin`:

```haskell
tossCoin prob fallback action = do
  toss <- (< prob) <$> (randomR (0,1) :: St Double)
  if not toss then return fallback else action

doCrossover cfg parents =
  tossCoin (_crossoverRate cfg) (tupleToList parents) $
    maybe [] (map computeMeasure . tupleToList) <$> uncurry (crossOver cfg) parents
```

Leituras finas:

- fallback do crossover = os **próprios pais** passados adiante (→ depois
  filtrados como duplicatas → custo 0);
- se o crossover roda mas retorna `Nothing` (nenhum parceiro compatível) →
  `[]`, ou seja, **nenhum filho**;
- `computeMeasure` é aplicado aos filhos porque **transplantar subtree
  invalida o cache de profundidade/altura de todos os ancestrais**;
- `doMutation` usa `1 - _crossoverRate` como probabilidade: os dois
  operadores se complementam.

`sampleManyWithProb` é roleta sobre pesos **não normalizados**:

```haskell
cumSum = fmap reverse . foldl' cumSumReducer (0, [])
sampleWithProb = do rand <- randomR (0, max)
                    return $ fst . fromJust $ find ((> rand) . snd) roulette
```

Acumula soma cumulative (o `reverse` devolve à ordem original), sorteia em
`[0, total]` e pega o primeiro cujo limiar cumulativo excede o sorteio.
Só as razões dos pesos importam.

**`runEvolution`** é a versão *pura* (sem log/checkpoint, tudo em `St`) — usada
por experimentos e testes.

**`keepBest` vs `replaceWorst`:** a primeira é a estratégia real; a segunda
está definida "para experimentação" mas **não está ligada ao laço** (código
morto intencional).

---

### `Evolution.Checkpoint`

`src/Evolution/Checkpoint.hs` — salvar/restaurar corridas longas.

Um checkpoint guarda tudo necessário para continuar **exatamente** onde parou:

```haskell
data Checkpoint = MkCheckpoint
  { _gen :: (Word64, Word64),   -- os dois words do gerador SplitMix
    _population :: [Tree],       -- só árvores! fitness é recalculado no load
    _currentEvals :: Int
  } deriving (Show, Read, Generic, Flat)
```

Decisões técnicas notáveis:

- **Serialização com a biblioteca `flat`** (formato binário compacto).
  Populações são grandes; JSON/texto seria ordens de grandeza mais lento e
  maior. `flat` deriva instâncias a partir de `Generic`.
- **Instâncias `Flat` derivadas *aqui*, não em `Grammar`**: são
  *standalone deriving* (`deriving instance Flat Tree`, etc.) para não criar
  **instâncias órfãs** — `Grammar` deliberadamente não depende de `flat`.
  O comentário no módulo deixa explícito esse trade-off.
- **`_population :: [Tree]`, sem fitness**: ao carregar, `decodeCheckpoint`
  re-ponta cada árvore com o `_fitnessFunction` do config. Assim o formato de
  arquivo fica independente do tipo de fitness — e continua válido se a
  função de fitness ou a tolerância mudarem entre execuções.
- **RNG**: `makeCheckpoint` pega `unStdGen :: StdGen -> SMGen` e
  `unseedSMGen :: SMGen -> (Word64, Word64)`; `decodeCheckpoint` faz o
  inverso (`S.put (StdGen $ seedSMGen' ...)`). Resultado: a sequência
  aleatória da corrida retomada é a mesma da interrompida.
- Arquivo corrompido = **erro duro** (`fromRight (error ...)`) — reiniciar em
  silêncio jogaria horas de cálculo fora sem avisar.
- Escrito *in place*, uma vez a cada 1000 avaliações → sempre um arquivo por
  par `(seed, benchmark)` (o nome da chave está em
  `Benchmark.Run.checkpointFilename`).

---

### `Evolution.Pretty`

`src/Evolution/Pretty.hs` — imprime uma população como tabela com moldura:

```
┬────────┬───────────────────
│ Fitness │ Tree
├────────┼───────────────────
│ 0       │ length x0
┴────────┴───────────────────
```

**Truque de Haskell bem interessante** — o `newtype Zip`:

```haskell
newtype Zip a = Zip { getZip :: [a] }

instance Semigroup a => Semigroup (Zip a) where
  Zip (a:as) <> Zip (b:bs) = Zip (a <> b : getZip (Zip as <> Zip bs))
  _ <> _ = Zip []
```

É um semigrupo que **zippa duas listas elemento a elemento**, combinando com o
`<>` do elemento. Combinado com `Max`:

```haskell
widths = map getMax $ getZip $ foldl1 (<>) $
         map (Zip . map (Max . length)) (shown <> header)
```

`foldMap (Zip . map (Max . length))` sobre as linhas da tabela produz, **num
único fold**, a largura da coluna mais larga de cada coluna. Depois `pad`
espaça com `zipWith` + `replicate`, e os separadores são montados com
`intercalate ['─', m, '─']`. `FlexibleInstances` é necessário para
`instance Show a => Pretty [Individual a]`.

---

## 5. Camada `Benchmark` — problemas, dados e execução

### `Benchmark.Core`

`src/Benchmark/Core.hs` — o **registro declarativo** de um problema:

```haskell
data Benchmark a = MkBenchmark
  { _datasetName        :: String,             -- nome no GitHub / diretório
    _benchmarkId         :: Maybe String,       -- id da CLI (default = datasetName)
    _inputTypes         :: ProgramArgTypes,    -- tipos dos inputs (e do programa)
    _outputType         :: OutputType,
    _fitnessMetric      :: Lit -> Lit -> a,    -- (esperado, atual) -> contribuição
    _testCases          :: Int,
    _trainCases         :: Int,
    _relevantTypes      :: Set GType,          -- fatia da gramática permitida
    _allowedConstants   :: Map GType [St Lit], -- ERCs por tipo (AÇÕES)
    _customOutputParser :: Maybe OutputParser
  }
```

Sem comportamento: o **mesmo registro** alimenta download, split, construção
de config e logging. Adicionar problema = escrever um record, não mexer em
máquina.

Detalhes:

- `_fitnessMetric :: Lit -> Lit -> a` recebe **(esperado, atual)** e retorna a
  contribuição daquele caso, somável via `mconcat` (as métricas devolvem
  `Sum x`).
- `_trainCases` guiam a busca; `_testCases` só servem para relatório —
  assim um programa **não consegue "vencer" no log por overfitting**.
- `_relevantTypes :: Set GType` restringe o que o sampler pode construir:
  problema numérico não precisa de operações de par, e a tabela fica menor.
- `_allowedConstants :: Map GType [St Lit]` — **valores são ações `St Lit`**
  porque alguns constantes são sorteios aleatórios (ERC = *ephemeral random
  constant*), que precisam ser sorteados **na hora da amostragem**, não na
  construção da config.
- `type StatsCache = (Tree, (Float, Maybe Float))` — cache de 1 entrada para
  não re-pontuar o melhor a cada linha de log.
- `getBenchmarkId` = `fromMaybe _datasetName _benchmarkId`.

---

### `Benchmark.Problems` + `Benchmark.Problems.*`

`src/Benchmark/Problems.hs` é o **catálogo**. Importa os 24+ módulos de
problema e oferece o dispatcher da CLI.

**Truque de Haskell central: tipo existencial.**

```haskell
{-# LANGUAGE GADTs #-}

data Problem where
  MkProblem :: (Fitness a, Monoid a, Show a) => Benchmark a -> Problem

allProblems :: [Problem]
allProblems = [ MkProblem compareStringLengths, MkProblem countOdds, ... ]

getProblem :: String -> Maybe Problem
runProblem :: FilePath -> Int -> String -> IO ()
```

Os problemas têm tipos de fitness **diferentes** (`Sum Integer`, `Sum Float`,
`Result (Sum ...)`...). O wrapper `Problem` **esconde o tipo** mas carrega as
constraints que `runBenchmark` precisa. Resultado: uma **lista homogênea**
`[Problem]` onde cada elemento pode ser executado sem o chamador saber o tipo.
Pattern matching em `MkProblem` traz as constraints para o escopo.

Também expõe `allProblemIds` (usado pela ajuda da CLI — nunca fica desatualizado)
e `searchCxRateProblem` (varredura de crossover rate).

Cada `Benchmark.Problems.<Nome>` é um módulo com **um value** `Benchmark a`.
Exemplos representativos:

| Problema | O que ilustra |
|---|---|
| `Median` | o caso mais simples: 3 ints → int, `rightWrong`, constantes ERC `randomR (-100,100)` |
| `CountOdds` | `allowUnaryLambdas` para habilitar `filter`/`map`; ERCs `0,1,2` + random |
| `EvenSquares` | `_customOutputParser` (dataset guarda lista como string com `\n`), métrica `alignWith`/`These` punindo tamanho e valor |
| `ReplaceSpaceWithNewline` | resposta é **par**; parser custom lê `output1` **e** `output2`; métrica soma `intError` + `levenshteinDistance`; ERC de string aleatória com ~20% de espaços |
| `WallisPi` | soma `floatError` com `prettyLevenshteinDistance` (distância sobre a *forma impressa*) |
| `CollatzNumbers` | existe no código mas está **comentado** em `allProblems` |

---

### `Benchmark.Download`

`src/Benchmark/Download.hs` — busca datasets sob demanda do repositório
público `thelmuth/program-synthesis-benchmark-datasets`.

```haskell
csvDirs = "datasets/"
downloadBenchmark workDir name = do
  createDirectoryIfMissing True (workDir <> csvDirs)
  dlAndUnzip workDir name "random"
  dlAndUnzip workDir name "edge"

dlAndUnzip ... = unless fileExists $ do
  callCommand $ "curl -LJ -o " <> fileName <> ".gz " <> url
  let unzipAndShuffle = "gzip --to-stdout -d " <> fileName <> ".gz | sort -R > " <> fileName
  handle (\(e :: SomeException) -> return ()) $ do
    callCommand unzipAndShuffle
    removeFile (fileName <> ".gz")
```

- **Idempotente**: se o arquivo existe, reutiliza (1 download por máquina).
- **Pipeline shell**: `curl` → `gzip -d | sort -R`. O `sort -R` **embaralha**,
  e isso tem consequência: **o split treino/teste é definido no download**.
  Apagar `./datasets/*.json` e baixar de novo gera um split diferente e muda
  os resultados (o README avisa isso).
- `ScopedTypeVariables` para o `\(e :: SomeException) -> return ()` — engole
  qualquer exceção do descompactar (ex.: download devolveu HTML), deixando o
  arquivo no estado que ficou; o parser falhará depois com mensagem mais clara.
- `System.Process.callCommand` roda em `/bin/sh` — daí a dependência POSIX
  listada no README.

---

### `Benchmark.Parse`

`src/Benchmark/Parse.hs` — JSON-lines → `Lit` tipado.

Os datasets são um objeto JSON por linha com `input1..inputN` e `output1`.

```haskell
type OutputParser = Object -> Lit

parseJsonLine :: String -> Object                       -- parcial de propósito
defaultOutputParser gType json = parseJsonLit gType (json ^. "output1")
```

`parseJsonLit :: OutputType -> Value -> Lit` despacha pelo **tipo declarado**:

```haskell
parseJsonLit GInt (Number sci)          = IntLit $ round $ toRealFloat sci
parseJsonLit GFloat (Number sci)        = FloatLit $ toRealFloat sci
parseJsonLit GBool (Bool b)             = BoolLit b
parseJsonLit GChar (String txt)         = CharLit $ T.head txt          -- 1 char
parseJsonLit (GList GChar) (String txt) = stLit $ T.unpack txt          -- string
parseJsonLit (GList gt) (Array vec)     = ListLit gt $ toList $ fmap (parseJsonLit gt) vec
```

`OverloadedStrings` habilita as `Key` do aeson ≥ 2.0. O operador caseiro

```haskell
(^.) :: Object -> String -> Value
(^.) json key = let Just val = KM.lookup (K.fromString key) json in val
```

é um **acessor parcial de propósito** (`Just` irrefletido): campo ausente =
dataset malformado, e falhar rápido é melhor que treinar em lixo
silenciosamente. Essa parcialidade recorrente é um estilo consciente do
projeto: `let Just (Object json) = decode ...`.

---

### `Benchmark.Dataset`

`src/Benchmark/Dataset.hs` — carregar e dividir.

```haskell
type TestCase = ([Lit], Lit)   -- (inputs, esperado)
type Dataset  = [TestCase]

loadTrainAndTestSet workDir benchmark = do
  downloadBenchmark workDir (_datasetName benchmark)
  random <- readJson workDir benchmark "-random.json"
  edge   <- readJson workDir benchmark "-edge.json"
  let (trainSet, remaining) = splitAt (_trainCases benchmark) $ edge <> random
      testSet = take (_testCases benchmark) remaining
  return (trainSet, testSet)
```

**Política de split:**

1. **edge cases primeiro**, depois random — casos-limite são as condições de
   borda interessantes e **sempre** devem estar no treino;
2. primeiros `_trainCases` → treino (driva a fitness);
3. próximos `_testCases` → teste (só relatório).

Como o download já embaralhou o arquivo random, as duas metades são amostras
efetivamente aleatórias.

`loadTrainAndValidationSet foldNumber ...` é a variação **5-fold CV** (usada
pela varredura de crossover rate): particiona a porção *random* do treino em 5
chunks iguais, guarda o chunk `foldNumber` como validação, e treina com edge +
resto. O `getFold` recursivo extrai o i-ésimo chunk preservando a ordem dos
demais — uma implementação elegante de "remover o i-ésimo" em uma lista:

```haskell
getFold 0 xs = (head xs, tail xs)
getFold i (x:xs) = let (el, xs') = getFold (i-1) xs in (el, x : xs')
```

`readJson` lê as linhas, decodifica cada objeto e monta `([inputs], esperado)`.
O truque da lista infinita:

```haskell
transform obj = (zipWith parseJsonLit (_inputTypes benchmark) xs, parseOutput obj)
  where xs = [obj ^. ("input" <> show i) | i <- [1 ..]]
```

`xs` é infinita, mas `zipWith` **para no comprimento de `_inputTypes`** —
lazy evaluation faz o resto.

---

### `Benchmark.Metrics`

`src/Benchmark/Metrics.hs` — as funções de score. Todas têm a forma
`Lit -> Lit -> Sum x`, recebem **(esperado, atual)** e dizem **quão errado**
está. "Menor é melhor", 0 = perfeito.

| Métrica | Tipo | Comportamento |
|---|---|---|
| `rightWrong` | `Sum Integer` | 0 se igual, 1 se não (sem crédito parcial) |
| `intError` | `Sum Integer` | `\|x - y\|`, promovido para `Integer` p/ não estourar |
| `floatError` | `Sum Float` | `\|x - y\|` |
| `boolError` | `Sum Integer` | 0/1 para booleans |
| `levenshteinDistance` | `Sum Integer` | distância de edição sobre os **elementos** das listas |
| `prettyLevenshteinDistance` | `Sum Integer` | idem, mas sobre as **strings impressas** |

Por que `Sum`? Porque `mconcat` sobre os casos de teste vira uma soma
(`/`monoid do `Semigroup` de `Sum`) — é assim que `makeConfig` pontua a suite
inteira numa linha.

**Levenshtein — truque de Haskell (lazy array como memoização):**

```haskell
getLevenshteinDistance xs ys = levMemo ! (n, m)
  where
    levMemo = array ((0,0), (n,m)) [((i,j), lev i j) | i <- [0..n], j <- [0..m]]
    xa = listArray (1, n) xs      -- 1-indexado p/ casar com a formulação clássica
    lev 0 v = v
    lev u 0 = u
    lev u v | xa ! u == ya ! v = levMemo ! (u-1, v-1)
            | otherwise = 1 + minimum [ levMemo ! (u, v-1)     -- insert
                                      , levMemo ! (u-1, v)     -- delete
                                      , levMemo ! (u-1, v-1) ] -- substitute
```

`Data.Array.array` constrói o array **de forma lazy e auto-referente**: as
entradas dependem de outras entradas do mesmo array, e o GHC resolve isso
sob demanda, na ordem que a recorrência alcança. Sem loops explícitos, O(n·m)
tempo/espaço, memoização embutida. É o idiomático "DP em Haskell".

---

### `Benchmark.Helpers`

`src/Benchmark/Helpers.hs` — utilitários compartilhados.

#### `Result` — o `Maybe` com `Ord` certo

```haskell
data Result a = Result !a | Error deriving (Eq, Ord, Show, Read)
```

Fitness é "menor é melhor", então `Error` precisa ordenar **acima** de todo
sucesso. O `Ord` derivado compara a **tag do construtor primeiro**, e `Error`
é o último construtor → `Error` é sempre o pior valor. (Um `Maybe` comum não
daria essa garantia de forma tão explícita/robusta, e `Result` também carrega
o Monoid a seguir.)

```haskell
instance Semigroup a => Semigroup (Result a) where
  Result x <> Result y = Result (x <> y)
  _ <> _ = Error                      -- qualquer crash envenena tudo
instance Monoid a => Monoid (Result a) where mempty = Result mempty
instance Functor Result where ...
maybeToResult :: Maybe a -> Result a
maybeToResult Nothing = Error
maybeToResult (Just a) = Result a
```

**Efeito prático:** um único caso de teste que crasha derruba a fitness
inteira para `Error`, que é o pior valor possível e nunca é
`isPerfectSolution`. `mconcat` sobre a suite propaga o erro — nenhum programa
que trava pode "vingar" por acertar o resto.

#### Combinadores de tipos relevantes

```haskell
allowList gTypes       = gTypes <> (GList <$> gTypes)
allowPairs gTypes      = gTypes <> (GPair <$> gTypes <*> gTypes)
allowUnaryLambdas gTypes = gTypes <> (GLambda <$> (MkFunctionType <$> ((:[]) <$> gTypes) <*> gTypes))
```

`Functor` sobre funções de tipo: `<$>` em `GList`/`GPair`/`GLambda` expande o
conjunto de tipos "interessantes" com as formas derivadas (container, par,
função unária `t -> t`). Problema que precisa de `map`/`filter` chama
`allowUnaryLambdas` numa linha. `allowUnaryLambdas` também é o que habilita
`GLambda (t -> t)` no sampler — sem ele, nenhuma lambda é gerável.

#### `fisherYatesStep` — **não é usado** (código morto)

Um passo de Fisher-Yates sobre `Map Int a` para embaralhar. O comentário diz
"see the callers in Benchmark.Dataset", mas **não há chamadores**: o
embaralhamento real acontece no shell, via `sort -R`, durante o download.
Ver §11.

`csvJoin = intercalate ";"` — os datasets usam `;` porque inputs podem conter
vírgulas.

---

### `Benchmark.BenchmarkToConfig`

`src/Benchmark/BenchmarkToConfig.hs` — **a ponte** problema → motor.

```haskell
makeConfig :: (Ord a, Monoid a) => Dataset -> Benchmark a -> Config (Result a)
```

```haskell
MkConfig
  { _programType = MkFunctionType (_inputTypes bench) (_outputType bench),
    _maxTreeDepth = 15, _maxMutationTreeDepth = 15, _maxInitialDepth = 15,
    _popSize = 1000, _individualsPerStep = 2,
    _nEvaluations = 300 * 1000,
    _fitnessFunction = fitness,
    _parentScalar = 0.9993, _crossoverRate = 0.5,
    _fullTable = buildTable termsAndOps treeDepth True,
    _growTable = buildTable termsAndOps treeDepth False
  }
  where
    fitness tree = mconcat $
      (\(x, y) -> _fitnessMetric bench y <$> maybeToResult (evalTree x tree)) <$> trainSet
    termsAndOps = MkTermsAndOps
      { _literals  = _allowedConstants bench,
        _arguments  = typesToArgMap (_inputTypes bench),
        _operations = operationsFromTypes (S.toList $ _relevantTypes bench) }
```

A função de fitness merece ser lida devagar, `innermost` para fora:

1. `evalTree x tree` → `Maybe Lit` (crash?);
2. `maybeToResult` → `Result Lit`;
3. `_fitnessMetric bench y <$>` → `Result a` (mapeia a métrica **sobre o
   `Result`**, com `y` = esperado já fixado);
4. `mconcat` sobre todos os casos → `Result a` final (qualquer `Error`
   envenena).

Retorno `Config (Result a)` — exatamente o tipo que o laço (`Fitness`) suporta.

`operationsFromTypes` agrupa operadores **pelo tipo que produzem**:

```haskell
ops = [(minBound :: Operation) .. maxBound]     -- Enum + Bounded = "todos"
findOps t = filter (\op -> isJust $ unifyTypes t (opOutput op)) ops
```

Ou seja: `map` aparece sob **todo** tipo que seu resultado pode ter. Note que
as duas tabelas (`full` e `grow`) são construídas **duas vezes, uma por
config** — é o maior custo fixo de inicialização (tabela × 16 profundidades ×
|relevantTypes| células, cada uma com tabelas aninhadas de lambda).

---

### `Benchmark.Run` / `Benchmark.RunSearch`

**`Benchmark.Run.runBenchmark`** — execução ponta a ponta (já descrita no §2).

Pontos adicionais:

- `hSetBuffering stdout $ BlockBuffering Nothing` no início (performance do
  printf frequente);
- o callback `logToFile` **fechado sobre o handle** do CSV: cada tick grava
  uma linha via `logPop` e devolve o `StatsCache` atualizado; flush a cada 100
  linhas (uma queda perde pouca coisa);
- `checkpointFilename _ seed benchmark = "./checkpoint/s<seed>_<id>.checkpoint"`
  — chaveado por **seed e problema** para que corridas em paralelo não se
  atropelem, mas re-executar o mesmo par **retoma** o estado antigo;
- ao final: `logBest testSet` → `.result.csv` e `jsonBest ...` →
  `.result.json`, sempre do `head` da população ordenada (o melhor).

**`Benchmark.RunSearch.searchCxRate`** — um fold da varredura de
*crossover rate*:

```haskell
let cfg = (makeConfig trainSet benchmark) {_crossoverRate = fromIntegral cxRate / 100}
(finalPop, _) <- evalStateT (runAndLog cfg logToFile checkpoint) (mkStdGen 0)
```

Diferenças em relação ao runner padrão: dados via `loadTrainAndValidationSet`
(fold de validação retido), `_crossoverRate` **sobrescrito com record update**
por cima do default, e **seed fixa em 0** — assim, varrendo `cxRate`, a única
coisa que muda entre execuções é o parâmetro testado. `cxRate` é recebido em
**porcentagem** (0-100) e dividido por 100.

---

### `Benchmark.Log`

`src/Benchmark/Log.hs` — tudo que é gravado em disco.

**Arquivos:**

| Arquivo | Quando | Conteúdo |
|---|---|---|
| `<id>.log.csv` | durante | cabeçalho `time;n_evals;best_fitness;best_depth;best_node_count;best_acc;best_nmse;best_string_rep_simple;best_string_rep` + 1 linha por tick |
| `<id>.result.csv` | final | um caso de teste por linha: `x0..xn;y;y_hat;right` |
| `<id>.result.json` | final | resumo do programa vencedor |

**Funções principais:**

- `prepareLogFiles` cria `./output/` e `./checkpoint/`, abre o CSV e escreve
  o cabeçalho; devolve `(Handle, resultCsv, resultJson)`.
- `logBest dataset t` — gera o CSV final: para cada caso, `pretty` dos inputs,
  do esperado, do obtido (`nan` se crash) e `show (Just y == yHat)`.
- `jsonBest` — monta o JSON **manualmente** com um helper de duas linhas:

  ```haskell
  (.:) :: Show a => String -> a -> String
  key .: value = show key <> ":" <> show value
  ```

  (sim, `show` de uma `String` já adiciona as aspas — é por isso que strings
  saem quoted). Campos: `datasetName`, `seed`, `totalEvals`, `fitness`,
  `height`, `nodeCount`, `accuracy`, `nmse`, `stringRepSimple` (após
  `simplifyTree`), `stringRep` (como evoluiu) e **`showTree`** (a
  representação `show`, que o `prune` lê de volta com `read`).
- `logPop cache testSet time nEvals pop` — uma linha do CSV de progresso,
  devolvendo **`(linha, novoCache)`**.
- `memoLast` — **memoização de 1 entrada**, pura, com cache passado
  explicitamente:

  ```haskell
  memoLast f t@(lastX, lastY) x
    | x == lastX = (lastY, t)
    | otherwise  = let newY = f x in (newY, (x, newY))
  ```

  O cache é explícito (e não escondido em `IO`) porque o laço é de resto puro.
  Evita re-pontuar o mesmo melhor indivíduo a cada tick.

**Métricas de qualidade (sempre no conjunto de TESTE):**

- `accuracy` — fração de casos corretos; floats com tolerância `1e-4` (os
  datasets armazenam valores arredondados); resto exato; crash nunca casa.
- `nmse` — `MSE(pred, atual) / variância(atual)`: 0 = perfeito, 1.0 = não
  melhor que sempre prever a média. Só existe se **tudo** for numérico
  (`runOnNum` devolve `Nothing` caso contrário → loga `nan`).
- `getAccuracyAndNmse` combina os dois com `join`/`liftA2` sobre `Maybe`.

---

## 6. `Prune` — pós-processamento guloso

`src/Prune.hs` — encolhe a solução encontrada **sem perder acurácia**.
Rodado pela CLI (`stack run prune`), processa `input-prune/*.result.json` →
`output-prune/*.result.json`.

**`pruneFile`** por arquivo:

1. lê o JSON com aeson e extrai `showTree` e `datasetName` (pattern matching
   irrefletido em `Just`/`Object`/`String` — dataset malformado = erro);
2. `resetMeasure $ read ...` — **as medidas cached do arquivo referem-se à
   posição original da árvore**, então são descartadas antes de qualquer coisa
   (o round-trip `show`/`read` funciona porque `Tree` deriva `Read`);
3. recarrega o dataset do problema (`getProblem` + `loadTrainAndTestSet`) —
   o **mesmo split** usado na corrida, para as acurácias serem comparáveis;
4. `pruneTree trainSet tree` e depois `simplifyTree` para a variante legível;
5. escreve novo JSON com `Object $ content <> newJson` (todos os campos
   originais + `showPrunedTree`, `stringRepPruned`, `stringRepPrunedSimple`,
   acurácias antes/depois em train e test, `heightPruned`, `nodeCountPruned`).

**`pruneTree` — subida de encosta gulosa:**

```haskell
pruneTree dataset tree = go [] (minimumBy compareTrees [tree, simplifyTree tree])
  where
    compareTrees = compare `on` (\t -> (1 - getAcc dataset t, getHeight t, getNodeCount t))
    go path t = case replaceWithSubtrees path t of
      [] -> iterateNext t path
      subtrees ->
        let bestSubtree = minimumBy compareTrees subtrees
        in case compareTrees t bestSubtree of
             LT -> iterateNext t path          -- t é melhor: mantém
             _  -> go path bestSubtree         -- deleção melhorou: aceita e desce
```

Ranking: **maximizar acurácia** (`1 - acc` é minimizado), depois menor
altura, depois menor node count. Acurácia **nunca é sacrificada** — tamanho
só desempata. Parte do melhor de `(original, simplificado)`.

A caminhada de posições:

- `type TreePath = [Int]` — cadeia de índices de filho a partir da raiz
  (`[]` = raiz, `[0,2]` = 3º filho do 1º filho). Lambdas **não** são um nível
  novo: `nextPath` mergulha no corpo transparentemente (um `LambdaLit` é
  folha sintaticamente, mas seu corpo ainda pode ser podado).
- `replaceWithSubtrees path t` — todas as árvores obtíveis **deletando exatamente
  um nó-wrapper** (promovendo um filho). Caso especial de `Map`:

  ```haskell
  replaceWithSubtrees [] (Node m Map [LeafLit (LambdaLit (MkTypedTree _ (MkFunctionType [a] b))), list])
    | a == b = [list]     -- map id xs = xs; checkPromotableArgs não expressa isso
  ```

  porque para operadores polimórficos `checkPromotableArgs` usa **igualdade de
  tipos** (conservador), não unificação.
- `checkPromotableArgs` usa **ViewPatterns**:

  ```haskell
  checkPromotableArgs (opType -> fType) = map fst $ filter ((_outType fType ==) . snd) $ zip [0..] $ _argTypes fType
  ```

  Só argumentos cujo tipo declarado **iguala** o tipo de saída do operador são
  promovíveis — trocá-los não muda o tipo da expressão.
- Terminação: cada passo aceito **melhora estritamente** o ranking de uma
  árvore fixa, e há finitas subtrees alcançáveis por deleção.
- `setArgAt`/`setAt` remontam a árvore com o filho promovido (`setAt` ignora
  índice fora de range).

---

## 7. `app/Main.hs` — a CLI

```haskell
main = do
  args <- getArgs
  let parsed = parseArgs args
  createDirectoryIfMissing True "./checkpoint"
  case parsed of
    Nothing -> case args of
                 ["prune"] -> prune
                 _         -> showHelp
    Just (name, seed) -> runProblem "./" seed name

parseArgs [nameString, seedString] =
  if nameString `elem` allProblemIds
    then (nameString,) <$> readMaybe seedString
    else Nothing
parseArgs _ = Nothing
```

- **`TupleSections`**: `(nameString,) <$> readMaybe seedString` curifica
  parcialmente uma tupla — sintaxe compacta de "fixar o 1º componente".
- Valida contra `allProblemIds` **em runtime** (a lista vem do registro de
  problemas, então a ajuda nunca desatualiza).
- `workDir = "./"` — **todos** os caminhos (`datasets/`, `output/`,
  `checkpoint/`) são relativos ao diretório corrente; hay que rodar da raiz.
- Sem argumentos válidos → `showHelp` com a lista ordenada dos benchmarks.

---

## 8. `test/` — a suíte de testes

Tasty + QuickCheck + HUnit (~190 testes, ~30s). `test/Spec.hs` só faz wiring:

```haskell
defaultMain $ testGroup "Tests"
  [ testGroup "Grammar"        GrammarSpec.tests,
    testGroup "Evolution"      EvolutionSpec.tests,
    testGroup "Benchmark"      BenchmarkSpec.tests,
    testGroup "Max tree depth" MaxTreeDepthSpec.tests,
    testGroup "Prettify Tree"  PrettyTreeSpec.tests,
    testGroup "Measure"        MeasureSpec.tests ]
```

Os grupos espelham as camadas de dependência do código. Módulos notáveis:

- `GrammarTypesSpec` / `GrammarSimplifySpec` — type-checker e regras de
  reescrita;
- `EvolutionSpec/{AtPoint,Crossover,Generate,Mutation}Spec` — operadores
  genéticos; `EvolutionSpec/Helpers.hs` contém `runTypeCheck`, que é onde
  `Grammar.Types.typeCheck` é **realmente usado**:
  `QC.counterexample ce $ isJust $ typeCheck (_type tt) (_tree tt)` — os
  geradores são validados contra o type-checker por QuickCheck;
- `MaxTreeDepthSpec` — invariantes de limite de profundidade;
- `ProblemTrees` — árvores de referência para os problemas.

Filtros úteis: `cabal test --test-options='--pattern Grammar'`.

---

## 9. Conceitos de Programação Genética implementados

Esta seção consolida, em linguagem de GP, o que a implementação faz.

### 9.1 Representação

- **Árvore de sintaxe** (`Tree`) como no GP clássico de Koza, mas os terminais
  incluem **argumentos do programa** (`Arg n`) e **ERCs** (`Literal`), e os
  nós internos são um enum fixo de primitivas.
- **Tipos**: STGP (*Strongly Typed GP*) — cada nó tem tipo, e só combinações
  bem tipadas existem. Além disso, **ordem superior**: `LambdaLit` torna
  lambdas de primeira classe e `map`/`filter` são primitivas — é o "HOTGP".
- **Sem tipagem no valor**: `Tree` não guarda tipo; tipagem é ou construída
  (sampler) ou conferida sob demanda.

### 9.2 Inicialização

- **Ramped half-and-half** (Koza): mistura `full` e `grow` ao longo de um
  intervalo de profundidades, evitando população inicial idêntica.
- Ambos geradores são **dirigidos por tipos** via `SamplerTable`, então
  nenhum indivíduo inicial é mal tipado.

### 9.3 Avaliação / Fitness

- Fitness = **soma da métrica sobre o treino**, com crash → `Error` que
  envenena a soma inteira. Menor é melhor, 0 = perfeito.
- Crashes (`Nothing` do avaliador) nunca pontuam como valor plausível; NaN é
  filtrado no avaliador.
- **Train/test split** explícito: a busca só vê treino; acurácia/NMSE no
  teste servem para relatório não-enviesado.
- `isPerfectSolution` permite **parada antecipada** (não queima o orçamento
  restante).

### 9.4 Seleção de pais

- **Seleção proporcional ao rank com decaimento exponencial**
  (`_parentScalar ** rank`), amostrada por roleta. É uma variante de
  *fitness-proportionate* que só depende da **ordem**, tornando-a robusta a
  escalas de fitness muito diferentes.
- Com `0.9993`, a pressão seletiva é **deliberadamente fraca** — diversidade
  acima de exploração gulosa.
- `_individualsPerStep = 2` → 1 par por passo.

### 9.5 Operadores genéticos

- **Crossover de subtree** (principal fonte de variação): troca bidirecional,
  **só entre subtrees de mesmo tipo** e **que cabem nos limites de profundidade
  dos dois pais**. Falha = `Nothing` = pais intactos, sem custo.
  Prob. 0.5 (`_crossoverRate`).
- **Mutação de substituição de subtree** (Koza): ponto aleatório uniforme,
  substituto gerado para o **mesmo tipo** e com **orçamento de profundidade
  restante**. Prob. `1 - _crossoverRate`.
- Deduplicação de filhos antes de pontuar.

### 9.6 Seleção de sobreviventes

- **Steady-state** + **elitismo puro**: pais e filhos são mesclados e ficam os
  melhores `_popSize`. O melhor nunca é descartado.
- **Pressão de parsimônia** no desempate da `Ord (Individual a)`: empate de
  fitness → menor árvore vence.

### 9.7 Controle de bloat (três camadas)

1. **Limites duros**: `_maxTreeDepth = 15` (global), `_maxMutationTreeDepth`
   (mutação), `_maxInitialDepth` (inicial), e o orçamento relativo
   `_maxTreeDepth - getCurrentDepth` na mutação.
2. **Desempate por tamanho** na ordenação da população.
3. **Pós-processamento**: `Grammar.Simplify` (regras que preservam semântica,
   dobra constantes, normaliza comutativos) e `Prune` (deleção gulosa que
   nunca perde acurácia).

### 9.8 Restrição de gramática por problema

- `_relevantTypes` limita os tipos "interessantes" → o sampler só oferece
  operadores/folhas que produzem tipos daí; a tabela fica menor e a busca
  foca.
- `_allowedConstants` define os ERCs permitidos por tipo (incluindo
  aleatórios), evitando constantes absurdas.

### 9.9 Reprodutibilidade e retomada

- RNG puro em `State StdGen`; seed explícita na CLI.
- Checkpoint binário a cada 1000 avaliações guardando população **+ estado do
  RNG**; mesmo `(problema, seed)` reproduz a corrida inteira, inclusive
  retomada.

### 9.10 Orçamento

- `_nEvaluations = popSize * nGens = 300.000` é o combustível. Cada passo
  custa tipicamente 2 (o par de filhos). A contagem inclui a população
  inicial.

---

## 10. Truques e idiomas de Haskell usados no código

### 10.1 Extensões de linguagem, onde e por quê

| Extensão | Onde | Por quê |
|---|---|---|
| `GADTs` | `Evolution.Config`, `Evolution.Individual`, `Benchmark.Problems` | empacotar constraints (`Ord a`, `Fitness a`) junto do valor / tipo existencial |
| `PatternSynonyms` + `{-# COMPLETE #-}` | `Grammar.Core` | `LeafLit`/`LeafArg` bidirecionais sem boilerplate, com exhaustividade preservada |
| `StandaloneDeriving` | `Evolution.Individual`, `Evolution.Checkpoint` | derivar `Show`/`Read`/`Flat` "sob demanda" com a constraint certa |
| `DeriveGeneric` / `DeriveAnyClass` | `Grammar.Core`, `Evolution.Checkpoint` | `Generic` para derivação de `Flat` |
| `OverloadedStrings` | `Benchmark.Parse`, `Prune` | `Key` do aeson ≥ 2.0 a partir de literais |
| `TupleSections` | `Evolution.SamplerTable`, `app/Main` | `(DoesNotUseInput,)`, `(nameString,)` |
| `ViewPatterns` | `Prune` | `checkPromotableArgs (opType -> fType)` |
| `InstanceSigs` | `Evolution.SamplerTable` | assinaturas nos `instance` (legibilidade/verificação) |
| `FlexibleInstances` | `Evolution.Pretty` | `instance Pretty [Individual a]` |
| `RankNTypes` | `Evolution.Run` | `LoggingFunction s a` (polimorfismo de ordem superior no alias) |
| `ScopedTypeVariables` | `Download`, `Run*`, `Prune` | anotações de tipo em lambdas de handler de exceção |
| `OverloadedLists` | `Grammar.Types` | (efetivamente inócuo aqui; resquício) |
| `NumericUnderscores` | `Benchmark.Problems.SmallOrLarge` | literais `1_000_000` legíveis |

### 10.2 Monads e módonos

- **`State StdGen` puro como núcleo estocástico** (`type St a`) —
  reprodutibilidade total sem `IO`.
- **`StateT StdGen IO` no laço** — log/arquivos em `IO`, aleatoriedade em
  estado; `hoistState = S.state . S.runState` move cálculos puros entre os
  dois **mantendo o gerador**; `S.liftIO` para o IO.
- **`Control.Monad.State.Strict`** (estado estrito — evita vazamento de
  thunks numa corrida longa).
- **List monad como escolha não-determinística** em `instantiateArgs`
  (`getPossibilities` ramifica com `do`/`return` e filtra com `guard`), e nas
  comprehensions que materializam a tabela do sampler.
- **`Maybe` como falha** em `typeCheck`/`unifyTypes`/`evalTree`; monadificação
  estrutural via `<$>`/`<*>`/`zipWithM`.
- **`sequence`/`mapM` sobre `Maybe`** no avaliador = avaliação call-by-value
  com curto-circuito.
- **`guard`** no avaliador (monad `Maybe`) para rejeitar NaN.

### 10.3 Tipos de classe e instâncias

- **`Pretty`** (classe do projeto) com instance `OVERLAPPABLE` para listas.
- **`Fitness`** com superclasses `Ord, Show, Read` e instâncias derivadas de
  `Result`/`Sum` — o laço genérico opera sem saber o tipo concreto.
- **`Semigroup`/`Monoid` customizados**:
  - `UsesInput` — semigrupo de dois pontos (flag "pode usar input");
  - `Result` — monoid que **propaga `Error`** (crash envenena);
  - `Zip` — semigrupo que zippa listas (cálculo de larguras de coluna).
- **`Ord` derivado de `Result`** explorando a ordem dos construtores
  (`Error` por último = pior).
- **`Ord (Individual a)` manual** implementando a pressão de parsimônia.
- **`Data.SortedList`** (tipo abstrato) para manter a invariante de população
  ordenada — quem chama não consegue desordenar.

### 10.4 Construtos funcionais

- **`foldl'`** (estricto) em `Concat`, `cumSum`, travessias do crossover —
  evita cadeia de thunks.
- **`foldr`** em `listConsNode` para manter ordem.
- **`foldMap`** para agregar `UsesInput`/`Max`.
- **`Data.Array.array` lazy e auto-referente** = memoização de DP
  (Levenshtein).
- **Functor da tupla**: `(ls ++) <$> go p tr` em `Evolution.Crossover`;
  `bimap mconcat (Right <$>)` em `SamplerTable` (dobrar um lado, mapear o
  outro numa tupla).
- **`Data.Align.alignWith` + `These`** em `EvenSquares` para comparar listas
  de tamanhos diferentes tratando `This`/`That`/`These`.
- **`on` + `minimumBy`** para ranking (`compare `on` (...)`).
- **`Enum`/`Bounded`** para enumerar todos os `Operation`s.
- **Listas infinitas + `zipWith`** (`[obj ^. ... | i <- [1..]]`) — a
  lazy evaluation corta no comprimento certo.
- **Record update** (`{_crossoverRate = ...}`) para sobrescrever um campo de
  config construída.
- **Record wildcards/selection** de campos com `_` — os records usam
  underscore como "lens barata" (`_programType cfg`, `_indTree i`).
- **Campos estritos `!`** em todos os tipos centrais (`Tree`, `Lit`,
  `Measure`, `Config`) para desempenho.
- **`Maybe Measure` dentro do nó** = memoização com invalidação explícita.

### 10.5 Truques menores que valem a nota

- `((' ' :) . unwords ...)` — seção inicial para prefixar com espaço.
- `lowerFirst (show x)` — deriva nome de função do construtor.
- `replace from to` com `stripPrefix` — substituição em listas com guarda
  contra `from` vazio (loop infinito).
- `let Just x = ...` / pattern matching irrefletido em parsers — **falha
  rápida e barulhenta** deliberada (dataset malformado = bug, não caso de uso).
- `error` como "bug interno" no avaliador: um `error` ali significa que o
  type-checker deixou passar algo — falhar alto é melhor que degradar
  silenciosamente.
- `printf` de `Text.Printf` para a linha de progresso; `hFlush stdout` para
  não perder saída em buffer quando o processo cai.
- JSON **construído à mão** no `Benchmark.Log` (`.:`) em vez de aeson, para
  formatar os campos na ordem desejada com control total — enquanto
  `Prune`/`Dataset` **leem** com aeson. Mistura deliberada.
- `Text.Printf`/`Data.Time` para timestamps; `iso8601Show` no RunSearch
  (nomes de arquivo ordenáveis) vs `show time` no Run (nomes com espaço —
  cuidado no shell).

---

## 11. Armadilhas, código morto e particularidades

Coisas que é importante saber **ao ler ou modificar** o código:

1. **O logging por iteração está desligado.**
   Em `Evolution.Run.runAndLog`, as chamadas ao `loggingFunction` estão
   comentadas (linhas ~98-100 e ~115, e o `go (Just statsCache)` virou
   `go Nothing ...`). Consequência: o `.log.csv` sai **apenas com o
   cabeçalho**. O mecanismo (`logPop` + `memoLast`) está completo e correto —
   basta religar as chamadas. O README já documenta isso.

2. **`typeCheck` não roda na busca.** `Grammar.Types.typeCheck` é usado nos
   testes (QuickCheck) como especificação. Na produção, a garantia de tipo
   vem da `SamplerTable` (construção) + `inferOutputType` (operadores).
   Se você alterar um operador, é o sampler e o `inferOutputType` que precisam
   continuar corretos — mas vale rodar os testes, que são justamente o
   contrato do `typeCheck`.

3. **A contagem de avaliações é conservadora.** Em `steadyStateReplace`,
   `evaluations = length children` conta os filhos **antes** da deduplicação —
   inclui pais passados adiante e duplicatas, que nunca são de fato
   pontuados. O orçamento é, portanto, um pouco superestimado (na prática,
   quase sempre 2 por passo).

4. **O checkpoint depende de o contador bater `mod 1000 == 0` exato.**
   Os passos avançam de 0 ou 2 (par de filhos), e a população inicial tem
   1000 (par) — logo os múltiplos de 1000 são sempre atingidos. Se você
   mudar `_individualsPerStep` para ímpar ou a população para ímpar, passos
   ímpares podem **pular por cima** do múltiplo de 1000 e o checkpoint não é
   salvo naquele tick.

5. **Código morto / sem uso:**
   - `Benchmark.Helpers.fisherYatesStep` — não tem chamadores (o shuffle real
     é `sort -R` no shell, durante o download);
   - `Evolution.Run.replaceWorst` — estratégia alternativa, documentada como
     "não ligada ao laço";
   - `Evolution.Helpers.randoms`, `Grammar.Core.compOp`,
     `Grammar.Helpers.listLitOf` — utilitários de conveniência sem uso no
     `src`;
   - `Benchmark.Problems.CollatzNumbers` — problema completo, mas comentado
     em `allProblems`;
   - comentários de chamadas de logging em `Evolution.Run` (ver item 1).

6. **Funções parciais intencionais.** `error`/`fromJust`/pattern irrefletido
   aparecem em parsers, `sample []`, `eval` catch-all, `inferOutputType`
   (`head $ filter ...`), `getBranchAt` (`getChildren _ _ = error`). Em todos
   os casos o comentário justifica: ou é "impossível após o type-check", ou é
   "dataset corrompido = falhar rápido". Ao refatorar, preserve essas
   invariantes — ou torne-as explícitas no tipo.

7. **`resetMeasure`/`computeMeasure` devem ser lembrados** em qualquer
   transformação nova de árvore. O crossover já chama `computeMeasure` nos
   filhos; `mkIndividual` recalcula antes de pontuar; `Prune` faz
   `resetMeasure` ao ler do JSON. Uma medida velha causa limites de
   profundidade e desempates errados **silenciosamente**.

8. **Os dois arquivos de dataset são embaralhados no download** (`sort -R`),
   então apagar `./datasets/` muda o split e os resultados. Isso não é bug —
   é propriedade do pipeline, documentada no README.

9. **Checkpoints nunca são apagados ao final.** Uma corrida concluída deixa o
   checkpoint no último múltiplo de 1000; rodar de novo imprime `LOADING
   CHECKPOINT` e termina em segundos, gravando um **novo** conjunto de
   arquivos em `output/`. Para recomeçar: `rm ./checkpoint/s<seed>_<problema>.checkpoint`.

10. **`buildTable` é construída duas vezes por config** (`full` + `grow`), e
    cada tabela tem células para 16 profundidades × tipos relevantes, cada uma
    com tabelas aninhadas de lambda. É o custo fixo de inicialização — se
    você aumentar muito `_relevantTypes` ou a profundidade, o startup fica
    visivelmente mais lento.

11. **Escopo de lambda é trocado, não encadeado**: `evalLambda` chama
    `evalTree [l]`, substituindo a lista de argumentos. O corpo de um lambda
    **não** enxerga os argumentos do programa externo.

12. **`Evolution.Pretty` importa `Individual` de `Evolution.Run`** (que o
    re-exporta), não de `Evolution.Individual` — um pequeno acoplamento que
    vale saber ao mover código.

13. **`stack.yaml` precisa dos `extra-deps`** (aeson ≥ 2.0 para
    `Data.Aeson.KeyMap`) porque o snapshot `lts-18.18` traz aeson 1.5. Sem
    eles, `stack build` falha. O `hotgp.cabal` é gerado do `package.yaml`
    por hpack — editar `package.yaml` e rodar `hpack` antes de usar cabal.

---

## 12. Como estender o sistema

### Adicionar um problema de benchmark

1. Criar `src/Benchmark/Problems/MeuProblema.hs` exportando
   `meuProblema :: Benchmark a` (escolher a métrica define `a`, ex.
   `Sum Integer`).
2. Preencher: `_datasetName` (nome no repositório theluth), `_inputTypes`,
   `_outputType`, `_fitnessMetric`, `_trainCases`/`_testCases`,
   `_relevantTypes` (use `allowList`/`allowPairs`/`allowUnaryLambdas`),
   `_allowedConstants` (ERCs como `[St Lit]`), `_customOutputParser` se o
   campo de saída não for `output1`.
3. Registrar em `allProblems` em `src/Benchmark/Problems.hs`.
4. (Opcional) adicionar `_benchmarkId` se o nome não for identificador de CLI
   válido.
5. `cabal build all` — o problema aparece automaticamente na ajuda.

### Adicionar um operador (primitiva) à gramática

1. Construtor em `Operation` (`Grammar.Core`);
2. Assinatura em `opType` (`Grammar.Types`);
3. Caso em `eval` (`Grammar.Eval`);
4. Opcional: nome/símbolo em `Grammar.Pretty`, regras em
   `Grammar.Simplify`;
5. O operador passa a ser oferecido automaticamente aos benchmarks cujos
   `_relevantTypes` unifiquem com o tipo de saída dele
   (`operationsFromTypes` faz o filtro).

### Ajustar os hiperparâmetros

Tudo em `src/Benchmark/BenchmarkToConfig.hs`: `popSize`, `nGens`,
`treeDepth`, `_parentScalar`, `_crossoverRate`,
`_individualsPerStep`. Lembre-se das interações: `treeDepth` mexe no custo de
construção das tabelas do sampler; `_individualsPerStep` ímpar pode afetar o
disparo do checkpoint (item 4 da §11).

---

### Índice rápido "onde está X"

| Quero ver... | Arquivo |
|---|---|
| a AST / os tipos da linguagem | `src/Grammar/Core.hs` |
| as assinaturas dos operadores | `src/Grammar/Types.hs` (`opType`) |
| como um programa roda | `src/Grammar/Eval.hs` (`evalTree`) |
| o type-checker / unificação | `src/Grammar/Types.hs` (`typeCheck`, `unifyTypes`) |
| cache de profundidade/tamanho | `src/Grammar/Helpers.hs` (`computeMeasure`) |
| simplificação algébrica | `src/Grammar/Simplify.hs` |
| como árvores tipadas são geradas | `src/Evolution/SamplerTable.hs` |
| população inicial | `src/Evolution/Generate.hs` (`ramped`) |
| o laço evolutivo | `src/Evolution/Run.hs` (`steadyStateReplace`, `runAndLog`) |
| seleção dos pais | `src/Evolution/Run.hs` (`exponentialRank`, `sampleManyWithProb`) |
| crossover | `src/Evolution/Crossover.hs` |
| mutação | `src/Evolution/Mutation.hs` |
| tipo do indivíduo / parsimônia | `src/Evolution/Individual.hs` |
| classe de fitness | `src/Evolution/Fitness.hs` |
| todos os knobs | `src/Evolution/Config.hs` |
| checkpoint binário | `src/Evolution/Checkpoint.hs` |
| descrição de um problema | `src/Benchmark/Core.hs` |
| registro dos problemas | `src/Benchmark/Problems.hs` |
| download/embaralhamento dos dados | `src/Benchmark/Download.hs` |
| split treino/teste | `src/Benchmark/Dataset.hs` |
| métricas de erro | `src/Benchmark/Metrics.hs` |
| construção do `Config` + hipervariáveis | `src/Benchmark/BenchmarkToConfig.hs` |
| execução ponta a ponta | `src/Benchmark/Run.hs` |
| varredura de crossover rate | `src/Benchmark/RunSearch.hs` |
| logs CSV/JSON e acurácia | `src/Benchmark/Log.hs` |
| poda gulosa | `src/Prune.hs` |
| CLI | `app/Main.hs` |
