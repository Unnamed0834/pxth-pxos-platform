.PHONY: all verify test format

all: verify test

verify:
	./tools/check-repo.sh

test:
	python3 -m unittest discover -s tests/fleet -q

format:
	nixfmt $$(find . -name '*.nix' -not -path './.git/*')
