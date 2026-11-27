# 非 StandardError 异常：装载包装 rescue 不到，走真实崩溃路径（exit 非零）
raise Exception.new("hard crash")
