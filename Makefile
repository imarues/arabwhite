SHELL := /bin/bash

.PHONY: all verify generate build clean

all: build

verify:
	python3 tools/verify_translations.py

generate:
	python3 tools/generate_translations.py

build: verify generate
	./build.sh

clean:
	rm -rf build coverage-report.txt
