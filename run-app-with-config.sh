#!/bin/bash
# 启动配置好的 Kimi Code Agent（完整版，包含引擎）

cd "$(dirname "$0")"

# 从环境变量读取 Kimi API Key（从 https://platform.moonshot.cn/ 获取）。
# 不要把真实 Key 写进本文件：它会被提交进 git。用法：
#   KIMI_API_KEY="sk-..." ./run-app-with-config.sh
if [ -z "$KIMI_API_KEY" ]; then
  echo "错误：未设置 KIMI_API_KEY 环境变量"
  echo "用法: KIMI_API_KEY=\"sk-...\" $0"
  exit 1
fi

APP_PATH="release-native/Kimi Code Agent.app"
EXEC_PATH="$APP_PATH/Contents/MacOS/KimiCodeAgent"

if [ ! -f "$EXEC_PATH" ]; then
  echo "错误：找不到打包好的 app"
  echo "请先运行: npm run native:package"
  exit 1
fi

echo "启动 Kimi Code Agent..."
echo "App 路径: $APP_PATH"

# 直接执行 app 内的二进制文件（这样能继承环境变量）
"$EXEC_PATH"
