# HOTGP — Higher-Order Typed Genetic Programming

https://doi.org/10.1145/3583131.3590464

Sistema de Programação Genética (GP) que busca programas funcionais (com
suporte a lambdas / ordem superior) para problemas de síntese de programas.
Este README descreve, passo a passo, tudo o que é necessário para compilar o
projeto e executá-lo de modo que ele **gere os arquivos de output**.

Resumo do que o executável faz:

1. baixa (uma única vez) o dataset do problema para `./datasets/`;
2. separa os casos em treino e teste;
3. roda a busca evolutiva (população de 1000 indivíduos, até 300.000
   avaliações, profundidade máxima da árvore 15 — hiperparâmetros fixos em
   `src/Benchmark/BenchmarkToConfig.hs`);
4. escreve o resultado em `./output/` e o estado da busca em `./checkpoint/`.

---

## 1. Pré-requisitos

| Necessidade | Detalhe |
|---|---|
| Sistema operacional | Linux ou macOS (os caminhos/ferramentas usados são POSIX) |
| GHC + cabal-install **ou** Stack | formas alternativas de build — ver seção 2 |
| `curl` | baixa os datasets (`Benchmark/Download.hs`) |
| `gzip` | descompacta os `.gz` baixados |
| `sort` (GNU coreutils) | embaralha o dataset (`sort -R`) |
| Shell POSIX (`/bin/sh`) | os comandos são executados via `System.Process.callCommand` |
| Internet | apenas na **primeira execução** de cada problema |

Verificação rápida das ferramentas externas:

```bash
which curl gzip sort sh
curl --version | head -1
gzip --version | head -1
sort --version | head -1
```

> **Importante:** os datasets vêm de
> <https://github.com/thelmuth/program-synthesis-benchmark-datasets> e são
> **embaralhados no download** (`gzip -d | sort -R`). Ou seja, o split
> treino/teste é definido no momento do download: apagar
> `./datasets/*.json` e baixar de novo gera um split diferente e muda os
> resultados.

---

## 2. Build

O projeto pode ser construído de duas formas. Qualquer uma gera o executável
`hotgp-exe`.

### Opção A — cabal (recomendada e testada neste ambiente)

Ferramentas usadas para validar este README: `cabal 3.12.1.0` + `GHC 9.6.7`
(gerenciados por ghcup).

```bash
# 1. garante que o índice de pacotes está atualizado (só na primeira vez)
cabal update

# 2. compila a biblioteca + o executável
cabal build all

# 3. (opcional) roda a suíte de testes (tasty/QuickCheck)
cabal test
```

O binário fica em
`dist-newstyle/build/x86_64-linux/ghc-<versão>/hotgp-0.1.0.0/x/hotgp-exe/build/hotgp-exe/hotgp-exe`
— mas não é preciso usar o caminho na mão, a seção 3 usa `cabal run`.

### Opção B — stack (também testada neste ambiente)

O `stack.yaml` fixa o snapshot `lts-18.18` (GHC 8.10.7). Na primeira vez o
Stack baixa esse GHC (se ainda não estiver instalado, ex. via
`ghcup install ghc 8.10.7`) e compila todas as dependências — leva bastante
tempo (a primeira build tirou ~40 pacotes do zero).

```bash
stack setup      # baixa o GHC 8.10.7, se necessário
stack build      # compila lib + hotgp-exe
stack test       # (opcional) suíte de testes
```

> **Por que há `extra-deps` no `stack.yaml`?** O snapshot `lts-18.18` traz
> `aeson-1.5.6.0`, que ainda não tem os módulos `Data.Aeson.KeyMap` /
> `Data.Aeson.Key` usados por `src/Benchmark/Parse.hs` e `src/Prune.hs`
> (foram atualizados para o estilo aeson ≥ 2.0). Por isso o
> `stack.yaml` declara `aeson-2.0.3.0` e as few versões mínimas que ele
> exige (`OneTuple`, `attoparsec`, `hashable`, `semialign`, `text-short`,
> `time-compat`). Sem esses `extra-deps` o `stack build` falha com
> `Could not find module ‘Data.Aeson.KeyMap’`.
>
> O `hotgp.cabal` é gerado a partir do `package.yaml` (hpack). O Stack o
> regenera sozinho; se você editar o `package.yaml`, rode `hpack` antes de
> usar o cabal.
>
> Outros avisos inofensivos:
> - `Specified file "ChangeLog.md" for extra-source-files does not exist` —
>   o arquivo é só metadado de empacotamento e não afeta a execução.

---

## 3. Como executar (gerar o output)

Sempre **a partir da raiz do repositório**: todos os caminhos
(`datasets/`, `output/`, `checkpoint/`) são relativos ao diretório corrente
(`app/Main.hs`, `workDir = "./"`).

### Sintaxe

```bash
# com cabal
cabal run hotgp-exe -- <nome_do_benchmark> <seed>

# com stack (as três formas abaixo são equivalentes)
stack run hotgp-exe -- <nome_do_benchmark> <seed>
stack run -- <nome_do_benchmark> <seed>
stack run <nome_do_benchmark> <seed>
```

Argumentos:

- `<nome_do_benchmark>`: um dos ids listados na seção 5 (ex.: `sum-of-squares`);
- `<seed>`: número inteiro. O par `(problema, seed)` é determinístico: a
  mesma dupla reproduz exatamente a mesma execução (inclusive ao retomar de
  checkpoint).

### Exemplo completo (passo a passo)

```bash
git clone <repositorio> hotgp
cd hotgp

# compila
cabal build all

# roda um problema com a seed 42
cabal run hotgp-exe -- sum-of-squares 42
```

O que você deve ver no terminal (a primeira execução baixa os datasets):

```
::: Downloading ./datasets/sum-of-squares-random.json :::
::: Done! ./datasets/sum-of-squares-random.json :::
::: Downloading ./datasets/sum-of-squares-edge.json :::
::: Done! ./datasets/sum-of-squares-edge.json :::
STARTING FROM SCRATCH
2026-10-01 20:54:38.123456 UTC -	1000/300000
:: CHECKPOINT ::
2026-10-01 20:55:18 UTC	43686/300000 (14.56%)
...
2026-10-01 22:11:23 UTC	300000/300000 (100.00%)
```

- a **primeira execução** baixa os dois arquivos do dataset (é preciso
  internet); nas seguintes eles são reaproveitados de `./datasets/`;
- o contador mostra as avaliações gastas / orçamento
  (300.000 = população 1000 × 300 gerações); a saída é longa (uma linha
  por passo) — use `| tee run.log` ou redirecione se quiser guardar;
- a execução **termina sozinha** ao chegar em 100% **ou** quando encontra
  uma solução perfeita (mensagem `Perfect solution found! ...`);
- duração típica: **alguns minutos** por problema (uma execução completa de
  `sum-of-squares 42` levou ~7 minutos de CPU nesta máquina; o tempo varia
  conforme a máquina e o tamanho do conjunto de treino);
- quando os 300.000 acabam, os arquivos de `./output/` são gravados e o
  processo encerra com código 0.

### Sem argumentos / argumentos inválidos

```bash
cabal run hotgp-exe
```

imprime a ajuda com a lista de benchmarks disponíveis.

---

## 4. Onde fica o output

Tudo é escrito na raiz do repositório.

### `./output/` — resultados da execução

Três arquivos, com o prefixo
`<data-hora>_s<seed>_<nome-do-problema>`:

| Arquivo | Conteúdo |
|---|---|
| `*.log.csv` | CSV com cabeçalho `time;n_evals;best_fitness;best_depth;best_node_count;best_acc;best_nmse;...` — uma linha por iteração. **Atenção:** hoje esse arquivo sai com **apenas o cabeçalho**, porque as chamadas de *logging* por iteração estão comentadas no laço principal (procure `loggingFunction` em `src/Evolution/Run.hs`: o retorno é sempre `go Nothing ...`). |
| `*.result.csv` | **Output final por caso de teste**: colunas `x0;...;y;y_hat;right` (entrada, esperado, obtido pelo programa, acertou?). Escrito ao final da execução. |
| `*.result.json` | **Resumo do melhor programa encontrado**: `datasetName`, `seed`, `totalEvals`, `fitness`, `height`, `nodeCount`, `accuracy` (fração de acertos no conjunto de teste), `nmse`, `stringRep` (programa como foi evoluído), `stringRepSimple` (após simplificação) e `showTree` (representação `show`, usada pelo pós-processamento `prune`). |

Exemplo de trecho do `.result.json`:

```json
{
    "datasetName":"sum-of-squares",
    "seed":42,
    "totalEvals":300000,
    "fitness":"6462",
    "accuracy":0.0,
    "nmse":"2.2786716e-7",
    "stringRepSimple":"...",
    "stringRep":"..."
}
```

> Os nomes de arquivo contêm espaços e dois-pontos (timestamp `show`ed) —
> use aspas ao trabalhar com eles no shell.

### `./datasets/` — dados baixados

`<nome>-random.json` e `<nome>-edge.json` para cada problema já executado.
São ignorados pelo git (`.gitignore`).

### `./checkpoint/` — estado da busca

Arquivo `s<seed>_<nome-do-problema>.checkpoint` (formato binário `flat`),
salvo a cada 1000 avaliações.

- **rodar o mesmo comando de novo retoma** de onde parou (mensagem
  `LOADING CHECKPOINT`) em vez de começar do zero. Isso vale também depois
  de uma execução **concluída**: o checkpoint salvo fica no último múltiplo
  de 1000 (ex.: 299.000 de 300.000), então um segundo
  `cabal run hotgp-exe -- sum-of-squares 42` imprime `LOADING CHECKPOINT`,
  termina em segundos e grava **um novo** conjunto de arquivos em
  `./output/` (com outro timestamp) — os antigos não são apagados;
- para **recomeçar do zero**, apague o arquivo:
  ```bash
  rm ./checkpoint/s42_sum-of-squares.checkpoint
  ```
- seeds diferentes usam checkpoints diferentes, então dá para rodar várias
  execuções em paralelo sem conflito.

### Limpeza total

```bash
rm -rf ./output ./checkpoint ./datasets
```

---

## 5. Benchmarks disponíveis

Lista idêntica à impressa pela ajuda (`Benchmark.Problems.allProblemIds`):

```
compare-string-lengths
count-odds
digits
double-letters
even-squares
for-loop-index
grade
last-index-of-zero
median
mirror-image
negative-to-zero
number-io
replace-space-with-newline
replace-space-with-newline-fst
replace-space-with-newline-snd
small-or-large
smallest
string-differences
string-lengths-backwards
sum-of-squares
syllables
vector-average
vectors-summed
wallis-pi
```

(O `collatzNumbers` existe em `src/Benchmark/Problems/CollatzNumbers.hs`, mas
está comentado em `src/Benchmark/Problems.hs` e por isso não aparece.)

Tamanho dos conjuntos (`_trainCases` / `_testCases`), definidos por problema:

| treino | teste | problemas |
|---|---|---|
| 50 | 50 | `sum-of-squares` |
| 50 | 150 | `wallis-pi` |
| 100 | 1000 | `compare-string-lengths`, `digits`, `double-letters`, `even-squares`, `for-loop-index`, `median`, `mirror-image`, `replace-space-with-newline`, `replace-space-with-newline-fst`, `replace-space-with-newline-snd`, `small-or-large`, `smallest`, `string-lengths-backwards`, `vector-average` |
| 150 | 1000 | `last-index-of-zero` |
| 150 | 1500 | `vectors-summed` |
| 200 | 2000 | `count-odds`, `grade`, `negative-to-zero`, `string-differences`, `syllables` |
| 250 | 1000 | `number-io` |

---

## 6. Pós-processamento: `prune`

Encolhe o programa encontrado removendo sub-árvores desnecessárias **sem
perder acurácia** (subida de encosta gulosa em `src/Prune.hs`).

```bash
# 1. prepare os diretórios (ambos precisam existir)
mkdir -p input-prune output-prune

# 2. copie os JSONs de resultado que você quer podar
cp "./output/2026-10-01 20:54:37.766867737 UTC_s42_sum-of-squares.result.json" input-prune/

# 3. rode (as três formas abaixo são equivalentes)
cabal run hotgp-exe -- prune
stack run prune
stack run hotgp-exe -- prune

# 4. resultado
ls output-prune/
```

Cada `output-prune/<mesmo nome>.json` recebe os campos extras
`showPrunedTree`, `stringRepPruned`, `stringRepPrunedSimple`,
`trainAccuracy`/`testAccuracy` (antes), `trainAccuracyPruned`/`testAccuracyPruned`
(depois), `heightPruned` e `nodeCountPruned`.

Obs.: o `prune` recarrega o dataset do problema (baixa de novo se você tiver
apagado `./datasets/`) — precisa de internet nesse caso.

---

## 7. Testes

```bash
cabal test          # ou: stack test
```

Suíte Tasty/QuickCheck em `test/` (`Spec.hs` agrupa Grammar, Evolution,
Benchmark, Max tree depth, Prettify Tree e Measure): **190 testes**, ~30 s.
Filtros úteis:

```bash
cabal test --test-options='--pattern Grammar'
cabal test --test-options='--quickcheck-tests 500'
```

---

## 8. Estrutura do código (mapa rápido)

```
app/Main.hs              CLI: parseia <benchmark> <seed> | prune
src/Benchmark/           Problemas, download/split do dataset, log e runner
  Problems.hs            Catálogo dos 24 benchmarks + despacho
  Problems/*.hs          Um arquivo por problema
  Download.hs            curl + gzip + sort -R → ./datasets/
  Dataset.hs             Split treino/teste (edge primeiro)
  Run.hs                 Execução ponta a ponta → ./output/
  BenchmarkToConfig.hs   Traduz Benchmark → Config (pop=1000, gens=300, depth=15)
src/Evolution/           Laço evolutivo (steady-state), operadores, checkpoint
src/Grammar/             Tipos, árvores, avaliador, pretty-print, simplificação
src/Prune.hs             Poda gulosa de programas
test/                    Testes (tasty)
```

---

## 9. Solução de problemas

| Sintoma | Causa / solução |
|---|---|
| `Invalid args!` + lista de benchmarks | Nome do problema ou seed inválidos (a seed precisa ser inteiro). |
| `curl: (6) Could not resolve host` | Sem internet — é preciso no primeiro acesso ao problema. |
| `gzip: ... not in gzip format` | Download falhou (HTML em vez de `.gz`): apague `./datasets/<nome>-*.json*` e rode de novo. |
| Diferenças entre duas execuções "iguais" | Verifique se o `.checkpoint` foi apagado ou se `./datasets/` foi rebaixado (o embaralhamento muda o split). |
| `input-prune: does not exist` (prune) | `mkdir -p input-prune output-prune` antes de rodar. |
| Quer recomeçar do zero | `rm ./checkpoint/s<seed>_<problema>.checkpoint`. |
| Quer orçamento/ profundidade diferentes | Ajuste `popSize`, `nGens` e `treeDepth` em `src/Benchmark/BenchmarkToConfig.hs` e recompile. |
