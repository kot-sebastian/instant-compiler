# Builds insc_jvm and insc_llvm into the project root (as required by the task).
#
#   make            build both compilers
#   make test       unit/property tests (cabal) + end-to-end tests (needs java + LLVM)
#   make unit-test  only the cabal test suite (needs no java/LLVM)
#   make e2e-test   only the end-to-end tests
#   make grammar    regenerate src/Instant/{Abs.hs,Lex.x,Par.y} from src/Instant.cf (needs bnfc)
#   make docker     build a container image with everything installed (also: make docker-test)
#   make clean      remove build artefacts

CABAL     ?= cabal
BNFC      ?= bnfc
CONTAINER ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
IMAGE     ?= instant-compiler

.PHONY: all build test unit-test e2e-test grammar docker docker-test clean

all: build

build:
	$(CABAL) build exe:insc_jvm exe:insc_llvm
	cp "$$($(CABAL) list-bin exe:insc_jvm)" insc_jvm
	cp "$$($(CABAL) list-bin exe:insc_llvm)" insc_llvm

test: unit-test e2e-test

unit-test:
	$(CABAL) test --test-show-details=direct

e2e-test: build
	test/e2e.sh

grammar:
	rm -rf .bnfc-out
	$(BNFC) --haskell -d -o .bnfc-out src/Instant.cf
	cp .bnfc-out/Instant/Abs.hs .bnfc-out/Instant/Lex.x .bnfc-out/Instant/Par.y src/Instant/
	rm -rf .bnfc-out

docker:
	$(CONTAINER) build -t $(IMAGE) .

docker-test: docker
	$(CONTAINER) run --rm $(IMAGE) make test

clean:
	$(CABAL) clean
	rm -f insc_jvm insc_llvm
