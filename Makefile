CRYSTAL_FLAGS =
BIN = bin/sebas

.PHONY: build spec lint release format clean

build:
	@mkdir -p $(dir $(BIN))
	crystal build $(CRYSTAL_FLAGS) -o $(BIN) src/main.cr

spec:
	crystal spec

lint:
	./bin/ameba

release:
	@mkdir -p $(dir $(BIN))
	crystal build --release --progress -o $(BIN) src/main.cr

format:
	crystal tool format

clean:
	rm -rf bin lib .shards
