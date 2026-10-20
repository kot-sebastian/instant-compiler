# Instant Compiler

[English](README.md) | **Polski**

Kompilator języka **Instant** do **JVM** (asembler Jasmin → `.class`) oraz **LLVM** (`.ll` → `.bc`),
napisany w Haskellu. Projekt zaliczeniowy z MRJP (treść zadania: [`[PL]task-description.pdf`](%5BPL%5Dtask-description.pdf)).

```text
x = 2 + 3 * 4;      ← przypisanie: nic nie wypisuje
x - 1;              ← wyrażenie: wypisuje 13
(x - 4) / 2         ← wypisuje 5
```

- [Szybki start](#szybki-start)
- [Wymagania](#wymagania)
- [Budowanie](#budowanie)
- [Użycie](#użycie)
- [Testy](#testy)
- [Uruchamianie w kontenerze (bez instalowania GHC)](#uruchamianie-w-kontenerze-bez-instalowania-ghc)
- [Jak to działa](#jak-to-działa)
- [Struktura katalogów](#struktura-katalogów)
- [Rozwiązywanie problemów](#rozwiązywanie-problemów)

## Szybki start

```bash
make                                   # buduje ./insc_jvm i ./insc_llvm
./insc_jvm test/programs/basic.ins     # → test/programs/basic.j + basic.class
java -cp test/programs basic
./insc_llvm test/programs/basic.ins    # → test/programs/basic.ll + basic.bc
lli test/programs/basic.bc
```

Nie masz GHC? Zobacz [Uruchamianie w kontenerze](#uruchamianie-w-kontenerze-bez-instalowania-ghc).

## Wymagania

| Narzędzie | Do czego | Wersja testowana |
|-----------|----------|------------------|
| GHC + `cabal` (≥ 3.4) | budowanie kompilatora | GHC 9.10, 9.12; cabal 3.12, 3.14 |
| Java (JRE/JDK) | uruchamianie Jasmina (`lib/jasmin.jar`) i wynikowych `.class` | OpenJDK 17, 25 |
| LLVM: `llvm-link`, `lli` | linkowanie z `lib/runtime.bc` i uruchamianie `.bc` | LLVM 14, 22 |
| `make`, `bash` | Makefile i testy end-to-end | – |

`alex` i `happy` (generatory leksera/parsera) **nie muszą być zainstalowane** – cabal zbuduje je sam
(`build-tool-depends`). `bnfc` potrzebny jest tylko przy zmianie gramatyki (`make grammar`).

Instalacja narzędzi:

```bash
# Fedora
sudo dnf install ghc cabal-install llvm java-25-openjdk-headless make
```

```bash
# Debian / Ubuntu
sudo apt install ghc cabal-install llvm default-jdk-headless make
```

```bash
# Dowolny Linux / macOS – oficjalny instalator GHCup (https://www.haskell.org/ghcup/)
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```

Po instalacji cabala jednorazowo: `cabal update`.

## Budowanie

```bash
make          # = make build: cabal build + skopiowanie insc_jvm i insc_llvm do katalogu głównego
make clean    # usuwa dist-newstyle/ oraz insc_jvm, insc_llvm
```

Pierwsze budowanie pobiera zależności z Hackage (w tym alex/happy), więc trwa kilka minut;
kolejne – kilka sekund.

Biblioteki Haskella (poza `base`): `array` (kod wygenerowany przez alex/happy), `containers` (mapy
zmiennych), `mtl` (monady `State`/`ExceptT`), `filepath`, `directory`, `process` (sterownik:
ścieżki, pliki, wywoływanie Jasmina/llvm-link). Testy dodatkowo używają `QuickCheck`.

## Użycie

```text
insc_jvm  [--emit-only] PLIK.ins...
insc_llvm [--emit-only] PLIK.ins...
```

| Polecenie | Wynik (w katalogu pliku wejściowego) |
|-----------|--------------------------------------|
| `./insc_jvm foo/bar/baz.ins` | `foo/bar/baz.j` (Jasmin) i `foo/bar/baz.class` |
| `./insc_llvm foo/bar/baz.ins` | `foo/bar/baz.ll` (tekstowe LLVM IR) i `foo/bar/baz.bc` (bitkod z dolinkowanym runtime) |
| `--emit-only` | tylko `.j` / `.ll`, bez uruchamiania Javy/LLVM (przydatne, gdy ich nie ma) |
| `-h`, `--help` | pomoc |

Uruchomienie wyniku:

```bash
java -cp foo/bar baz     # JVM
lli foo/bar/baz.bc       # LLVM
```

Można podać wiele plików naraz – każdy jest kompilowany niezależnie. Kod wyjścia jest `0` tylko
wtedy, gdy wszystkie się skompilowały; błędy trafiają na stderr, np.:

```text
prog.ins: statement 2: variable 'z' is used before being assigned
prog.ins: parse error: syntax error at line 2, column 4 before `*'
```

Zmienne środowiskowe:

| Zmienna | Znaczenie |
|---------|-----------|
| `INSTANT_LIB_DIR` | katalog z `jasmin.jar` / `runtime.bc`. Domyślnie szukany jest kolejno: `lib/` obok pliku wykonywalnego (układ po `make`), katalog danych z `cabal install`, `./lib` |
| `JAVA` | polecenie Javy (domyślnie `java`) |
| `LLVM_LINK` | polecenie llvm-link (domyślnie `llvm-link`) |

Kompilatory można też uruchamiać bez `make`, przez cabala (z katalogu głównego projektu):

```bash
cabal run insc_jvm -- test/programs/basic.ins
```

## Testy

```bash
make test         # wszystko: unit-test + e2e-test
make unit-test    # cabal test – nie wymaga Javy ani LLVM
make e2e-test     # buduje kompilatory i uruchamia test/e2e.sh (wymaga java, llvm-link, lli)
```

- **`test/Spec.hs`** (`cabal test`) – testy jednostkowe (parser, łączność operatorów, błędy,
  wybór instrukcji JVM, wyjście LLVM) oraz testy własności QuickCheck na losowych programach.
  Wygenerowany kod jest *wykonywany* przez symulator stosu JVM i interpreter emitowanego LLVM IR,
  a wynik porównywany z interpreterem referencyjnym (arytmetyka 32-bitowa). Sprawdzane jest też, że
  `.limit stack` jest dokładnie równy maksymalnej głębokości stosu podczas wykonania i jest optymalny.
- **`test/e2e.sh`** – kompiluje każdy `test/programs/*.ins` oboma kompilatorami, uruchamia przez
  `java`/`lli` i porównuje z `*.output`; sprawdza, że programy z `test/bad/` są odrzucane; kompiluje
  duży wygenerowany program (300 zmiennych, wyrażenie o głębokości 1000) i sprawdza zgodność JVM/LLVM;
  mierzy czas kompilacji programu z 200 000 instrukcji (złożoność).

Dodanie testu: wrzuć `nazwa.ins` i oczekiwane wyjście `nazwa.output` do `test/programs/`.

## Uruchamianie w kontenerze (bez instalowania GHC)

`Dockerfile` zawiera komplet narzędzi (GHC, cabal, JDK, LLVM). Działa z Dockerem i Podmanem
(`make` sam wybiera `podman`, jeśli jest dostępny; można wymusić `make docker CONTAINER=docker`).

```bash
make docker          # buduje obraz instant-compiler ze skompilowanymi insc_jvm/insc_llvm
make docker-test     # buduje obraz i uruchamia w nim make test
```

To samo bez `make` na hoście (wystarczy Podman lub Docker):

```bash
podman build -t instant-compiler .
```

```bash
podman run --rm instant-compiler make test
```

Kompilacja własnych programów z katalogu `./progs` przy użyciu obrazu:

```bash
podman run --rm -v "$PWD/progs:/data:Z" instant-compiler sh -c 'insc_jvm /data/prog.ins && java -cp /data prog'
```

```bash
podman run --rm -v "$PWD/progs:/data:Z" instant-compiler sh -c 'insc_llvm /data/prog.ins && lli /data/prog.bc'
```

Praca nad kodem bez lokalnego GHC – sam etap `toolchain` obrazu i katalog projektu zamontowany
w kontenerze (wolumen `instant-cabal` przechowuje pobrane zależności między uruchomieniami):

```bash
podman build --target toolchain -t instant-toolchain .
```

```bash
podman run --rm -it -v instant-cabal:/root/.local/state/cabal -v "$PWD:/src:Z" -w /src instant-toolchain make test
```

## Jak to działa

```text
             ┌───────────────── Compiler.Frontend ─────────────────┐
 plik.ins →  │ lekser/parser (BNFC) → kontrola zmiennych i literałów │ → Program (AST)
             └───────────────────────────────────────────────────────┘
                     │                                    │
          Compiler.Backend.JVM                  Compiler.Backend.LLVM
     Method {stack, locals, [Instr]}             SSA: %1, %2, ...
                     │                                    │
   plik.j → Jasmin → plik.class        plik.ll → llvm-link (+ lib/runtime.bc) → plik.bc
```

**Frontend** (`Compiler.Frontend`) – parsuje i odrzuca programy, których nie da się poprawnie
skompilować: użycie zmiennej przed przypisaniem oraz literały > 2³¹−1.

**JVM** (`Compiler.Backend.JVM`):
- kolejność obliczania podwyrażeń wg **Sethiego–Ullmana**: najpierw liczone jest poddrzewo wymagające
  głębszego stosu, więc zadeklarowany `.limit stack` jest minimalny (sprawdzane w testach);
- `swap` tylko tam, gdzie zmieniono kolejność argumentów operatora nieprzemiennego (`-`, `/`);
  `+` i `*` traktowane są jako przemienne, zgodnie z treścią zadania;
- przy wypisywaniu: dla wyrażenia o głębokości 1 najpierw `getstatic System.out` (bez `swap`),
  dla głębszych – najpierw wyrażenie, potem `getstatic` + `swap` (stos nie rośnie);
- najkrótsze instrukcje: `iconst_m1..5`, `bipush`, `sipush`, `ldc`, `iload_0..3`/`istore_0..3`;
- `.limit locals` = 1 (`args`) + liczba zmiennych.

**LLVM** (`Compiler.Backend.LLVM`) – każda wartość pośrednia trafia do nowego rejestru SSA, a zmienna
wiąże się z rejestrem przechowującym jej wartość, więc nie są potrzebne `alloca`/`load`/`store`.
Przypisanie stałej (`x = 5`) generuje jawną instrukcję `add i32 0, 5` – zgodnie z treścią zadania
żadne operacje nie są pomijane ani zwijane (brak constant folding). `printInt` pochodzi z
`lib/runtime.bc`.

**Złożoność** – wszystkie przebiegi są liniowe (listy różnicowe przy sklejaniu kodu, `Data.Map`
dla zmiennych → O(n log n)). Zadanie wymaga co najwyżej O(n log n).

## Struktura katalogów

```text
.
├── Makefile             make / make test / make clean / make grammar / make docker
├── instant.cabal        definicja pakietu: biblioteka, insc_jvm, insc_llvm, testy
├── Dockerfile           środowisko z GHC, JDK i LLVM
├── app/
│   ├── insc_jvm.hs      main: frontend → backend JVM → Jasmin
│   └── insc_llvm.hs     main: frontend → backend LLVM → llvm-link
├── src/
│   ├── Instant.cf       gramatyka języka (BNFC)
│   ├── Instant/         wygenerowane przez BNFC (make grammar): Abs.hs, Lex.x (alex), Par.y (happy)
│   └── Compiler/
│       ├── Syntax.hs    widok na AST wspólny dla backendów (operatory binarne, przemienność)
│       ├── Frontend.hs  parsowanie + kontrola zmiennych i zakresu literałów
│       ├── Driver.hs    CLI wspólne dla obu kompilatorów: pliki, błędy, szukanie lib/, narzędzia
│       └── Backend/
│           ├── JVM.hs   generowanie kodu Jasmin
│           └── LLVM.hs  generowanie LLVM IR
├── lib/
│   ├── jasmin.jar       asembler Jasmin
│   └── runtime.bc       runtime LLVM (printInt)
└── test/
    ├── Spec.hs          testy jednostkowe i QuickCheck (cabal test)
    ├── e2e.sh           testy end-to-end (java, lli)
    ├── programs/        programy testowe *.ins + oczekiwane wyjście *.output
    └── bad/             programy, które muszą zostać odrzucone
```

Zmiana gramatyki: edytuj `src/Instant.cf` i uruchom `make grammar` (wymaga `bnfc`, np.
`cabal install BNFC`). Pliki `.x`/`.y` są przetwarzane przez alex/happy automatycznie podczas
budowania, więc pasują do każdej wersji GHC (wcześniej w repozytorium leżał wygenerowany kod `.hs`,
który kompilował się tylko na GHC 8.4).

## Rozwiązywanie problemów

| Problem | Rozwiązanie |
|---------|-------------|
| `cannot find jasmin.jar; looked in: ...` | uruchamiasz plik wykonywalny spoza projektu – ustaw `INSTANT_LIB_DIR=/ścieżka/do/projektu/lib` |
| `cannot run llvm-link` / `cannot run java` | zainstaluj LLVM / Javę albo wskaż je przez `LLVM_LINK` / `JAVA`; ewentualnie użyj `--emit-only` |
| `cabal: unrecognised command: list-bin` | za stary cabal (< 3.4) – zaktualizuj (`ghcup install cabal`) |
| `java.lang.ClassFormatError: Invalid method Code length` | program jest za duży dla JVM (limit 64 KB bajtkodu na metodę) – to ograniczenie platformy, wersja LLVM działa |
| Błąd przy wczytywaniu `runtime.bc` w nowym LLVM | bitkod jest wstecznie kompatybilny (sprawdzone na LLVM 14 i 22); gdyby jednak nie zadziałał – wygeneruj go z własnego `runtime.ll` (`llvm-as runtime.ll -o lib/runtime.bc`) |
| `file name 'my-prog' is not a valid JVM class name` | klasa nazywa się jak plik, więc nazwa pliku musi być identyfikatorem Javy (litery, cyfry, `_`, `$`) – zmień nazwę, np. na `my_prog.ins` (dotyczy tylko `insc_jvm`) |
