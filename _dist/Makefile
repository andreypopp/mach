mach_lib.ml: ../lib/*.ml ../lib/*.mli
	@../_bin/ocamlbundle $^ > $@
	@echo 'include Mach_lib' >> $@
cmdliner.ml: ../_opam/lib/cmdliner/*.ml ../_opam/lib/cmdliner/*.mli
	@../_bin/ocamlbundle $^ > $@
	@echo 'include Cmdliner' >> $@
mach.ml: mach_lib.ml cmdliner.ml ../bin/mach.ml
	@../_bin/ocamlbundle $^ > $@
mach: mach.ml
	ocamlopt -I +unix -o $@ unix.cmxa $^
.PHONY: clean
clean:
	rm -f mach mach.ml mach_lib.ml cmdliner.ml *.cmx *.cmi *.o

