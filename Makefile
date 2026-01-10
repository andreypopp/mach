workon:
	@cat TODO.md | mq 'include "section" nodes|split(2)|filter(fn(s): !regex_match(title(s),"DONE");)|nth(0)|all_nodes()'

pick-a-todo:
	pnpx @anthropic-ai/claude-code /pick-a-todo --permission-mode acceptEdits --model opus

commit:
	git add -u
	git commit -m wip
