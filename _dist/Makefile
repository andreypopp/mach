mach_lib.ml: ../lib/*.pp.ml ../lib/*.pp.mli
	@../bin/ocamlbundle $^ > $@
	@echo 'include Mach_lib' >> $@
cmdliner.ml: ../_opam/lib/cmdliner/*.ml ../_opam/lib/cmdliner/*.mli
	@../bin/ocamlbundle $^ > $@
	@echo 'include Cmdliner' >> $@
sexplib0.ml: $(filter-out %/sexplib0__.ml,$(wildcard ../_opam/lib/sexplib0/*.ml ../_opam/lib/sexplib0/*.mli))
	@../bin/ocamlbundle $^ > $@
parsexp.ml: $(filter-out %/parsexp__.ml,$(wildcard ../_opam/lib/parsexp/*.ml ../_opam/lib/parsexp/*.mli))
	@../bin/ocamlbundle $^ > $@
mach.ml: sexplib0.ml parsexp.ml mach_lib.ml cmdliner.ml ../bin/mach.ml
	@cat sexplib0.ml > $@
	@echo 'open Sexplib0' >> $@
	@cat parsexp.ml >> $@
	@echo 'open Parsexp' >> $@
	@echo 'open Sexplib0.Sexp_conv' >> $@
	@cat mach_lib.ml >> $@
	@cat cmdliner.ml >> $@
	@cat ../bin/mach.ml >> $@
mach: mach.ml
	ocamlopt -I +unix -o $@ unix.cmxa $^
.PHONY: clean
clean:
	rm -f mach mach.ml mach_lib.ml cmdliner.ml *.cmx *.cmi *.o

