CRYSTAL_FLAGS =
BIN = bin/sebas

# Windows 工具链：MSYS make 会剥离 TMP/TEMP，native crystal/cc 拿不到可写临时目录
# （cygpath -w 给出 Windows 形式路径；POSIX 上 cygpath 不存在则回退 /tmp）
export TMP := $(shell cygpath -w /tmp 2>/dev/null || echo /tmp)
export TEMP := $(TMP)

.PHONY: build spec lint lint-build release format format-check drill clean check docs-check agents-check

build:
	@mkdir -p $(dir $(BIN))
	crystal build $(CRYSTAL_FLAGS) -o $(BIN) src/main.cr

spec:
	crystal spec

# 文档自检：死链、失效行号锚、单文件体量。只用 Ruby 标准库。
docs-check:
	ruby tools/check_docs.rb

# Agent 流程工具：策略层单测 + 文档示例与实现一致性。均不访问网络。
agents-check:
	ruby tools/test_sebas_process.rb
	ruby tools/test_sebas_process_regressions.rb
	ruby tools/test_docs_examples.rb
	ruby tools/test_oneline_sheet.rb
	ruby tools/test_backfill_script.rb
	ruby tools/test_ruby_version_guard.rb
	ruby tools/test_evidence_register.rb
	ruby tools/test_anchors_extract.rb
	ruby tools/test_coderabbit_config.rb

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
