CRYSTAL ?= crystal
CRYSTAL_MIN = 1.22
CRYSTAL_MIN_MAJOR = $(firstword $(subst ., ,$(CRYSTAL_MIN)))
CRYSTAL_MIN_MINOR = $(lastword $(subst ., ,$(CRYSTAL_MIN)))
CRYSTAL_FLAGS =
BIN = bin/sebas

# GNU make 取第一个非点开头的目标为默认目标。crystal-version-check 排在 build
# 前面，必须显式钉住，否则裸 `make`（或 `make CRYSTAL=...`）只跑版本检查就退出。
.DEFAULT_GOAL := build

# Windows 工具链：MSYS make 会剥离 TMP/TEMP，native crystal/cc 拿不到可写临时目录
# （cygpath -w 给出 Windows 形式路径；POSIX 上 cygpath 不存在则回退 /tmp）
export TMP := $(shell cygpath -w /tmp 2>/dev/null || echo /tmp)
export TEMP := $(TMP)

.PHONY: build spec lint lint-build release format format-check drill clean check docs-check agents-check crystal-version-check

# src/platform/keys/vault.cr 依赖 OpenSSL::Cipher#gcm_tag，该 API 自 Crystal
# 1.22.0 才进入 stdlib。旧版会把错误推迟到编译期才报 undefined method，
# 且失败面取决于编译文件集（不 require keys 的 spec 子集能过），这里提前拦截。
# 版本号按 major.minor 两段整数比较，不依赖 sort -V（BSD sort 没有）。
crystal-version-check:
	@version=$$("$(CRYSTAL)" --version 2>&1 | sed -n 's/^Crystal \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -1); \
	set -- $$version; \
	if [ -z "$$1" ]; then \
		echo "错误：执行 $(CRYSTAL) --version 失败。需要 Crystal >= $(CRYSTAL_MIN)，见 docs/design/process/quickstart.md §1.1" >&2; \
		exit 1; \
	fi; \
	if [ "$$1" -lt "$(CRYSTAL_MIN_MAJOR)" ] || \
	   { [ "$$1" -eq "$(CRYSTAL_MIN_MAJOR)" ] && [ "$$2" -lt "$(CRYSTAL_MIN_MINOR)" ]; }; then \
		echo "错误：当前 Crystal $$1.$$2 低于 $(CRYSTAL_MIN)，编译会在 src/platform/keys/vault.cr 报 undefined method 'gcm_tag'。" >&2; \
		echo "升级：brew upgrade crystal，或用 mise（见 docs/design/process/quickstart.md §1.1）。" >&2; \
		echo "也可临时指定：make CRYSTAL=/path/to/crystal。" >&2; \
		exit 1; \
	fi

build: crystal-version-check
	@mkdir -p $(dir $(BIN))
	"$(CRYSTAL)" build $(CRYSTAL_FLAGS) -o $(BIN) src/main.cr

spec: crystal-version-check
	"$(CRYSTAL)" spec

# 文档自检：死链、失效行号锚、单文件体量。只用 Ruby 标准库。
docs-check:
	ruby tools/check_docs.rb

# Agent 流程工具：策略层单测 + 文档示例与实现一致性。均不访问网络。
# 测试清单由 tools/tests/ 的目录结构推导（tools/tests/run.rb），
# 新增测试文件不需要再改本目标，也不会因为漏改而静默不跑。
agents-check:
	ruby tools/tests/run.rb

# ameba 是 development dependency；未构建时先构建，再运行
lint: lint-build
	./bin/ameba

lint-build: crystal-version-check
	@mkdir -p bin
	"$(CRYSTAL)" build -o bin/ameba lib/ameba/bin/ameba.cr

release: crystal-version-check
	@mkdir -p $(dir $(BIN))
	"$(CRYSTAL)" build --release --progress -o $(BIN) src/main.cr

# M0-WP8 强杀演练：构建 release 后跑门禁演练 spec（taskkill /F ≈ SIGKILL 口径）
drill: release
	"$(CRYSTAL)" spec spec/platform/cli/gateway_spec.cr

format:
	"$(CRYSTAL)" tool format

format-check: crystal-version-check
	"$(CRYSTAL)" tool format --check

# 与 CI 对齐的三道门禁
check: format-check spec lint

clean:
	rm -rf bin lib .shards
