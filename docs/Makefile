.PHONY: build serve publish clean

build:
	./website.ml build

serve:
	./website.ml serve

publish: build
	@echo "Publishing to gh-pages branch..."
	@rm -rf /tmp/mach-gh-pages
	@git worktree add /tmp/mach-gh-pages gh-pages 2>/dev/null || \
		(git branch gh-pages 2>/dev/null || true; git worktree add /tmp/mach-gh-pages gh-pages)
	@cp index.html /tmp/mach-gh-pages/
	@cd /tmp/mach-gh-pages && \
		git add -A && \
		git diff --cached --quiet || git commit -m "Update website"
	@git push --force origin gh-pages
	@git worktree remove /tmp/mach-gh-pages
	@echo "Published to https://andreypopp.github.io/mach/"

clean:
	rm -f index.html
