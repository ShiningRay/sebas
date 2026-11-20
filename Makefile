CRYSTAL_FLAGS =
BIN = bin/sebas

# Windows 工具链：MSYS make 会剥离 TMP/TEMP，native crystal/cc 拿不到可写临时目录
# （cygpath -w 给出 Windows 形式路径；POSIX 上 cygpath 不存在则回退 /tmp）
export TMP := $(shell cygpath -w /tmp 2>/dev/null || echo /tmp)
export TEMP := $(TMP)

.PHONY: build spec lint lint-build release format format-check drill clean check docs-check

build:
	@mkdir -p $(dir $(BIN))
	crystal build $(CRYSTAL_FLAGS) -o $(BIN) src/main.cr

spec:
	crystal spec

# 文档自检：死链、失效行号锚、单文件体量。只用 python 标准库。
docs-check:
	python3 tools/check_docs.py

# ameba 是 development dependency；未构建时先构建，再运行
lint: lint-build
	./bin/ameba

lint-build:
	@mkdir -p bin
	crystal build -o bin/ameba lib/ameba/bin/ameba.cr

release:
	@mkdir -p $(dir $(BIN))
	crystal build --release --progress -o $(BIN) src/main.cr

# M0-WP8 强杀演练：构建 release 后跑门禁演练 spec（taskkill /F ≈ SIGKILL 口径）
drill: release
	crystal spec spec/platform/cli/gateway_spec.cr

format:
	crystal tool format

format-check:
	crystal tool format --check

# 与 CI 对齐的三道门禁
check: format-check spec lint

clean:
	rm -rf bin lib .shards
