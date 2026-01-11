.PHONY: build test workon pick-a-todo commit
build:
	dune build
test:
	dune runtest
workon:
	@cat TODO.md | mq 'include "section" nodes|split(2)|filter(fn(s): !regex_match(title(s),"DONE");)|nth(0)|all_nodes()'
pick-a-todo:
	pnpx @anthropic-ai/claude-code /pick-a-todo --permission-mode acceptEdits --model opus
commit:
	git add -u
	git commit -m wip
init:
	opam switch create . 5.4.0 --no-install -y
	opam install . --deps-only -y
