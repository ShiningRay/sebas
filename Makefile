CRYSTAL_FLAGS =
BIN = bin/sebas

# Windows 工具链：MSYS make 会剥离 TMP/TEMP，native crystal/cc 拿不到可写临时目录
# （cygpath -w 给出 Windows 形式路径；POSIX 上 cygpath 不存在则回退 /tmp）
export TMP := $(shell cygpath -w /tmp 2>/dev/null || echo /tmp)
export TEMP := $(TMP)

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
