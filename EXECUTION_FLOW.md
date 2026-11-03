# Fluxo de execução do HOTGP — do `cabal run` ao programa final

> **O que é este documento.** Um passeio guiado, **na ordem em que as coisas
> acontecem**, pelo caminho que um comando como
>
> ```bash
> cabal run hotgp-exe -- sum-of-squares 42
> ```
>
> percorre dentro do código. Cada seção corresponde a uma fase da execução e
> responde três perguntas: *onde estamos*, *o que acontece* e *o que mudou no
> mundo depois disso*.
>
> Ele é **complementar** a [UNDERSTAND_THE_CODE.md](UNDERSTAND_THE_CODE.md):
> aquele documento é um catálogo módulo a módulo (ótimo para consultar "onde
> está X"); este é a **linha do tempo** — a mesma informação organizada pelo
> eixo do tempo, com analogias, exemplos numéricos tirados dos valores reais do
> projeto e links para aprender cada conceito.

**Como ler.** Numa primeira leitura, siga linearmente (F0 → F7). Numa segunda,
use os quadros **🔎 Leitura fina** — eles escondem os detalhes que explicam
*por que* o código é assim (e que costumam ser a resposta para "por que meu
experimento se comportou estranho?"). Os trechos de código são citações
comentadas do código real, não pseudocódigo.

**Convenções usadas no texto**

| Marca | Significado |
|---|---|
| **F0 … F7** | fases da execução, na ordem do tempo |
| 🧠 **Analogia** | tradução do mecanismo para o mundo real |
| 🔎 **Leitura fina** | detalhe de implementação que muda o comportamento observável |
| ⚠️ **Armadilha** | algo que confunde ao rodar/alterar o projeto |
| 📌 **Estado do mundo** | o que existe (em memória e em disco) ao fim da fase |

---

## Sumário

- [0. Modelo mental e mapa da execução](#0-modelo-mental-e-mapa-da-execução)
- [1. Fase 0 — o processo acorda](#1-fase-0--o-processo-acorda)
- [2. Fase 1 — o nome vira um problema](#2-fase-1--o-nome-vira-um-problema)
- [3. Fase 2 — o maestro monta o mundo](#3-fase-2--o-maestro-monta-o-mundo)
  - [3.4 O dataset: baixar, ler, dividir](#34-o-dataset-baixar-ler-e-dividir)
  - [3.5 `makeConfig`: a ponte problema → motor](#35-makeconfig-a-ponte-problema--motor)
  - [3.6 A tabela de amostragem](#36-a-tabela-de-amostragem--o-coração-do-typed)
- [4. Fase 3 — retomar ou começar do zero](#4-fase-3--retomar-ou-começar-do-zero)
- [5. Pausa — o que é "avaliar um programa"](#5-pausa--o-que-é-avaliar-um-programa)
- [6. Fase 4 — um passo evolutivo, em ordem](#6-fase-4--um-passo-evolutivo-em-ordem)
- [7. Fase 5 — o laço, a parada e o checkpoint](#7-fase-5--o-laço-a-parada-e-o-checkpoint)
- [8. Fase 6 — os artefatos finais](#8-fase-6--os-artefatos-finais)
- [9. Fase 7 — `prune`, o segundo programa](#9-fase-7--prune-o-segundo-programa)
- [10. O fluxo completo em uma página](#10-o-fluxo-completo-em-uma-página)
- [11. Perguntas frequentes de execução](#11-perguntas-frequentes-de-execução)
- [12. Referências para aprender cada conceito](#12-referências-para-aprender-cada-conceito)
- [Apêndice — cola de funções](#apêndice--cola-de-funções)

---

## 0. Modelo mental e mapa da execução

### 0.1 A fábrica de programas

🧠 **Analogia central.** Imagine uma fábrica que **projeta protótipos de
programas** em vez de peças. Ela tem:

1. **um kit de peças** (a gramática: `+`, `if`, `map`, `length`, ...), em que
   cada peça tem um **encaixe** (o tipo) — uma peça de `Int` só entra em buraco
   de `Int`;
2. **um catálogo de montagens pré-aprovadas** (a `SamplerTable`), que diz "para
   produzir um `Int` com 5 níveis de orçamento, estas peças são legais";
3. **uma bancada de testes** (o avaliador + a métrica), que roda cada protótipo
   contra casos de teste e devolve uma **nota de erro**;
4. **um placar sempre ordenado** (a população), do melhor para o pior;
5. **uma esteira de reprodução**: pegar dois bons protótipos, trocar pedaços
   compatíveis, trocar uma peça por outra, testar os filhos e manter os
   melhores — **sem nunca descartar o campeão**;
6. **um diário de bordo** (checkpoint + arquivos de saída).

A fábrica não "pensa" no problema. Ela **sorteia, mede, compara e descarta** —
milhares de vezes. O que faz isso funcionar é que o sorteio é **enviesado para
o que já deu certo** e **cegado por tipos**: nada que não compile chega à
bancada.

O objetivo final é achar um programa cuja **soma dos erros nos casos de treino
seja zero** (ou, para floats, menor que `1e-3`). "Menor é melhor" é a regra de
ouro do projeto inteiro.

### 0.2 Os dois relógios

Durante toda a execução, acompanhe dois contadores independentes:

| Relógio | O que conta | Onde vive |
|---|---|---|
| **Orçamento** | avaliações de indivíduos já gastas (começa em 1000, +2 por passo, teto 300.000) | argumento `nEvals` do laço |
| **Aleatoriedade** | posição no fluxo do gerador `StdGen` | estado da monada `State StdGen` |

O primeiro responde "quanto ainda posso gastar?". O segundo responde "qual é o
próximo número aleatório?" — e, como ele é **puro e serializável**, o par
`(problema, seed)` reproduz a corrida inteira, inclusive depois de
interrompida.

🧠 **Analogia do baralho.** A seed é a ordem inicial de um baralho. Cada
sorteio "compra" a próxima carta. Não há dados sendo jogados em `IO`: há um
**script determinístico** de números, e o checkpoint anota **em que carta do
script** a corrida parou. Retomar = continuar lendo o script do mesmo ponto.

### 0.3 O mapa de uma execução

```
$ cabal run hotgp-exe -- sum-of-squares 42
        │
        ▼
┌─ F0 ────────────────────────────────────────────────────────────────┐
│ app/Main.hs        getArgs → parseArgs → cria ./checkpoint → despacha │
└───────────────────────────────┬─────────────────────────────────────┘
                                ▼
┌─ F1 ────────────────────────────────────────────────────────────────┐
│ Benchmark.Problems  getProblem → MkProblem (tipo existencial)        │
└───────────────────────────────┬─────────────────────────────────────┘
                                ▼
┌─ F2 ────────────────────────────────────────────────────────────────┐
│ Benchmark.Run       abre logs → baixa/lê/divide dataset → makeConfig  │
│   Download · Parse · Dataset · BenchmarkToConfig · SamplerTable       │
└───────────────────────────────┬─────────────────────────────────────┘
                                ▼
┌─ F3 ────────────────────────────────────────────────────────────────┐
│ Evolution.Run       checkpoint existe?  ──sim──► loadCheckpoint      │
│                                         └─não──► ramped + mkIndividual│
└───────────────────────────────┬─────────────────────────────────────┘
                                ▼
┌─ F4 ────────────────────────────────────────────────────────────────┐
│ Evolution.Run       steadyStateReplace   ◄── repete ~149.500 vezes    │
│   rank → roleta → crossover → mutação → dedup → keepBest              │
└───────────────────────────────┬─────────────────────────────────────┘
                                ▼
┌─ F5 ────────────────────────────────────────────────────────────────┐
│ parada: solução perfeita OU orçamento esgotado; checkpoint a cada 1000│
└───────────────────────────────┬─────────────────────────────────────┘
                                ▼
┌─ F6 ────────────────────────────────────────────────────────────────┐
│ Benchmark.Log       .result.csv (casos) + .result.json (resumo)       │
└──────────────────────────────────────────────────────────────────────┘
        ┆
        └─ (depois, opcional, outro processo) F7: prune → output-prune/
```

---

## 1. Fase 0 — o processo acorda

**Onde estamos:** [app/Main.hs](app/Main.hs). Nada foi lido do disco ainda além
dos argumentos.

```haskell
main :: IO ()
main = do
  args <- getArgs
  let parsed = parseArgs args
  createDirectoryIfMissing True "./checkpoint"
  case parsed of
    Nothing -> do
      case args of
        ["prune"] -> prune
        _         -> showHelp
    Just (name, seed) -> runProblem workDir seed name
```

### 1.1 `parseArgs` — validação em runtime

```haskell
parseArgs [nameString, seedString] =
  if nameString `elem` allProblemIds
    then (nameString,) <$> readMaybe seedString
    else Nothing
parseArgs _ = Nothing
```

Três coisas acontecem aqui, nesta ordem:

1. **Exatamente dois argumentos?** `parseArgs` só casa com a lista de dois
   elementos. `["prune"]` cai no `_` e vira `Nothing` — por isso o `prune` é
   reconhecido *depois*, no `case args`.
2. **O nome existe?** A comparação é contra `allProblemIds`, que vem do
   registro de problemas (F1). Consequência prática: **a ajuda e a validação
   nunca ficam desatualizadas** — adicionar um problema ao registro o torna
   automaticamente um comando válido.
3. **A seed é um inteiro?** `readMaybe seedString` devolve `Nothing` para
   `"42abc"`, e o programa mostra a ajuda em vez de explodir.

O `(nameString,)` é **`TupleSections`**: fixa o primeiro componente da tupla e
deixa o segundo vir do `<$>`. Sem a extensão, seria
`fmap (\s -> (nameString, s)) (readMaybe seedString)`.

### 1.2 O diretório de checkpoint é criado **antes** de qualquer coisa

`createDirectoryIfMissing True "./checkpoint"` roda mesmo quando o comando é
inválido. É uma escolha defensiva: qualquer caminho que chegue perto do motor
já encontra `./checkpoint/` pronto. `./output/` e `./datasets/` são criados
depois, sob demanda, por quem os usa.

### 1.3 O despacho

- `["prune"]` → `Prune.prune` (F7), um **programa separado** que lê artefatos
  da execução anterior.
- `Just (nome, seed)` → `runProblem "./" seed nome` (F1).
- qualquer outra coisa → `showHelp`, que imprime `"Invalid args!"`, o uso e a
  lista **ordenada** de benchmarks (`sort allProblemIds`). A ordem do registro
  não importa para a UX.

⚠️ **Armadilha:** `workDir = "./"`. Todos os caminhos (`datasets/`, `output/`,
`checkpoint/`) são relativos ao **diretório corrente**. Rodar o executável de
outro diretório cria os arquivos lá — e dois diretórios diferentes terão
datasets e checkpoints diferentes.

📌 **Estado do mundo:** processo vivo, `./checkpoint/` existe, nenhum dataset
carregado, nenhum gerador aleatório criado. A seed é apenas um `Int` na pilha.

---

## 2. Fase 1 — o nome vira um problema

**Onde estamos:** [src/Benchmark/Problems.hs](src/Benchmark/Problems.hs).

### 2.1 O catálogo

```haskell
data Problem where
  MkProblem :: (Fitness a, Monoid a, Show a) => Benchmark a -> Problem

allProblems :: [Problem]
allProblems = [ MkProblem compareStringLengths, MkProblem countOdds, ... ]

getProblem :: String -> Maybe Problem
getProblem name = find byId allProblems
  where byId = (name ==) . problemId
```

Cada problema é um `Benchmark a` com um tipo de fitness **diferente**:
`Sum Integer` (median), `Sum Float` (wallis-pi), `Result (Sum Float)`
(even-squares), etc. Uma lista homogênea `[Problem]` não poderia guardar tipos
diferentes — daí o **tipo existencial**:

- `MkProblem` **esconde** o `a` do lado de fora;
- mas **carrega junto** as constraints `Fitness a`, `Monoid a`, `Show a` que o
  runner precisa.

🧠 **Analogia.** É uma **ficha de inscrição lacrada**: por fora, todas as fichas
são iguais e podem ficar na mesma pilha; por dentro, cada uma traz o "manual de
instruções" do seu tipo (como ler a nota, como somar notas, como imprimir). Ao
abrir a ficha com pattern matching em `MkProblem`, o manual entra em escopo.

```haskell
runProblem :: FilePath -> Int -> String -> IO ()
runProblem workDir seed problemName = case getProblem problemName of
  Nothing              -> error "Unknown benchmark name"
  Just (MkProblem bench) -> runBenchmark workDir seed bench
```

Duas consequências importantes:

1. **`error` no `Nothing`:** o CLI já validou contra `allProblemIds`; chegar
   aqui com nome inválido significa que alguém chamou `runProblem` por fora.
   Falhar alto é o estilo do projeto.
2. **A constraint volta "de graça":** no ramo `Just (MkProblem bench)`, o GHC
   sabe que existe um `a` com `Fitness`, `Monoid` e `Show`, e aceita passar
   `bench` para `runBenchmark`.

🔎 **Leitura fina — por que GADT e não `data Problem = forall a. ...`?**
As duas formas funcionariam; o GADT é o jeito moderno de escrever o mesmo
existencial com as constraints anexadas ao construtor. O mesmo truque aparece
em `Evolution.Config` (para carregar `Ord a` junto da `_fitnessFunction`) e em
`Evolution.Individual` (para carregar `Fitness a` junto da árvore e da nota).

📌 **Estado do mundo:** um `Benchmark a` concreto escolhido, com suas
constraints disponíveis. Nada foi baixado nem avaliado.

---

## 3. Fase 2 — o maestro monta o mundo

**Onde estamos:** [src/Benchmark/Run.hs](src/Benchmark/Run.hs), função
`runBenchmark`. Esta é a fase mais longa **fora** do laço evolutivo: é aqui que
o problema se transforma em dados, dados se transformam em configuração, e a
configuração se transforma em um `StateT StdGen IO` pronto para rodar.

```haskell
runBenchmark workDir seed benchmark = do
  hSetBuffering stdout $ BlockBuffering Nothing          -- (1)
  identifier <- logFileIdentifier benchmark seed          -- (2)
  (logFileHandle, finalResultFile, jsonFile) <- prepareLogFiles identifier workDir benchmark  -- (3)
  (trainSet, testSet) <- loadTrainAndTestSet workDir benchmark                               -- (4)
  let cfg = makeConfig trainSet benchmark                                                                  -- (5)
      checkpoint = checkpointFilename workDir seed benchmark
      logToFile cache time evals pop = do ...             -- callback de log (hoje não usado)
  (finalPop, nEvals) <- evalStateT (runAndLog cfg logToFile checkpoint) $ mkStdGen seed       -- (6)
  hClose logFileHandle
  writeFile finalResultFile $ logBest testSet (_indTree $ head $ SL.fromSortedList finalPop)   -- (7)
  writeFile jsonFile $ jsonBest (getBenchmarkId benchmark) seed nEvals testSet (head $ ...)    -- (8)
```

Vamos por partes, na ordem.

### 3.1 `hSetBuffering stdout (BlockBuffering Nothing)`

O laço imprime **uma linha por passo** (~149.500 linhas numa corrida completa).
Sem buffer de bloco, cada `printf` viraria uma escrita no terminal — o
overhead seria comparável ao da própria busca. Com `BlockBuffering`, a saída
sai em blocos; os pontos em que o código chama `hFlush stdout` são justamente
os "marcos" que o usuário precisa ver na hora (`STARTING FROM SCRATCH`,
`LOADING CHECKPOINT`, `Perfect solution found!`).

⚠️ **Armadilha:** se o processo for morto com `Ctrl-C`, o buffer pode se perder.
Para acompanhar ao vivo, rode com `stdbuf -oL` ou redirecione para arquivo e
use `tail -f`.

### 3.2 O identificador dos arquivos

```haskell
logFileIdentifier benchmark seed = do
  time <- getCurrentTime
  return $ show time <> "_s" <> show seed <> "_" <> getBenchmarkId benchmark
```

Resultado típico: `2026-10-01 20:54:37.766867737 UTC_s42_sum-of-squares`.
Note que `show UTCTime` produz **espaços e dois-pontos** — é por isso que o
README manda usar aspas ao manipular esses nomes no shell. A variante
`RunSearch` usa `iso8601Show`, que gera nomes ordenáveis e sem espaços.

### 3.3 `prepareLogFiles` — abrir antes de baixar

[src/Benchmark/Log.hs](src/Benchmark/Log.hs) faz:

1. `createDirectoryIfMissing True "./output/"` e `"./checkpoint/"`;
2. abre `<prefixo>.log.csv` em `WriteMode` (**trunca** se já existir);
3. escreve o cabeçalho:
   `time;n_evals;best_fitness;best_depth;best_node_count;best_acc;best_nmse;best_string_rep_simple;best_string_rep`;
4. devolve o `Handle` aberto e os caminhos de `.result.csv` e `.result.json`.

O `Handle` fica aberto durante **toda** a corrida. O callback `logToFile`
fechado sobre ele acrescentaria uma linha por tick (e daria `hFlush` a cada 100
linhas, para uma queda perder pouco). Hoje ele é construído, passado ao laço —
e **nunca chamado** (ver §7.4).

⚠️ **Ordem importa:** o arquivo é criado **antes** do download do dataset. Se o
download falhar, sobra um `.log.csv` só com cabeçalho, o que pode confundir.

### 3.4 O dataset: baixar, ler e dividir

`loadTrainAndTestSet` ([src/Benchmark/Dataset.hs](src/Benchmark/Dataset.hs)) é
o primeiro ponto em que o programa toca o mundo externo.

#### 3.4.1 Download — `curl | gzip | sort -R`

```haskell
downloadBenchmark workDir name = do
  createDirectoryIfMissing True (workDir <> "datasets/")
  dlAndUnzip workDir name "random"
  dlAndUnzip workDir name "edge"

dlAndUnzip ... = unless fileExists $ do
  callCommand $ "curl -LJ -o " <> fileName <> ".gz " <> url
  let unzipAndShuffle = "gzip --to-stdout -d " <> fileName <> ".gz | sort -R > " <> fileName
  handle (\(e :: SomeException) -> return ()) $ do
    callCommand unzipAndShuffle
    removeFile (fileName <> ".gz")
```

Três propriedades de projeto:

1. **Idempotência:** se `datasets/<nome>-<sufixo>.json` já existe, nada é
   baixado. O custo de rede é pago **uma vez por máquina**.
2. **O split nasce no download.** O `sort -R` **embaralha** o arquivo random
   *enquanto descompacta*. Como o split de treino/teste é um simples "pega os
   primeiros N", a ordem embaralhada é o que garante que treino e teste sejam
   amostras aleatórias — e não, por exemplo, os primeiros casos gerados.
3. **POSIX de propósito:** `curl`, `gzip`, `sort`, `/bin/sh` são dependências
   externas listadas no README. Não há HTTP client Haskell aqui.

⚠️ **Armadilha (a mais importante do projeto):** apagar `./datasets/*.json` e
baixar de novo produz **outro embaralhamento**, logo **outro split**, logo
**outros resultados** para a mesma seed. Isso não é bug: é uma propriedade
documentada do pipeline. Duas corridas "iguais" só são comparáveis com os
mesmos arquivos de dataset.

O `handle (\(e :: SomeException) -> return ())` engole falhas do descompactar
(ex.: o `curl` baixou uma página HTML de erro). A ideia é não abortar com uma
exceção opaca: o parser vai falhar depois, com uma mensagem mais clara sobre o
arquivo corrompido. `ScopedTypeVariables` é o que permite anotar `e`.

#### 3.4.2 Leitura — JSON-lines → `Lit` tipado

Cada linha é um objeto JSON com `input1..inputN` e `output1`. O parser é
**dirigido pelos tipos declarados no benchmark**:

```haskell
transform obj = (zipWith parseJsonLit (_inputTypes benchmark) xs, parseOutput obj)
  where xs = [obj ^. ("input" <> show i) | i <- [1 ..]]
```

🔎 **Leitura fina — a lista infinita.** `xs` é infinita, mas `zipWith` para no
comprimento de `_inputTypes`. A avaliação preguiçosa garante que só os campos
realmente usados são procurados. É um jeito elegante de dizer "leia tantos
`inputK` quantos o problema declara", sem saber o número em tempo de compilação
da função.

`parseJsonLit` despacha pelo tipo:

| Tipo declarado | JSON esperado | `Lit` produzido |
|---|---|---|
| `GInt` | número | `IntLit (round ...)` |
| `GFloat` | número | `FloatLit ...` |
| `GBool` | booleano | `BoolLit ...` |
| `GChar` | string de 1 caractere | `CharLit (head ...)` |
| `GList GChar` | string | `ListLit GChar [...]` (string vira lista de chars) |
| `GList t` | array | `ListLit t [...]` |

Se o problema guarda a resposta em outro campo (ou em dois campos, como
`replace-space-with-newline`), ele fornece `_customOutputParser :: Maybe
OutputParser`. O default lê `output1`.

⚠️ **Armadilha:** o acesso `json ^. "input1"` é **parcial de propósito**
(`let Just val = ...`). Dataset malformado = erro imediato. O estilo se repete
no `parseJsonLine` e no `prune`: falhar rápido e barulhento é preferível a
treinar em lixo silenciosamente.

#### 3.4.3 O split — edge primeiro, treino, teste

```haskell
random <- readJson workDir benchmark "-random.json"
edge   <- readJson workDir benchmark "-edge.json"
let (trainSet, remaining) = splitAt (_trainCases benchmark) $ edge <> random
    testSet = take (_testCases benchmark) remaining
return (trainSet, testSet)
```

A política, em palavras:

1. **Casos de borda primeiro.** `edge <> random` coloca os casos-limite na
   frente; como o treino é um prefixo e os edge cases são poucos, **todos eles
   entram no treino**. Eles são as condições interessantes (listas vazias,
   zeros, negativos) e não podem ficar de fora por azar do shuffle.
2. **Primeiros `_trainCases`** → treino. É o que a fitness enxerga.
3. **Próximos `_testCases`** → teste. **Só relatório.** Um programa não
   consegue "vencer no log" por overfitting: a nota que dirige a busca e a nota
   que aparece no resultado final vêm de conjuntos diferentes.

Para `sum-of-squares`, `_trainCases = _testCases = 50`. Para `median`,
100 de treino e 1000 de teste. A tabela completa está no README.

🧠 **Analogia.** O treino é o **simulado**; o teste é a **prova oficial**. A
fábrica só vê o simulado — mas o boletim final é calculado na prova oficial.

📌 **Estado do mundo:** `trainSet` e `testSet` em memória, cada um uma lista de
pares `([Lit], Lit)`; arquivos em `./datasets/`; `.log.csv` aberto com
cabeçalho.

### 3.5 `makeConfig`: a ponte problema → motor

[src/Benchmark/BenchmarkToConfig.hs](src/Benchmark/BenchmarkToConfig.hs)
transforma um `Benchmark a` + treino em um `Config (Result a)`. Tudo o que o
motor precisa saber sobre o problema é decidido **aqui**, uma vez.

```haskell
makeConfig trainSet bench =
  MkConfig
    { _programType           = MkFunctionType (_inputTypes bench) (_outputType bench),
      _maxTreeDepth          = treeDepth,      -- 15
      _maxMutationTreeDepth  = treeDepth,      -- 15
      _maxInitialDepth       = treeDepth,      -- 15
      _popSize               = popSize,        -- 1000
      _individualsPerStep    = 2,              -- 1 par por passo
      _nEvaluations          = nGens * popSize,-- 300 * 1000 = 300000
      _fitnessFunction       = fitness,
      _parentScalar          = 0.9993,
      _crossoverRate         = 0.5,
      _fullTable             = buildTable termsAndOps treeDepth True,
      _growTable             = buildTable termsAndOps treeDepth False
    }
```

#### 3.5.1 O tipo do programa

`_programType = inputTypes ->> outputType` é a assinatura que **todo** candidato
deve ter. É dela que saem os `Arg n` disponíveis e o tipo que a raiz deve
produzir. Para `sum-of-squares`: `[GInt] -> GInt`.

#### 3.5.2 `TermsAndOps` — o kit de peças do problema

```haskell
termsAndOps = MkTermsAndOps
  { _literals   = _allowedConstants bench,                              -- ERCs por tipo
    _arguments  = typesToArgMap (_inputTypes bench),                    -- tipo -> índices
    _operations = operationsFromTypes (S.toList $ _relevantTypes bench) -- tipo -> operações
  }
```

- **`_arguments`**: `[GInt, GInt, GInt]` vira `{GInt -> [0,1,2]}`. É assim que
  o gerador sabe que pode usar `Arg 1` onde se pede `GInt`.
- **`_allowedConstants`**: map de tipo para **ações** `St Lit`, não valores.
  🔎 **Por que ações?** Porque algumas constantes são **ERCs** (*ephemeral
  random constants*): "um inteiro qualquer entre -100 e 100". O sorteio só pode
  acontecer **no momento em que o nó é amostrado** — se fosse um valor fixo na
  config, todo mundo usaria o mesmo número. Em `sum-of-squares`, as constantes
  permitidas são `randomR (-100,100)`, `0` e `1`.
- **`_operations`**: `operationsFromTypes` percorre **todos** os construtores de
  `Operation` (via `Enum` + `Bounded`) e agrupa os que podem produzir cada tipo
  relevante. `map` aparece sob todo tipo de lista cujo resultado unifique.

```haskell
ops = [(minBound :: Operation) .. maxBound]
findOps t = filter (\op -> isJust $ unifyTypes t (opOutput op)) ops
```

- **`_relevantTypes`**: a fatia da gramática que o problema permite. `median`
  usa `{GInt, GBool}` — não há lista, par nem lambda. Isso **encolhe a tabela**
  e **foca a busca**. `count-odds` adiciona listas e lambdas unárias
  (`allowUnaryLambdas`) porque a solução natural é `filter odd xs`.
  Esses combinadores são só `<$>` sobre o construtor de tipo:
  `allowList ts = ts <> (GList <$> ts)`, etc.

#### 3.5.3 A função de fitness — ler de dentro para fora

```haskell
fitness tree = mconcat $
  (\(x, y) -> _fitnessMetric bench y <$> maybeToResult (evalTree x tree)) <$> trainSet
```

Em ordem de avaliação, para **um** caso `(x, y)`:

1. `evalTree x tree` → `Maybe Lit`. `Just v` = rodou; `Nothing` = crash
   (divisão por zero, `head []`, NaN, ...).
2. `maybeToResult` → `Result Lit`: crash vira `Error`.
3. `_fitnessMetric bench y <$>` → `Result a`: aplica a métrica com o esperado
   `y` fixo. `<$>` sobre `Result` preserva `Error`.
4. `mconcat` sobre **todos** os casos → `Result a`.

O `Result` é o "Maybe com a `Ord` certa": `Error` é o **último construtor**, e
a `Ord` derivada compara a tag primeiro — logo `Error` é **maior que qualquer
sucesso**, ou seja, o **pior** valor possível. E o `Semigroup` propaga:

```haskell
Result x <> Result y = Result (x <> y)
_        <> _        = Error          -- qualquer crash envenena a soma
```

🧠 **Analogia.** É uma prova com **nota final somada**: se o aluno quebrar a
caneta em uma questão, a prova inteira é anulada — ele não pode compensar
acertando as outras.

A métrica concreta vem de [Benchmark/Metrics.hs](src/Benchmark/Metrics.hs) e
sempre tem a forma `Lit -> Lit -> Sum x` (esperado, obtido → erro):
`rightWrong` (0/1, sem crédito parcial), `intError` (`|x - y|`),
`floatError`, `boolError`, `levenshteinDistance` (distância de edição sobre os
elementos) e `prettyLevenshteinDistance` (sobre a forma impressa).

O tipo de retorno é `Config (Result a)`, exatamente o que o laço genérico
suporta. Os tipos concretos variam por problema:

| Problema | `a` | Fitness final |
|---|---|---|
| `median` | `Sum Integer` (`rightWrong`) | `Result (Sum Integer)` |
| `sum-of-squares` | `Sum Integer` (`intError`) | `Result (Sum Integer)` |
| `wallis-pi` | `Sum Float` (`floatError` + `prettyLevenshteinDistance`) | `Result (Sum Float)` |

#### 3.5.4 Os hiperparâmetros fixos

| Constante | Valor | Efeito |
|---|---|---|
| `popSize` | 1000 | tamanho do placar |
| `nGens` | 300 | só entra como `300 * 1000` no orçamento |
| `treeDepth` | 15 | limite de profundidade (inicial, global, mutação) |
| `_individualsPerStep` | 2 | 2 pais → 1 par por passo |
| `_nEvaluations` | 300000 | "combustível" da corrida |
| `_parentScalar` | 0.9993 | decaimento do peso por rank |
| `_crossoverRate` | 0.5 | prob. de crossover; complemento = mutação |

Esses valores são os do experimento do [artigo do HOTGP](https://doi.org/10.1145/3583131.3590464).
Mudá-los é mexer **apenas** em `src/Benchmark/BenchmarkToConfig.hs` — mas veja
as armadilhas de checkpoint em §11.

### 3.6 A tabela de amostragem — o coração do "typed"

**Onde estamos:** [src/Evolution/SamplerTable.hs](src/Evolution/SamplerTable.hs).
Esta é, de longe, a parte mais engenhosa do projeto — e a que explica por que
**nenhum candidato nasce mal tipado**. A ideia geral é a de *Strongly Typed GP*
(STGP): restringir a gramática para que só existam combinações bem tipadas
([Montana, 1995](https://doi.org/10.1162/evco.1995.3.2.199)).

#### 3.6.1 O problema que ela resolve

Suponha que o gerador esteja em um nó que precisa produzir `GInt` e tenha 5
níveis de profundidade restantes. Ele pode colocar:

- `Arg 0` (se o argumento 0 for `Int`), ou
- `IntLit 7`, ou
- `AddInt` — mas aí precisa de **dois filhos `Int`**, cada um com 4 níveis, e
  assim por diante.

Escolher um operador ao acaso produziria lixo: `head` onde se pede `Int`,
`if` sem `Bool`, aridade errada. A tabela **pré-computa** a resposta para cada
par `(profundidade restante, tipo exigido)`.

🧠 **Analogia do GPS.** Em vez de tentar virar em ruas que não existem, o GPS
já tem um mapa de **todas as esquinas válidas** indexado por "onde estou"
(profundidade) e "para onde quero ir" (tipo). Dirigir vira só escolher uma
saída permitida e seguir.

#### 3.6.2 A estrutura

```haskell
type SamplerTable    = M.Map (Depth, OutputType) SamplerTableRow
type SamplerTableRow = ( UsesInput
                       , [ Either (St Terminal) (St (Operation, FunctionType)) ] )
```

- **Chave:** `(profundidade restante, tipo exigido)`.
- **Valor:** uma flag + uma lista de **alternativas**.
- Cada alternativa é uma **ação**:
  - `Left stTerm`: produzir um terminal (argumento ou literal — o literal é
    sorteado agora, se for ERC);
  - `Right st`: produzir um operador **junto com a instanciação da assinatura**
    que faz ele caber naquela célula (ex.: `map` instanciado como
    `(Int -> Int) -> [Int] -> [Int]`).
- **Por que ações e não valores?** Para adiar os ERCs até o sorteio do nó.

A flag `UsesInput` é um **semigrupo de dois pontos**:

```haskell
DoesNotUseInput <> DoesNotUseInput = DoesNotUseInput
_ <> _                             = UsesInput
```

`foldMap` sobre as alternativas de uma célula responde: *"esta célula
**pode** produzir uma árvore que lê algum argumento?"*. Isso é usado para
rejeitar **lambdas vazios** — um `\x -> 42` que ignora o parâmetro é inútil
para `map`/`filter`.

#### 3.6.3 `buildTree` — a descida

```haskell
buildTree table depth outputType = do
  node <- sample $ snd $ table M.! (depth, outputType)
  case node of
    Left stTerm -> mkLeaf <$> stTerm
    Right st -> do
      (op, fType) <- st
      args <- sequence $ buildTree table (depth - 1) <$> _argTypes fType
      return $ op <| args
```

Depois que a tabela garantiu a legalidade, gerar é **só descer**: escolher uma
alternativa, e para cada tipo de argumento da assinatura instanciada, descer
com `depth - 1`. Como cada filho recebe um nível a menos, a árvore não passa da
profundidade pedida.

🔎 **Leitura fina — amostragem uniforme sobre alternativas.** `sample` é
uniforme sobre a **lista**, não sobre os operadores. Um operador com mais
instanciações válidas aparece mais vezes na lista e é sorteado mais vezes. Isso
é intencional: quanto mais "encaixes" um operador tem, mais útil ele tende a
ser naquele contexto.

#### 3.6.4 Como a tabela é montada

`buildTableForLevel currentLambdaLevel termsAndOps maxDepth forceFullTree`
materializa, para `depth <- [0..maxDepth]` e `outputType <- relevantTypes`:

| Situação | O que a célula oferece |
|---|---|
| `(0, GLambda ft)` | **só** um lambda literal, construído a partir de uma tabela **aninhada** (corpo do lambda) |
| `(0, t)` | **só** terminais — no fundo, toda árvore tem que parar |
| `(d, t)`, `d > 0`, modo **grow** | terminais **ou** operadores |
| `(d, t)`, `d > 0`, modo **full** | **só** operadores — toda ramificação desce até o fundo |

- **Modo full vs. grow:** é a única diferença entre `_fullTable` e `_growTable`.
  No full, a linha de terminais em `d > 0` é `mempty`; no grow, ela é a célula
  `(0, t)` copiada. Nos filhos, o full fixa a profundidade exata; o grow aceita
  qualquer `0..d-1`.
- **`UsesInput` sobe:** a flag de uma linha é o `foldMap` das flags dos filhos
  de cada operador válido. Se nenhum caminho lê argumento, a linha inteira é
  `DoesNotUseInput`.
- **`instantiateArgs`** decide quais instanciações de um operador polimórfico
  cabem. Usa a **list monad como escolha não determinística**, carregando um
  conjunto de vínculos de tipos (`constraints`) da esquerda para a direita.
  Exemplo: pedir `[GInt]` de `map :: (a -> b) -> [a] -> [b]` unifica `b` com
  `GInt`; o primeiro argumento vira `a -> Int`, e `a` é enumerado entre os tipos
  relevantes que unificam.

#### 3.6.5 Lambdas de ordem superior

Um lambda é um **literal cujo corpo é uma árvore tipada**. A tabela trata isso
com tabelas aninhadas: para cada assinatura `GLambda ft`, constrói uma tabela
"um nível de lambda mais fundo", cujos **argumentos são os parâmetros do
lambda** (`typesToArgMap (_argTypes ft)`) — não os argumentos do programa.

```haskell
maxLambdaDepthAtEachLevel = [3, 0]
maxLambdaLevel            = 2
```

- Nível 0 (lambda externo): corpo com até 3 níveis.
- Nível 1 (lambda dentro de lambda): corpo com 0 níveis — na prática, só
  expressões do tipo identidade (`a -> a`), porque o filtro exige
  `head (_argTypes ft) == _outType ft`.
- Aninhamento para em 2 níveis: o número de células cresce rápido e lambdas
  profundos raramente ajudam.

Uma assinatura é **rejeitada** se o corpo não puder ser gerado, se o corpo
**não usaria** o parâmetro, ou se não houver nada a amostrar. Além disso,
`generateLambda` **re-tenta** até o corpo conter um `LeafArg`: a tabela só sabe
se o corpo *poderia* usar o input, não se *esta* amostra usou.

🔎 **Leitura fina — lambda é folha para a árvore externa.** Para
`computeMeasure`, `atPoint`, crossover e mutação, um `LambdaLit` é um **leaf**.
Altura/profundidade **não enxergam** o corpo; crossover/mutação **não escolhem**
pontos dentro dele. Quem olha para dentro é só `evalTree` (quando `map`/`filter`
aplicam o lambda) e `Prune` (que mergulha explicitamente em corpos). O corpo tem
orçamento de profundidade **próprio** (os 3 níveis do nível 0), independente do
orçamento do nó externo onde o lambda foi colocado.

#### 3.6.6 Custo

A tabela é construída de forma **preguiçosa**: `M.fromList` monta o mapa, mas
cada célula é um thunk; a primeira vez que `buildTree` pede `(d, t)`, a célula é
calculada e **fica em cache** (o mapa é compartilhado). Ainda assim, o custo é
real: 16 profundidades × tipos relevantes, cada célula olhando as células filhas,
mais tabelas aninhadas de lambda. É o **maior custo fixo de inicialização** —
visível se você aumentar muito `_relevantTypes`, `treeDepth` ou o número de
níveis de lambda. E note que `_fullTable` e `_growTable` são duas tabelas
completas, construídas separadamente.

📌 **Estado do mundo:** `Benchmark`, `Config` (com duas tabelas), treino, teste,
handle de log aberto. Ainda **nenhum** indivíduo foi gerado ou avaliado.

### 3.7 `evalStateT ... (mkStdGen seed)` — o baralho entra em cena

```haskell
(finalPop, nEvals) <- evalStateT (runAndLog cfg logToFile checkpoint) $ mkStdGen seed
```

`runAndLog` tem tipo `StateT StdGen IO (SortedPop a, Int)`. `evalStateT` roda a
computação com o estado inicial `mkStdGen seed` e devolve um `IO` com o
resultado. A partir daqui:

- **`IO`** existe para imprimir, ler/escrever arquivos e checar existência de
  checkpoint;
- **`State StdGen`** existe para toda a aleatoriedade. Nenhum operador
  genético usa `IO` para sortear.

Essa separação é o que torna a corrida reproduzível. `mkStdGen` é o gerador
SplitMix do `random`; a seed inteira vira o estado inicial.

---

## 4. Fase 3 — retomar ou começar do zero

**Onde estamos:** [src/Evolution/Run.hs](src/Evolution/Run.hs), `runAndLog`.

```haskell
runAndLog cfg loggingFunction checkpointFilename = do
  hasCheckpoint <- doesCheckpointExist checkpointFilename
  if hasCheckpoint then resumeFromCheckpoint else startFromScratch
```

### 4.1 O caminho "retomar"

```haskell
resumeFromCheckpoint = do
  S.liftIO $ putStrLn "LOADING CHECKPOINT"
  (evals, pop) <- loadCheckpoint cfg checkpointFilename
  go Nothing evals pop
```

`loadCheckpoint` ([src/Evolution/Checkpoint.hs](src/Evolution/Checkpoint.hs)):

1. lê o arquivo binário;
2. `unflat` decodifica um `Checkpoint` (`_gen`, `_population`, `_currentEvals`);
3. um arquivo corrompido é **erro duro** (`fromRight (error ...)`) — reiniciar
   em silêncio jogaria horas de cálculo fora;
4. `decodeCheckpoint`:
   - **restaura o RNG**: `S.put (StdGen $ seedSMGen' $ _gen checkpoint)`;
   - **re-pontua a população**: `mkIndividual cfg <$> _population checkpoint`.

🔎 **Leitura fina — por que não guardar a fitness?** O checkpoint guarda **só
árvores**. Ao carregar, cada árvore é re-avaliada com a `_fitnessFunction`
**atual**. Isso mantém o formato do arquivo independente do tipo de fitness e
faz o checkpoint continuar válido se a métrica ou a tolerância mudarem entre
execuções. O preço é re-avaliar 1000 indivíduos no carregamento (rápido perto
de re-fazer a corrida).

🔎 **Leitura fina — o RNG é restaurado exatamente.** `StdGen` do `random` é
implementado sobre SplitMix, cujo estado são dois `Word64`. `makeCheckpoint`
usa `unseedSMGen` para extrair o par; `decodeCheckpoint` usa `seedSMGen'` para
reconstruí-lo. Resultado: a corrida retomada sorteia **a mesma sequência** que
a corrida interrompida sortearia.

### 4.2 O caminho "começar do zero"

```haskell
startFromScratch = do
  S.liftIO $ putStrLn "STARTING FROM SCRATCH"
  p <- hoistState $ initPop cfg
  time <- S.liftIO getCurrentTime
  S.liftIO $ putStrLn $ show time <> " -\t" <> show (length p) <> "/" <> show (_nEvaluations cfg)
  go Nothing (length p) p
```

`initPop`:

```haskell
initPop cfg = SL.toSortedList . map (mkIndividual cfg) <$> ramped cfg
```

Duas etapas: **gerar** as árvores e **pontuar** cada uma.

#### 4.2.1 `ramped` — half-and-half de Koza

A inicialização *ramped half-and-half* é a receita clássica de Koza para não
começar a busca com uma população homogênea; a descrição original está no
[*Field Guide to Genetic Programming*](https://www.gp-field-guide.org.uk/).

```haskell
ramped cfg = go [] (_popSize cfg) 2
  where
    go pop 0 _ = return pop
    go pop nPop minDepth = do
      treesFull <- replicateM half     (full cfg minDepth outputType)
      treesGrow <- replicateM (half + r) (grow cfg minDepth outputType)
      go (treesFull <> treesGrow <> pop) (nPop - n) (minDepth + 1)
      where
        range     = maxDepth - minDepth + 1
        n         = nPop `div` range
        (half, r) = quotRem n 2
```

Leitura com os números do projeto (`popSize = 1000`, `maxInitialDepth = 15`):

- começa em `minDepth = 2` e sobe até 15 (14 faixas);
- na primeira rodada, `range = 14`, `n = 1000 div 14 = 71`, `half = 35`,
  `r = 1` → **35 árvores full + 36 grow** com profundidade 2;
- a rodada seguinte recebe `nPop = 929`, `range = 13`, e assim por diante;
- na última rodada, `range = 1` e `n = nPop`: ela absorve todo o resto, então a
  população fecha **exata** em 1000.

`full` e `grow` só delegam para `buildTree` com a tabela correspondente:

```haskell
full cfg = buildTree (_fullTable cfg)
grow cfg = buildTree (_growTable cfg)
```

A legalidade tipada já está na tabela (F2.6); aqui só se escolhe a **forma**:

- `full`: toda ramificação desce até o fundo → árvores cheias, folhas variadas;
- `grow`: ramificações podem parar cedo → árvores menores e mais variadas.

🧠 **Analogia.** É como montar um time misturando jogadores experientes e
novatos: metade dos candidatos é "cheia" (todas as posições preenchidas até o
fim) e metade é "enxuta" (para onde quiser). Isso evita começar com uma
população toda igual.

#### 4.2.2 `mkIndividual` — medir e só então pontuar

```haskell
mkIndividual config tree =
  MkIndividual computedTree (_fitnessFunction config computedTree)
  where computedTree = computeMeasure tree
```

`computeMeasure` ([src/Grammar/Helpers.hs](src/Grammar/Helpers.hs)) faz **uma
travessia bottom-up** e anota cada nó com:

- `_currentDepth`: distância até a raiz (+1 por nível, passado de cima);
- `_height`: `0` para folha, `1 + maximum (alturas dos filhos)` para nó;
- `_nodeCount`: `1 + sum (nós dos filhos)`.

Exemplo:

```
AddInt                 depth 0, height 2, nodes 5
├── Arg 0              depth 1, height 0, nodes 1
└── MultInt            depth 1, height 1, nodes 3
    ├── Arg 1          depth 2, height 0, nodes 1
    └── IntLit 2       depth 2, height 0, nodes 1
```

Por que memoizar? Porque o laço consulta tamanho **o tempo todo**: limites de
profundidade, desempate por parsimônia, logging, orçamento de mutação. Sem
cache, cada consulta seria uma travessia.

⚠️ **Armadilha:** `getMeasure` calcula sob demanda se o cache falta, mas
**não escreve de volta** (Haskell é imutável). Então `getHeight` numa árvore
"crua" recalcula a cada chamada. A disciplina do projeto é: `computeMeasure`
**uma vez** logo após construir/transformar; leia muitas.

#### 4.2.3 O placar ordenado

`SL.toSortedList` insere os indivíduos em um `Data.SortedList`, que mantém a
invariante de ordenação. A ordenação vem de `Ord (Individual a)`:

```haskell
compare i1 i2 = case compare (_fitness i1) (_fitness i2) of
  EQ -> compare (getNodeCount $ _indTree i1) (getNodeCount $ _indTree i2)
  x  -> x
```

Ou seja: **menor fitness primeiro**; empate → **menos nós primeiro**. O
desempate é a **pressão de parsimônia**: entre dois programas que acertam
igual, o menor vence. Isso é uma das três camadas de controle de bloat do
sistema (as outras: limites duros de profundidade e o pós-processamento).

📌 **Estado do mundo:** população de 1000 indivíduos **já pontuados** e
ordenados; `nEvals = 1000`; RNG na posição inicial (ou restaurada); possibilidade
de checkpoint em disco.

---

## 5. Pausa — o que é "avaliar um programa"

Antes do laço, vale abrir a caixa-preta que roda **uma vez por caso de treino,
por indivíduo**. É o trabalho que domina o tempo de execução.

### 5.1 `evalTree` — o interpretador

[src/Grammar/Eval.hs](src/Grammar/Eval.hs):

```haskell
evalTree :: [Lit] -> Tree -> Maybe Lit
evalTree args (LeafArg i) = ... args !! i ...
evalTree args (LeafLit v) = Just v
evalTree args Node {_operation = f, _args = opArgs} = do
  evaluatedArgs <- sequence $ evalTree args <$> opArgs
  v <- eval f evaluatedArgs
  case v of
    FloatLit x -> do guard (not $ isNaN x); return v
    _          -> return v
```

Três decisões semânticas:

1. **Call-by-value estrito.** Os filhos são avaliados **antes** do operador.
   `sequence` sobre `Maybe` curto-circuita no primeiro `Nothing`. Consequência
   curiosa: **`if` avalia as duas branches** — uma branch não escolhida pode
   derrubar o programa inteiro (por exemplo, `if True then 1 else head []`
   falha). É um efeito colateral do modelo, não um bug acidental.
2. **`Maybe Lit` é o contrato.** `Nothing` = falha de runtime: divisão por zero,
   `head []`, `mod 0`, NaN. A fitness trata isso como `Error`, nunca como valor.
3. **NaN é filtrado.** Qualquer `FloatLit` NaN vira `Nothing`, para nunca
   parecer uma nota boa.

#### Um exemplo concreto

Considere o candidato ao `sum-of-squares` (programa `Int -> Int`):

```
SumInts
└── Map
    ├── λx. MultInt (Arg 0) (Arg 0)
    └── Range (IntLit 1) (Arg 0) (IntLit 1)
```

Com a entrada `n = 5`, `evalTree [IntLit 5]`:

1. `Arg 0` (dentro de `Range`) → `5`.
2. `Range` recebe `[1, 5, 1]` e devolve `[1,2,3,4,5]` (com guards contra
   `step == 0`, passo na direção errada, e `take 5000` para não alocar lista
   infinita).
3. `Map` aplica o lambda a cada elemento. Dentro do lambda, `evalLambda`
   chama `evalTree [elemento] body` — **`Arg 0` do corpo é o parâmetro**, não o
   `n` do programa.
4. Cada elemento vira `x*x`: `[1,4,9,16,25]`.
5. `SumInts` soma: `55`.
6. A métrica `intError 55 55` → `Sum 0`; `Result (Sum 0)` é perfeito.

🧠 **Analogia.** `evalTree` é a **bancada de testes**: coloca o protótipo na
entrada, liga, e vê o que sai. Se solta fumaça (`Nothing`), é cartão vermelho.

🔎 **Leitura fina — escopo de lambda é trocado, não encadeado.** `evalLambda f
l = evalTree [l] (_tree f)` **substitui** a lista de argumentos. O corpo do
lambda **não enxerga** os argumentos do programa externo. Isso simplifica o
avaliador e é consistente com a geração (a tabela do corpo só oferece os
parâmetros do lambda).

⚠️ **Armadilha:** `eval` termina com `eval f vs = error ...`. Esse `error` só é
alcançável com uma árvore mal tipada — ou seja, indica bug em outro lugar. O
projeto prefere falhar alto a devolver um valor plausível.

### 5.2 A fitness, de novo (agora com o caminho completo)

Para um indivíduo `t` num problema com `trainSet` de 50 casos:

```
evalTree x t          :: Maybe Lit         (50 chamadas)
maybeToResult         :: Result Lit
metric y <$>          :: Result (Sum Integer)
mconcat               :: Result (Sum Integer)
```

- Se **qualquer** caso falhar, o `mconcat` produz `Error`, que ordena **depois**
  de qualquer sucesso e nunca é `isPerfectSolution`.
- `Sum` existe para que a soma dos casos seja um `Monoid`: `mconcat` de uma
  lista de `Sum Integer` soma os inteiros.
- **Menor é melhor.** `0` = perfeito.

O custo por indivíduo é, portanto, **`length trainSet` avaliações de árvore**.
Com 50 casos de treino, cada indivíduo custa 50 execuções de árvore; uma corrida
completa pontua da ordem de **2 × 10^5 indivíduos**, ou seja, **~10 milhões** de
execuções de árvore em `sum-of-squares`.

### 5.3 O cache de medidas, no contexto

`computeMeasure` já rodou em `mkIndividual`. Durante a evolução, quem invalida
esse cache são as transformações de forma:

| Operação | O que acontece com as medidas |
|---|---|
| gerar (`buildTree`) | nós nascem com `Nothing` |
| `mkIndividual` | `computeMeasure` antes de pontuar |
| crossover | `computeMeasure` nos dois filhos (obrigatório: ver §6.3) |
| mutação | ancestrais ficam com medida **velha**; o novo subtree nasce sem medida; `mkIndividual` conserta antes de pontuar |
| ler checkpoint | medidas vêm do arquivo; `mkIndividual` recalcula |
| `prune` | `resetMeasure` ao ler; `computeMeasure` ao terminar |

🔎 **Leitura fina — por que o crossover mede os filhos?** Porque a **mutação
vem logo depois** e usa `getCurrentDepth` do nó sorteado para calcular o
orçamento de profundidade. Sem `computeMeasure`, todo nó de uma árvore recém
transplantada reportaria `currentDepth = 0` (a medida seria calculada tratando
aquele nó como raiz), e a mutação geraria subtree grande demais perto do fundo.
Esse é o motivo do `map computeMeasure . tupleToList` em `doCrossover`.

---

## 6. Fase 4 — um passo evolutivo, em ordem

**Onde estamos:** `steadyStateReplace`, em [src/Evolution/Run.hs](src/Evolution/Run.hs).
Este é o coração da busca. Ele roda ~149.500 vezes.

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

Leia de cima para baixo: **selecionar → casar → cruzar → mutar → deduplicar →
sobreviver**. Cada etapa consome o RNG na ordem em que aparece. Vamos uma a uma.

### 6.1 Seleção: rank exponencial + roleta

```haskell
exponentialRank cfg ps = zip (SL.fromSortedList ps) $ (_parentScalar cfg **) <$> [0 ..]
```

A população já está ordenada (melhor primeiro). O rank `i` (0-based) recebe
peso `0.9993 ** i`:

| rank | peso (`0.9993 ^ rank`) | fração da roleta, com 1000 indivíduos |
|---|---|---|
| 0 (melhor) | 1.0000 | ~0,139% |
| 1 | 0.9993 | ~0,139% |
| 2 | 0.9986 | ~0,139% |
| … | … | … |
| 999 (pior) | 0.4969 | ~0,069% |

Números úteis:

- **melhor vs. segundo:** `1 / 0.9993 ≈ 1,0007` — praticamente iguais;
- **melhor vs. pior (rank 999):** `0.9993^999 ≈ 0.497` — o pior ainda tem
  **metade** do peso do melhor;
- como há 1000 indivíduos, a soma dos pesos é
  `(1 - 0.9993^1000) / 0.0007 ≈ 719,3`, então cada um leva uma fatia pequena da
  roleta (o melhor ~0,139%, o pior ~0,069%). A roleta é quase uniforme **de
  propósito**.

Ou seja: a pressão seletiva é **deliberadamente fraca**. Isso preserva
diversidade (o ponto do artigo) e evita que a população convirja cedo demais
para um clone. É "seleção proporcional à fitness expressa por **rank**" — só a
**ordem** importa, então escalas malucas de fitness não distorcem a roleta.

🧠 **Analogia.** Uma roleta em que o campeão tem uma fatia só um pouquinho maior
que os outros. Todo mundo pode ser chamado para reproduzir; os melhores são
chamados um pouco mais.

#### A roleta — `sampleManyWithProb`

```haskell
(max, roulette) = cumSum xs
sampleWithProb = do
  rand <- randomR (0, max)
  return $ fst . fromJust $ find ((> rand) . snd) roulette
```

`cumSum` acumula os pesos (e `reverse` devolve a ordem original). O sorteio é
uniforme em `[0, total]`; escolhe-se a primeira entrada cujo **limiar
cumulativo** ultrapassa o número sorteado. Os pesos não precisam somar 1 — só
as **razões** importam.

Com `_individualsPerStep = 2`, são sorteados **dois pais por passo**,
independentemente (podem ser o mesmo indivíduo!). `replicateM` faz isso.

### 6.2 Emparelhamento

```haskell
inPairs (x1 : x2 : xs) = (x1, x2) : inPairs xs
inPairs _              = []
```

Agrupa de 2 em 2; um elemento ímpar no fim é descartado (não procria). Com 2
pais, dá **um par por passo**.

### 6.3 Crossover — transplante com compatibilidade de tipo

```haskell
doCrossover cfg parents =
  tossCoin (_crossoverRate cfg) (tupleToList parents) $
    maybe [] (map computeMeasure . tupleToList) <$> uncurry (crossOver cfg) parents
```

Primeiro, o **cara-ou-coroa**:

```haskell
tossCoin prob fallback action = do
  toss <- (< prob) <$> randomR (0, 1)
  if not toss then return fallback else action
```

- com probabilidade **0.5**, roda o crossover;
- senão, **os próprios pais passam adiante** (e ainda podem ser mutados em
  §6.4).

Se o crossover roda mas devolve `Nothing` (nenhum parceiro compatível), o
resultado é `[]`: **nenhum filho** naquele passo.

#### `crossOver` em detalhe

[src/Evolution/Crossover.hs](src/Evolution/Crossover.hs):

1. **Sorteia um nó do pai 1:** `p1 <- randomR (1, getNodeCount t1)`.
   Todos os nós têm a mesma probabilidade (inclusive a raiz).
2. **Recupera a subtree doada:** `b1 = getBranchAt p1 t1`.
3. **Coleta todos os pontos do pai 2 compatíveis:**
   `getAllMatchingSubtrees cfg b1 t2`.
4. **Se a lista está vazia → `Nothing`.** Os pais ficam intactos; nenhuma
   avaliação é desperdiçada.
5. **Sorteia um parceiro** e faz a **troca bidirecional**:
   ```haskell
   c1 <- atPoint p1 (const $ return b2) t1   -- t1 com b1 trocado por b2
   c2 <- atPoint p2 (const $ return b1) t2   -- t2 com b2 trocado por b1
   ```

O critério de compatibilidade:

```haskell
satisfies candidateBranch =
     inferOutputType argTypes candidateBranch == desiredOutType  -- mesmo tipo
  && candidateBranch `fitsIn` branch                              -- cabe no pai 1
  && branch `fitsIn` candidateBranch                              -- cabe no pai 2

fitsIn src dest = getCurrentDepth dest + getHeight src <= _maxTreeDepth cfg
```

Três exigências, todas necessárias:

- **tipo igual:** `inferOutputType` descobre o tipo que a subtree produz no
  contexto do programa. É **igualdade**, não unificação — para operadores
  polimórficos isso é conservador (pode rejeitar um par legal), mas nunca gera
  filho mal tipado.
- **cabe nos dois sentidos:** cada pai tem um orçamento de profundidade
  diferente. `src` precisa caber onde `dest` está **e** vice-versa. O teste usa
  a **altura** da subtree que entra e a **profundidade** do ponto que sai.
- **coleta em pré-ordem com posição:** `go` devolve `(Point, Tree)` junto, para
  a troca não precisar de uma segunda busca.

🧠 **Analogia.** É um transplante de órgão: o órgão doado precisa ser do **mesmo
tipo sanguíneo** (tipo) e **caber na cavidade** do receptor (profundidade). Se
não houver doador compatível, a cirurgia é cancelada — e ninguém paga o preço.

#### Exemplo

```
t1 = AddInt                     t2 = If
     ├── Arg 0                       ├── GtInt
     └── MultInt                     │   ├── Arg 0
         ├── Arg 1                   │   └── IntLit 0
         └── IntLit 2                ├── Arg 1
                                     └── IntLit 0
```

Pré-ordem de `t1`: `1 AddInt, 2 Arg0, 3 MultInt, 4 Arg1, 5 IntLit 2`.
Sorteia-se `p1 = 3` → `b1 = MultInt [Arg1, 2]`, tipo `GInt`.

Em `t2`, as subtrees de tipo `GInt` são: `If` (1), `Arg0` (3), `IntLit 0` (4),
`Arg1` (5), `IntLit 0` (6). Sorteia-se `(5, Arg1)`:

```
c1 = AddInt [Arg0, Arg1]
c2 = If [GtInt [Arg0, 0], AddInt [Arg0, MultInt [Arg1, 2]], 0]
```

Os dois filhos são bem tipados **por construção**: o tipo do buraco e o tipo do
enxerto coincidem.

### 6.4 Mutação — trocar uma peça por outra do mesmo encaixe

```haskell
doMutation cfg tree = tossCoin (1 - _crossoverRate cfg) tree $ mutate cfg tree
```

Probabilidade **0.5** (complemento do crossover). `mutate`:

```haskell
mutate cfg = atRandomPoint (replaceSubtree cfg)
```

#### 6.4.1 Escolher o ponto — `atRandomPoint` / `atPoint`

`Point` é o índice **1-based em pré-ordem** (DFS, esquerda→direita):

```
1 AddInt
├── 2 Arg 0
└── 3 MultInt
    ├── 4 Arg 1
    └── 5 IntLit 2
```

`atPoint` desce usando o **node count** de cada filho como "mapa de tamanho":

```haskell
changeChildren p f (t : ts)
  | n < p     = (t :) <$> changeChildren (p - n) f ts   -- alvo não está aqui: pula
  | otherwise = (: ts) <$> atPoint p f t                 -- alvo está aqui: desce
  where n = getNodeCount t
```

Exemplo com `point = 5`: no topo, `p = 4`; o filho `Arg 0` tem `n = 1 < 4` →
pula, `p = 3`; o filho `MultInt` tem `n = 3`, e `3 < 3` é falso → desce; em
`MultInt`, `p = 2`; `Arg 1` tem `n = 1 < 2` → pula, `p = 1`; o próximo filho é
`IntLit`, e `atPoint 1` aplica a mutação nele. Chegou ao nó 5.

🔎 **Leitura fina.** A navegação usa `getNodeCount` dos **filhos não tocados**,
cujas medidas são válidas. O nó reconstruído mantém a medida antiga (que fica
**stale** até o `mkIndividual` seguinte) — mas isso não atrapalha a navegação,
porque só se consultam tamanhos de subtrees intactas.

#### 6.4.2 Gerar o substituto — `replaceSubtree`

```haskell
replaceSubtree config tree =
  grow config
    (min (_maxMutationTreeDepth config) (_maxTreeDepth config - getCurrentDepth tree))
    (inferOutputType argTypes tree)
```

Duas restrições, ambas essenciais:

- **tipo:** `inferOutputType` descobre o que a subtree substituída produzia; o
  gerador só constrói algo **daquele tipo**. O pai continua bem tipado.
- **profundidade:** o orçamento é `min 15 (15 - currentDepth)`. Uma mutação
  **perto do fundo** de uma árvore profunda é forçada a ser **rasa**. É isso que
  impede crescimento sem limite (bloat) — e é por isso que a mutação **precisa**
  das medidas corretas (ver §5.3).

🧠 **Analogia.** Trocar uma peça do motor por outra **do mesmo encaixe** e que
**não faça o carro ficar mais largo que a garagem**.

### 6.5 Deduplicação — e uma surpresa sobre igualdade

```haskell
popTrees = map _indTree $ SL.fromSortedList pop
withoutDuplication = filter (`notElem` popTrees) xMen
```

A intenção é clara: filhos que já existem na população não precisam ser
avaliados de novo. Mas há uma sutileza.

🔎 **Leitura fina — `Eq Tree` inclui o cache de medidas.** `Tree` deriva `Eq`
e carrega `_measure :: Maybe Measure`. Então duas árvores com a **mesma forma**
mas medidas diferentes **não são iguais** para `notElem`. Na prática:

- **pais que passaram direto** (crossover não sorteado e mutação não sorteada)
  têm exatamente as mesmas medidas da população → são filtrados (custo 0);
- **filhos de crossover** recebem `computeMeasure` → podem coincidir
  exatamente com um indivíduo existente → filtrados;
- **filhos mutados** têm ancestrais com medida **velha** e o novo subtree sem
  medida → praticamente nunca são iguais a um membro medido da população, mesmo
  que a forma coincida.

Ou seja, a deduplicação é **mais fraca** do que o comentário sugere. Não é um
bug de correção (a população continua válida), mas explica por que o número de
avaliações "reais" não bate com o contador.

### 6.6 Sobrevivência — `keepBest` e elitismo

```haskell
newPop = keepBest cfg pop (mkIndividual cfg <$> withoutDuplication)

keepBest cfg oldPop children =
  SL.take (_popSize cfg) $ oldPop <> SL.toSortedList children
```

1. Cada filho sobrevivente é **medido e pontuado** (`mkIndividual`).
2. `oldPop <> children` faz **merge ordenado** das duas listas ordenadas.
3. `SL.take 1000` mantém os melhores.

Consequências:

- **Elitismo puro:** o melhor indivíduo **nunca** é descartado. Se um filho é
  pior que todos os 1000, ele simplesmente não entra.
- **Steady-state:** a população não é substituída por geração; a cada passo só
  alguns filhos entram e alguns ruins saem. O placar muda suavemente.
- O merge é o ponto em que a **parsimônia** atua: empate de fitness → menos nós
  vence.

🧠 **Analogia.** Um torneio contínuo: a cada rodada, dois competidores geram
filhos; os filhos entram no ranking; os piores da tabela são eliminados. O
líder nunca perde a vaga por acaso. Esse modelo é o *steady-state* de GP (em
oposição ao modelo geracional); o Field Guide citado na §4.2.1 cobre os dois.

### 6.7 A contabilidade de avaliações

```haskell
evaluations = length children   -- antes da deduplicação
```

🔎 **Leitura fina — o orçamento é conservador.** `children` inclui:

- filhos de crossover bem-sucedido (2);
- pais passados direto quando o crossover não foi sorteado (2), que ainda podem
  ser mutados ou não;
- **nada** quando o crossover falhou (`[]`).

O contador soma `length children` **antes** de filtrar duplicatas. Portanto o
orçamento de 300.000 **superestima** o número de indivíduos realmente
pontuados. E há outro detalhe: quando o crossover não é sorteado, os "filhos"
são os próprios pais; se a mutação também não for sorteada, eles são filtrados
como duplicatas e **custam 0 avaliações reais**, mas contam 2 no orçamento.

Ordem de grandeza por passo:

| Cenário | Filhos contados | Novos realmente pontuados |
|---|---|---|
| crossover ok (p=0.5) | 2 | 0–2 (após dedup) |
| crossover não sorteado (p=0.5) | 2 | ~1 em média (cada pai muta com p=0.5) |
| crossover falhou (`Nothing`) | 0 | 0 |

Isso não compromete a busca: o laço para quando o **contador** chega a 300.000,
e o critério é uniforme para todas as corridas. Mas explica por que
`totalEvals` no JSON não é "quantos indivíduos foram avaliados".

📌 **Estado do mundo:** nova população ordenada de 1000; `innerNEvals` (0 ou 2
tipicamente); RNG avançado por todos os sorteios do passo.

---

## 7. Fase 5 — o laço, a parada e o checkpoint

**Onde estamos:** ainda em `runAndLog`, função `go`.

```haskell
go maybeStatsCache nEvals pop = do
  when (nEvals `mod` checkpointEvery == 0) $ do
    S.liftIO $ putStrLn ":: CHECKPOINT ::"
    saveCheckpoint checkpointFilename nEvals pop

  (innerNEvals, newPop) <- hoistState $ steadyStateReplace cfg pop
  let totalNEvals = innerNEvals + nEvals
      pct = 100.0 * fromIntegral totalNEvals / fromIntegral (_nEvaluations cfg)
  time <- S.liftIO getCurrentTime
  S.liftIO $ printf "%s\t%d/%d (%.2f%%)\n" (show time) totalNEvals (_nEvaluations cfg) pct

  if isPerfectSolution (_fitness $ bestIndividual newPop)
    then do
      S.liftIO $ putStrLn $ show time <> " -\tPerfect solution found! " <> pretty (_indTree $ bestIndividual newPop)
      return (newPop, totalNEvals)
    else
      if totalNEvals >= _nEvaluations cfg
        then return (newPop, totalNEvals)
        else go Nothing totalNEvals newPop
```

### 7.1 A ordem exata dentro de uma iteração

1. **Checkpoint?** Se `nEvals` é múltiplo de 1000, salva **antes** de dar o
   passo. Note que o primeiro `go` recebe `nEvals = 1000` (população inicial) —
   então a **primeira coisa** que o laço faz é gravar um checkpoint. É por isso
   que a saída típica mostra `:: CHECKPOINT ::` logo no começo.
2. **Um passo evolutivo** (toda a §6).
3. **Imprime o progresso** com timestamp, avaliações e porcentagem.
4. **Solução perfeita?** `isPerfectSolution` da fitness do melhor. Se sim,
   imprime o programa e retorna.
5. **Orçamento esgotado?** `totalNEvals >= 300000` → retorna.
6. **Senão**, recursão com o novo estado.

`bestIndividual = head . SL.fromSortedList` — como a lista está ordenada, o
melhor é sempre a cabeça. Não há busca.

### 7.2 Quando parar

`isPerfectSolution` depende do tipo de fitness ([src/Evolution/Fitness.hs](src/Evolution/Fitness.hs)):

| Tipo | Perfeito quando | Onde aparece |
|---|---|---|
| `Int` / `Integer` | `<= 0` | métricas de contagem/erro inteiro |
| `Float` | `< 1e-3` | métricas contínuas (tolerância: 0 exato é inalcançável) |
| `Sum a` | quando o componente é perfeito | soma dos casos |
| `Result a` | `Result x` → componente; `Error` → sempre `False` | fitness final de todo benchmark |

Note que a parada é pelo fitness de **treino**. É possível parar com fitness 0
e acurácia de teste < 1 (generalização imperfeita) — e isso é esperado, não um
bug.

### 7.3 `hoistState` — a ponte entre os dois mundos

```haskell
hoistState :: Monad m => S.State s a -> S.StateT s m a
hoistState = S.state . S.runState
```

`runState` de uma computação pura devolve `s -> (a, s)`. `S.state` constrói uma
ação `StateT` a partir dessa função. Resultado: o **mesmo gerador** atravessa a
fronteira, e `steadyStateReplace` continua sendo código puro e testável,
enquanto o laço pode fazer `IO` (imprimir, salvar).

### 7.4 O logging por iteração está desligado

No código atual, as chamadas ao callback estão **comentadas**:

```haskell
-- statsCache <- S.liftIO $ loggingFunction Nothing time (length p) p
...
-- newStatsCache <- S.liftIO $ loggingFunction maybeStatsCache time totalNEvals newPop
...
else go Nothing totalNEvals newPop
```

Consequência prática: **o `.log.csv` sai só com o cabeçalho**. O mecanismo
existe e está correto:

- `logPop` monta uma linha com tempo, avaliações, fitness, altura, nós,
  acurácia, NMSE, programa simplificado e programa bruto;
- `memoLast` evita re-pontuar o mesmo melhor indivíduo a cada tick (cache de
  uma entrada, passado explicitamente porque o laço é puro);
- o `Handle` é fechado no fim de `runBenchmark`.

Religar é trocar `go Nothing` por `go (Just statsCache)` e descomentar as duas
linhas. Se você fizer isso, prepare-se para o custo: `logPop` roda o melhor
programa no **conjunto de teste** (até 2000 casos) a cada passo — a corrida
fica bem mais lenta.

⚠️ **Armadilha:** como o log está desligado, não há série temporal de fitness.
Para analisar convergência hoje é preciso instrumentar o laço (ou usar a saída
do terminal, que tem apenas avaliações e porcentagem).

### 7.5 Checkpoint — o "save" do videogame

```haskell
data Checkpoint = MkCheckpoint
  { _gen          :: (Word64, Word64)   -- estado do SplitMix
  , _population   :: [Tree]             -- só árvores (sem fitness)
  , _currentEvals :: Int
  } deriving (Show, Read, Generic, Flat)
```

- **Formato:** binário `flat`, derivado de `Generic`. Populações são grandes;
  JSON seria ordens de magnitude maior e mais lento.
- **Instâncias órfãs:** `Flat` para os tipos da gramática é derivado **aqui**,
  com `StandaloneDeriving`, para que `Grammar` não dependa de `flat`.
- **Frequência:** a cada 1000 avaliações, sobrescrevendo o mesmo arquivo.
  Como os passos somam 0 ou 2, e a população inicial tem 1000, os múltiplos de
  1000 são sempre atingidos.
- **Último checkpoint:** numa corrida que esgota o orçamento, o de 299.000.
  Ao chegar a 300.000, o laço **retorna** sem chamar `go` de novo — logo não
  salva em 300.000. É por isso que rodar o mesmo comando outra vez imprime
  `LOADING CHECKPOINT` e termina em segundos (se a corrida parou antes por
  solução perfeita, o último save é anterior a isso).
- **Chave do arquivo:** `./checkpoint/s<seed>_<benchmark>.checkpoint`. Só seed
  e problema — **não** os hiperparâmetros.

⚠️ **Armadilha séria:** como a chave não inclui `popSize`, `treeDepth` nem
`_crossoverRate`, mudar hiperparâmetros e rodar de novo **retoma** o checkpoint
antigo, com a população e o contador velhos. Sempre apague o checkpoint depois
de mexer na config:
`rm ./checkpoint/s42_sum-of-squares.checkpoint`.

⚠️ **Armadilha:** o checkpoint nunca é apagado ao final. Rodar de novo gera
**novos** arquivos em `./output/` (outro timestamp) sem apagar os antigos.

### 7.6 `runEvolution` — a versão pura

```haskell
runEvolution :: Fitness a => Config a -> St (SortedPop a)
```

Sem log, sem checkpoint, sem parada por solução perfeita: só `initPop` + passos
até o orçamento. É a versão usada por experimentos e testes que só querem a
população final. Se você for instrumentar a busca, comece por aqui.

📌 **Estado do mundo:** ao sair do laço, população final ordenada e
`totalNEvals`; handle de log aberto (fechado em seguida); checkpoint em disco no
último múltiplo de 1000.

---

## 8. Fase 6 — os artefatos finais

De volta a `runBenchmark`, depois do `evalStateT`:

```haskell
hClose logFileHandle
writeFile finalResultFile $ logBest testSet (_indTree $ head $ SL.fromSortedList finalPop)
writeFile jsonFile $ jsonBest (getBenchmarkId benchmark) seed nEvals testSet (head $ SL.fromSortedList finalPop)
```

### 8.1 `.result.csv` — caso a caso

`logBest` gera:

```
x0;...;x(N-1);y;y_hat;right
```

- `x0..xn`: entradas impressas com `pretty`;
- `y`: esperado;
- `y_hat`: obtido, ou `nan` se o programa crashou naquele caso;
- `right`: `show (Just y == yHat)`.

⚠️ **Armadilha de leitura:** `right` usa **igualdade exata**, enquanto
`accuracy` (no JSON) usa **tolerância `1e-4` para floats**. Então o CSV pode
dizer `False` num caso que a acurácia contou como acerto. Para floats, confie na
coluna `accuracy` para o número agregado e trate `right` como "bateu bit a
bit".

### 8.2 `.result.json` — o resumo do campeão

`jsonBest` monta o JSON **à mão** (com um helper `key .: value` que usa `show`,
daí strings saírem com aspas):

| Campo | Conteúdo |
|---|---|
| `datasetName` | nome do dataset |
| `seed` | seed usada |
| `totalEvals` | orçamento **contado** (não o nº real de indivíduos pontuados) |
| `fitness` | fitness de treino (string; `"nan"` se `Error`) |
| `height` | altura da árvore |
| `nodeCount` | número de nós |
| `accuracy` | fração de acertos no **teste** |
| `nmse` | erro quadrático médio normalizado pela variância (ou `"nan"`) |
| `stringRepSimple` | programa após `simplifyTree` (legível) |
| `stringRep` | programa como evoluiu |
| `showTree` | representação `show` — **é o que o `prune` lê de volta** |

Por que duas representações? `stringRep` é fiel ao que a busca encontrou;
`stringRepSimple` passa pelas regras algébricas de
[src/Grammar/Simplify.hs](src/Grammar/Simplify.hs) (folding de constantes,
`x + 0 = x`, `if True then a else b = a`, etc.) e costuma ser bem menor e mais
legível. A simplificação **preserva semântica**, então pode ser usada sobre uma
solução já validada.

### 8.3 `accuracy` e `nmse`

```haskell
accuracy ys ysHat = acertos / total
  -- floats: |x - y| < 1e-4; resto: igualdade exata; crash nunca acerta

nmse ys ysHat = MSE(pred, atual) / var(atual)
```

- `accuracy` é a fração de casos corretos **no teste**.
- `nmse` só existe se **tudo** for numérico (`Int` ou `Float`); senão `"nan"`.
  `0` = perfeito; `1.0` = não melhor que prever sempre a média.

Essas métricas são calculadas **uma vez**, no final, sobre o conjunto de teste.
É por isso que o `prune` também as recalcula: ele quer comparar antes/depois no
mesmo conjunto.

📌 **Estado do mundo:** três arquivos em `./output/` (log com cabeçalho,
result.csv, result.json), checkpoint em `./checkpoint/`, datasets em
`./datasets/`. Processo termina com código 0.

---

## 9. Fase 7 — `prune`, o segundo programa

**Onde estamos:** [src/Prune.hs](src/Prune.hs). Este é um **processo separado**,
rodado depois, sobre os artefatos:

```bash
mkdir -p input-prune output-prune
cp "./output/<id>.result.json" input-prune/
cabal run hotgp-exe -- prune
```

`prune` lista `input-prune/`, processa cada arquivo e grava o mesmo nome em
`output-prune/`. Ele **não cria** os diretórios.

### 9.1 Ler o programa de volta

```haskell
Just (Object content) <- decodeFileStrict ("input-prune/" <> fileName)
let Just (String showTree) = KM.lookup "showTree" content
    Just (String datasetNameText) = KM.lookup "datasetName" content
    tree = resetMeasure $ read (unpack showTree)
```

- `read` funciona porque `Tree` deriva `Read` — o `showTree` é um round-trip
  fiel.
- `resetMeasure` é **obrigatório**: as medidas gravadas referem-se à posição
  original de cada nó na árvore inteira. Se você promover uma subtree, o
  `currentDepth` antigo estaria errado. Melhor descartar e recalcular.

### 9.2 Recarregar o mesmo split

```haskell
(trainSet, testSet) <- case getProblem datasetName of
  Just (MkProblem problem) -> loadTrainAndTestSet "./" problem
```

Isso pode **baixar de novo** se `./datasets/` foi apagado — e, como o split é
definido pelo shuffle do download, as acurácias podem não ser comparáveis às
originais. Para comparar antes/depois de forma justa, mantenha os mesmos
arquivos de dataset.

### 9.3 A poda — subida de encosta gulosa

```haskell
pruneTree dataset tree = go [] (minimumBy compareTrees [tree, simplifyTree tree])
  where
    compareTrees = compare `on` (\t -> (1 - getAcc dataset t, getHeight t, getNodeCount t))
    go path t = case replaceWithSubtrees path t of
      [] -> iterateNext t path
      subtrees ->
        let bestSubtree = minimumBy compareTrees subtrees
         in case compareTrees t bestSubtree of
              LT -> iterateNext t path          -- atual é melhor: mantém
              _  -> go path bestSubtree         -- deleção melhorou: aceita e desce
```

Ranking, em ordem:

1. **maior acurácia** (`1 - acc` é minimizado);
2. **menor altura**;
3. **menor número de nós**.

A acurácia **nunca é sacrificada**; tamanho só desempata. O ponto de partida é
o melhor entre a árvore original e a já simplificada. Em cada posição, tenta
**deletar exatamente um nó-wrapper**, promovendo um filho; se a deleção melhora
o ranking, aceita e continua do mesmo ponto; senão, avança para a próxima
posição (`nextPath`).

🧠 **Analogia.** É um **bonsai**: você tira um galho de cada vez, mas só aceita o
corte se a árvore continuar dando o mesmo fruto — e, entre dois cortes que dão
o mesmo fruto, prefere o que deixa a planta menor.

### 9.4 Quais deleções são legais

```haskell
replaceWithSubtrees [] (Node m op trs) = (trs !!) <$> checkPromotableArgs op

checkPromotableArgs (opType -> fType) =
  map fst $ filter ((_outType fType ==) . snd) $ zip [0..] $ _argTypes fType
```

Só se pode promover um argumento cujo **tipo declarado é igual** ao tipo de
saída do operador. Assim a expressão mantém o tipo. Para operadores
polimórficos, a comparação é **igualdade de variáveis**, não unificação — logo
é conservadora.

Há um caso especial para `map`:

```haskell
replaceWithSubtrees [] (Node m Map [LeafLit (LambdaLit (MkTypedTree _ (MkFunctionType [a] b))), list])
  | a == b = [list]     -- map id xs = xs
```

`checkPromotableArgs` não expressaria isso (para `map`, o argumento lambda não
tem o mesmo tipo da lista), mas quando o lambda é `a -> a`, a lista pode ser
promovida diretamente. É a regra `map id xs = xs` embutida no pruner.

O caminho (`TreePath = [Int]`) é uma cadeia de índices de filho: `[]` = raiz,
`[0,2]` = terceiro filho do primeiro filho. `nextPath` faz a caminhada em
pré-ordem e **mergulha em corpos de lambda** — um `LambdaLit` é folha
sintaticamente, mas o corpo ainda pode ser podado.

### 9.5 A saída

O JSON original é **preservado** e recebe novos campos (`Object $ content <>
newJson`):

- `showPrunedTree`, `stringRepPruned`, `stringRepPrunedSimple`;
- `trainAccuracy` / `testAccuracy` (antes);
- `trainAccuracyPruned` / `testAccuracyPruned` (depois);
- `heightPruned`, `nodeCountPruned`.

Se `trainAccuracy` e `trainAccuracyPruned` forem iguais (e o tamanho menor), a
poda fez seu trabalho sem custo de generalização.

---

## 10. O fluxo completo em uma página

### 10.1 Diagrama de sequência

```
Main.main
  ├─ getArgs / parseArgs
  ├─ createDirectoryIfMissing ./checkpoint
  └─ Problems.runProblem
       └─ Problems.getProblem ──► MkProblem bench
            └─ Run.runBenchmark
                 ├─ hSetBuffering stdout
                 ├─ logFileIdentifier (timestamp)
                 ├─ Log.prepareLogFiles ──► ./output/<id>.log.csv (cabeçalho)
                 ├─ Dataset.loadTrainAndTestSet
                 │    ├─ Download.downloadBenchmark (curl|gzip|sort -R, 1ª vez)
                 │    ├─ Dataset.readJson "-random.json"
                 │    ├─ Dataset.readJson "-edge.json"
                 │    └─ splitAt trainCases (edge <> random) + take testCases
                 ├─ BenchmarkToConfig.makeConfig
                 │    ├─ TermsAndOps (args, ERCs, ops por tipo)
                 │    ├─ SamplerTable.buildTable full  (lazy)
                 │    └─ SamplerTable.buildTable grow  (lazy)
                 └─ evalStateT (Run.runAndLog cfg logToFile ckpt) (mkStdGen seed)
                      ├─ Checkpoint.doesCheckpointExist
                      │    ├─ sim  ──► loadCheckpoint (unflat, RNG, re-score)
                      │    └─ não  ──► initPop = ramped + mkIndividual
                      └─ go nEvals pop
                           ├─ (nEvals mod 1000 == 0) saveCheckpoint
                           ├─ steadyStateReplace
                           │    ├─ exponentialRank (0.9993^rank)
                           │    ├─ sampleManyWithProb (roleta)
                           │    ├─ inPairs
                           │    ├─ doCrossover (0.5)
                           │    │    └─ crossOver: ponto → subtree → matching → swap
                           │    ├─ doMutation (0.5)
                           │    │    └─ atRandomPoint → replaceSubtree (grow)
                           │    ├─ dedup (notElem)
                           │    └─ keepBest (merge + take 1000)
                           ├─ printf progresso
                           ├─ isPerfectSolution? ──► fim
                           └─ orçamento esgotado? ──► fim
                 ├─ hClose log
                 ├─ Log.logBest  ──► .result.csv
                 └─ Log.jsonBest ──► .result.json
```

### 10.2 Onde cada conceito vive

| Fase | Módulo principal | Funções-chave | Custo |
|---|---|---|---|
| F0 | [app/Main.hs](app/Main.hs) | `main`, `parseArgs` | O(1) |
| F1 | [Benchmark/Problems.hs](src/Benchmark/Problems.hs) | `allProblems`, `getProblem`, `runProblem` | O(nº problemas) |
| F2.3 | [Benchmark/Log.hs](src/Benchmark/Log.hs) | `prepareLogFiles` | O(1) + I/O |
| F2.4 | [Benchmark/Download.hs](src/Benchmark/Download.hs), [Dataset.hs](src/Benchmark/Dataset.hs), [Parse.hs](src/Benchmark/Parse.hs) | `downloadBenchmark`, `readJson`, `loadTrainAndTestSet` | I/O + parse |
| F2.5 | [BenchmarkToConfig.hs](src/Benchmark/BenchmarkToConfig.hs) | `makeConfig`, `operationsFromTypes` | O(casos) p/ closure |
| F2.6 | [SamplerTable.hs](src/Evolution/SamplerTable.hs) | `buildTable`, `buildTableForLevel`, `instantiateArgs`, `buildTree` | **alto e lazy** |
| F3 | [Evolution/Run.hs](src/Evolution/Run.hs), [Generate.hs](src/Evolution/Generate.hs), [Checkpoint.hs](src/Evolution/Checkpoint.hs) | `initPop`, `ramped`, `mkIndividual`, `loadCheckpoint` | 1000 avaliações |
| F4 | [Evolution/Run.hs](src/Evolution/Run.hs), [Crossover.hs](src/Evolution/Crossover.hs), [Mutation.hs](src/Evolution/Mutation.hs) | `steadyStateReplace`, `crossOver`, `mutate`, `keepBest` | 0–2 avaliações/passo |
| F5 | [Evolution/Run.hs](src/Evolution/Run.hs) | `go`, `saveCheckpoint` | I/O a cada 1000 |
| F6 | [Benchmark/Log.hs](src/Benchmark/Log.hs) | `logBest`, `jsonBest`, `getAccuracyAndNmse` | O(casos de teste) |
| F7 | [Prune.hs](src/Prune.hs) | `pruneFile`, `pruneTree`, `nextPath`, `replaceWithSubtrees` | O(passos × nós) |

### 10.3 Onde colocar um breakpoint

Se você quer **ver** o fluxo acontecendo:

1. **`Evolution.Run.steadyStateReplace`** — o passo inteiro. Inspecione
   `parents`, `children`, `xMen`, `withoutDuplication`, `newPop`.
2. **`Evolution.CrossOver.crossOver`** — veja `b1`, `matchingT2` e os dois
   filhos. É o melhor lugar para entender o transplante.
3. **`Evolution.SamplerTable.buildTree`** — veja a escolha de nó e a descida.
4. **`Benchmark.BenchmarkToConfig.fitness`** — veja uma avaliação completa
   (cuidado: chamada milhares de vezes).
5. **`Evolution.Run.initPop`** — veja a população nascer.

Dica: `stack ghci` (ou `cabal repl`) carrega a biblioteca; `runEvolution` com
uma `Config` pequena é ótimo para experimentar sem I/O. `pp` (de
`Evolution.Pretty`) imprime a população como tabela — a chamada existe,
comentada, no fim de `runBenchmark`.

### 10.4 Módulos fora do caminho crítico

Nem todo módulo participa de toda execução. Estes são os que ficam nas
margens — úteis de conhecer, mas que não aparecem no meio do laço:

| Módulo | Quando entra em cena | Papel |
|---|---|---|
| [Grammar/Pretty.hs](src/Grammar/Pretty.hs) | fim (`logBest`, `jsonBest`) e mensagens | transforma `Tree`/`Lit` em texto legível; **nada lê essas strings de volta** (exceto `showTree`, que usa `show`) |
| [Evolution/Pretty.hs](src/Evolution/Pretty.hs) | só se você descomentar `putStrLn $ pp finalPop` | imprime a população como tabela |
| [Grammar/Simplify.hs](src/Grammar/Simplify.hs) | fim (`stringRepSimple`) e `prune` | reescrita que preserva semântica; **não** roda no laço |
| [Benchmark/Metrics.hs](src/Benchmark/Metrics.hs) | dentro da closure de fitness | as funções de erro (`intError`, `rightWrong`, Levenshtein, ...) |
| [Benchmark/Helpers.hs](src/Benchmark/Helpers.hs) | fitness, CSV, configuração | `Result`, `maybeToResult`, combinadores de tipos, `csvJoin` |
| [Benchmark/RunSearch.hs](src/Benchmark/RunSearch.hs) | **entrada alternativa**, não chamada pela CLI | varredura de `_crossoverRate` com validação cruzada 5-fold e seed fixa 0 |
| [Benchmark/Problems/*](src/Benchmark/Problems) | F1 | cada arquivo é **um record** `Benchmark a`; sem comportamento |
| [test/](test) | `cabal test`, nunca pelo executável | contrato de tipos/operadores (`typeCheck` incluso) |

O `RunSearch` merece uma nota: ele é um **runner paralelo** a
`runBenchmark`, com diferenças deliberadas — dados via
`loadTrainAndValidationSet` (um fold de validação em vez do teste fixo),
`_crossoverRate` sobrescrito por record update e **seed sempre 0**, para que a
única variável entre execuções seja a taxa testada. Ele não é acessível por
`main`; é chamado por `searchCxRateProblem`, pensado para scripts/experimentos.

### 10.5 Perfil de tempo

Numa corrida completa de `sum-of-squares` (~7 min nesta máquina):

| Etapa | Ordem de grandeza | Observação |
|---|---|---|
| build das tabelas | segundos | lazy; cresce com `_relevantTypes` e `treeDepth` |
| população inicial | 1000 × 50 avaliações | ~50 mil execuções de árvore |
| laço (~149.500 passos) | ~99% do tempo | 2 filhos/passo; cada um avalia 50 casos |
| impressão | ~149.500 linhas | block-buffered |
| checkpoints | ~299 gravações | binário `flat` |
| resultados | O(casos de teste) | uma vez |

O gargalo é sempre **`evalTree` × tamanho do treino × indivíduos**. Aumentar
`_trainCases` custa linearmente; aumentar `treeDepth` custa no build da tabela
e no tamanho médio das árvores.

---

## 11. Perguntas frequentes de execução

**Rodei o mesmo comando e terminou em segundos. Por quê?**
Existe checkpoint em `./checkpoint/s<seed>_<problema>.checkpoint`. Numa corrida
que foi até o fim, o último save é o de 299.000; retomar dali gasta só os 1000
restantes. Para recomeçar:
`rm ./checkpoint/s<seed>_<problema>.checkpoint`.

**Duas execuções com a mesma seed deram resultados diferentes.**
Possíveis causas, em ordem de probabilidade:
1. `./datasets/` foi apagado/rebaxado → novo `sort -R` → **novo split**;
2. havia checkpoint de uma execução anterior;
3. você mudou hiperparâmetros e o checkpoint antigo foi retomado;
4. mudou o código da fitness/gramática.

**O `.log.csv` só tem o cabeçalho.**
O logging por iteração está comentado em `Evolution.Run` (§7.4). O arquivo é
criado e fechado, mas nenhuma linha é escrita.

**O `totalEvals` do JSON não corresponde a indivíduos avaliados.**
O contador soma `length children` antes da deduplicação e inclui pais passados
direto. É um orçamento conservador (§6.7).

**Por que o programa pode "acertar" no treino e errar no teste?**
Porque a busca só vê o treino. O teste é relatório. `accuracy` no JSON pode ser
< 1 mesmo com `fitness` de treino 0 — e `isPerfectSolution` para no treino.

**Vi `nan` no JSON.**
`fitness`/`nmse` são `"nan"` quando a fitness é `Error` (algum caso de teste
crashou) ou quando os valores não são numéricos. `best_fitness = nan` no log
teria o mesmo significado.

**Posso rodar vários problemas em paralelo?**
Sim, desde que **seeds/problemas diferentes** (o checkpoint é chaveado por
`seed` + `benchmark`). Duas execuções do **mesmo par** compartilham o mesmo
arquivo de checkpoint e vão se atropelar. Os datasets são compartilhados, mas o
download é idempotente — ainda assim, dois processos baixando o mesmo arquivo
ao mesmo tempo podem corromper o `.gz`.

**A ajuda não lista `collatzNumbers`.**
Ele existe em `src/Benchmark/Problems/CollatzNumbers.hs`, mas está comentado em
`allProblems`. A ajuda é gerada de `allProblemIds`, então reflete o registro.

**Preciso de internet?**
Só na primeira execução de cada dataset (e no `prune`, se `./datasets/` foi
apagado). Depois disso, os arquivos são reutilizados.

**Como mudo o orçamento/profundidade/população?**
`src/Benchmark/BenchmarkToConfig.hs` (`popSize`, `nGens`, `treeDepth`,
`_parentScalar`, `_crossoverRate`, `_individualsPerStep`). Depois de mudar,
**apague o checkpoint** — ele não codifica a config.

**Por que `typeCheck` não aparece no laço?**
Porque a garantia de tipo vem da **construção** (a `SamplerTable`) e de
`inferOutputType` nos operadores. `typeCheck` é a especificação formal usada
pelos testes (QuickCheck) para validar os geradores. Ver
[UNDERSTAND_THE_CODE.md §11](UNDERSTAND_THE_CODE.md).

**O que são ERCs?**
*Ephemeral random constants*: constantes sorteadas na hora da amostragem
(`randomR (-100,100)`). Por isso `_allowedConstants` guarda **ações** `St Lit`,
não valores: cada nó sorteado pode receber um número diferente.

---

## 12. Referências para aprender cada conceito

### 12.1 Os artigos deste projeto (e vizinhos)

| Artigo | O que ensina | Link |
|---|---|---|
| **HOTGP** — Higher-Order Typed Genetic Programming | o algoritmo implementado aqui: tipos fortes + funções de ordem superior + benchmark suite | <https://doi.org/10.1145/3583131.3590464> |
| **Origami** — (un)folding the abstraction of recursion schemes for program synthesis | a ideia de usar *recursion schemes* (fold/unfold) como blocos de síntese | <https://arxiv.org/abs/2402.13828> |
| **Going Bananas!** — Unfolding Program Synthesis with Origami | como o Origami evoluiu para *unfolds* e combinadores; avalia nos 29 problemas da suíte | <https://arxiv.org/abs/2406.01500> |
| **Sinking the Bloat** in Genetic Programming Using Equality Saturation | controle de bloat por saturação de igualdade — o passo além do `Simplify`/`Prune` | <https://doi.org/10.1007/978-3-032-23005-8_9> |

O título *Going Bananas!* é uma referência ao artigo clássico de recursion
schemes:

- Meijer, Fokkinga & Paterson, **“Functional Programming with Bananas, Lenses,
  Envelopes and Barbed Wire”** (FPCA 1991) —
  <https://doi.org/10.1007/3540543961_7>

### 12.2 Programação Genética

| Conceito | Onde aprender |
|---|---|
| Visão geral de GP | **A Field Guide to Genetic Programming** (Poli, Langdon & McPhee), gratuito: <https://www.gp-field-guide.org.uk/> |
| GP clássico, árvores, reprodução | Koza, *Genetic Programming: On the Programming of Computers by Means of Natural Selection* (MIT Press, 1992) |
| **Strongly Typed GP** (a base do "typed") | Montana, *Strongly Typed Genetic Programming*, Evolutionary Computation 3(2), 1995: <https://doi.org/10.1162/evco.1995.3.2.199> |
| **Ramped half-and-half** | Field Guide, seção de inicialização da população |
| **Seleção por rank / roleta** | Field Guide, cap. de seleção; verbete *fitness proportionate selection*: <https://en.wikipedia.org/wiki/Fitness_proportionate_selection> |
| **Steady-state GP** | Field Guide, cap. de algoritmos; o oposto do modelo geracional |
| **Bloat** e seu controle | o artigo *Sinking the Bloat* acima; e Luke & Panait, *A Comparison of Bloat Control Methods for GP* (2006) |
| **Benchmark suite** usada nos datasets | Helmuth & Spector, *General Program Synthesis Benchmark Suite* (GECCO 2015): <https://doi.org/10.1145/2739480.2754769> |
| Repositório dos datasets | <https://github.com/thelmuth/program-synthesis-benchmark-datasets> |

### 12.3 Tipos, unificação e lambda

| Conceito | Onde aprender |
|---|---|
| **Hindley–Milner** (a inspiração do `unifyTypes`) | <https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system> |
| **Unificação** estrutural | <https://en.wikipedia.org/wiki/Unification_(computer_science)> |
| **Cálculo lambda simplesmente tipado** | Pierce, *Types and Programming Languages* (MIT Press), cap. 9 |
| **Ordem superior** / funções como valores | qualquer introdução a Haskell; ex.: <https://learnyouahaskell.com/higher-order-functions> |

### 12.4 Haskell usado no código

| Recurso | Onde aparece | Onde aprender |
|---|---|---|
| **GADTs** (constraints empacotadas, tipos existenciais) | `Config`, `Individual`, `Problem` | <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/gadt.html> |
| **Pattern synonyms** bidirecionais + `COMPLETE` | `LeafLit`, `LeafArg` | <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/pattern_synonyms.html> |
| **Standalone deriving** | `Individual`, `Checkpoint` | <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/standalone_deriving.html> |
| **State monad** / `StateT` | todo o motor (`St`) | <https://wiki.haskell.org/State_Monad> |
| **Monoides e semigrupos** (`Sum`, `Result`, `UsesInput`, `Zip`) | fitness, sampler, pretty | <https://hackage.haskell.org/package/base/docs/Data-Monoid.html> |
| **`Data.SortedList`** (lista ordenada abstrata) | população | <https://hackage.haskell.org/package/sorted-list> |
| **`flat`** (serialização binária via `Generic`) | checkpoint | <https://hackage.haskell.org/package/flat> |
| **Aeson** (JSON) | dataset e prune | <https://hackage.haskell.org/package/aeson> |
| **Arrays lazy e auto-referentes** (DP) | `levenshteinDistance` | <https://hackage.haskell.org/package/array> e <https://en.wikipedia.org/wiki/Levenshtein_distance> |
| **Avaliação preguiçosa** | listas infinitas no parser, tabela lazy | <https://wiki.haskell.org/Lazy_evaluation> |
| **`foldl'` vs `foldr` vs `foldMap`** | `Concat`, `listConsNode`, `UsesInput` | <https://wiki.haskell.org/Fold> |
| **Functor de tupla** `(ls ++) <$> ...` | crossover | <https://hackage.haskell.org/package/base/docs/Data-Functor.html> |
| **`ViewPatterns`** | `Prune.checkPromotableArgs` | <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/view_patterns.html> |

### 12.5 Conceitos de execução e sistemas

| Conceito | Onde aprender |
|---|---|
| Call-by-value vs. call-by-name | <https://en.wikipedia.org/wiki/Evaluation_strategy> |
| Seed / RNG determinístico (SplitMix) | <https://hackage.haskell.org/package/random> e <https://prng.di.unimi.it/> |
| Checkpoint/restart | <https://en.wikipedia.org/wiki/Application_checkpointing> |
| Hill climbing / busca gulosa | <https://en.wikipedia.org/wiki/Hill_climbing> |
| Normalized MSE | <https://en.wikipedia.org/wiki/Mean_squared_error> |

---

## Apêndice — cola de funções

| Quero entender... | Vá para |
|---|---|
| como o comando é interpretado | `Main.main`, `Main.parseArgs` |
| como um nome vira um problema | `Problems.getProblem`, `Problems.runProblem` |
| como o dataset é baixado/embaralhado | `Download.downloadBenchmark`, `dlAndUnzip` |
| como treino/teste são separados | `Dataset.loadTrainAndTestSet` |
| como JSON vira `Lit` | `Parse.parseJsonLit`, `Dataset.readJson` |
| como o problema vira config | `BenchmarkToConfig.makeConfig` |
| como a fitness é calculada | `BenchmarkToConfig.fitness`, `Benchmark.Helpers.Result` |
| como árvores tipadas são geradas | `SamplerTable.buildTable`, `buildTree`, `instantiateArgs` |
| como a população inicial nasce | `Generate.ramped`, `full`, `grow` |
| como um indivíduo é medido/pontuado | `Individual.mkIndividual`, `Grammar.Helpers.computeMeasure` |
| como um programa é executado | `Grammar.Eval.evalTree`, `eval`, `evalLambda` |
| como um passo evolutivo funciona | `Run.steadyStateReplace` |
| como os pais são escolhidos | `Run.exponentialRank`, `sampleManyWithProb` |
| como o crossover funciona | `Crossover.crossOver`, `getAllMatchingSubtrees`, `getBranchAt` |
| como a mutação funciona | `Mutation.mutate`, `replaceSubtree`, `Helpers.atPoint` |
| como os sobreviventes são escolhidos | `Run.keepBest`, `Individual.Ord` |
| como o laço para | `Run.go`, `Fitness.isPerfectSolution` |
| como retomar de um checkpoint | `Checkpoint.loadCheckpoint`, `decodeCheckpoint` |
| como os resultados são gravados | `Log.logBest`, `Log.jsonBest` |
| como a poda funciona | `Prune.pruneTree`, `nextPath`, `replaceWithSubtrees` |
| o que cada hiperparâmetro faz | `BenchmarkToConfig.makeConfig`, `Evolution.Config` |

---

*Documento escrito para ser lido junto com o código. Se algo aqui divergir do
fonte, o fonte vence — e vale abrir um PR corrigindo este arquivo.*
