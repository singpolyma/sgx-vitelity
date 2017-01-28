GHCFLAGS=-Wall -fno-warn-name-shadowing -XHaskell2010 -O2
HLINTFLAGS=-XHaskell98 -XCPP -i 'Use camelCase' -i 'Use String' -i 'Use head' -i 'Use string literal' -i 'Use list comprehension' --utf8
VERSION=0.6

.PHONY: all shell clean doc install

all: report.html doc dist/build/libHSsgx-vitelity-$(VERSION).a dist/sgx-vitelity-$(VERSION).tar.gz

install: dist/build/libHSsgx-vitelity-$(VERSION).a
	cabal install

shell:
	ghci $(GHCFLAGS)

report.html: gateway.lhs
	-hlint $(HLINTFLAGS) --report $^

doc: dist/doc/html/sgx-vitelity/index.html README

README: sgx-vitelity.cabal
	tail -n+$$(( `grep -n ^description: $^ | head -n1 | cut -d: -f1` + 1 )) $^ > .$@
	head -n+$$(( `grep -n ^$$ .$@ | head -n1 | cut -d: -f1` - 1 )) .$@ > $@
	-printf ',s/        //g\n,s/^.$$//g\n,s/\\\\\\//\\//g\nw\nq\n' | ed $@
	$(RM) .$@

dist/doc/html/sgx-vitelity/index.html: dist/setup-config gateway.lhs
	cabal haddock --hyperlink-source

dist/setup-config: sgx-vitelity.cabal
	cabal configure

clean:
	find -name '*.o' -o -name '*.hi' | xargs $(RM)
	$(RM) -r dist

dist/build/libHSsgx-vitelity-$(VERSION).a: dist/setup-config gateway.lhs
	cabal build --ghc-options="$(GHCFLAGS)"

dist/sgx-vitelity-$(VERSION).tar.gz: README dist/setup-config gateway.lhs
	cabal check
	cabal sdist
