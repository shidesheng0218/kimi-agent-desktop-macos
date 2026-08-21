#!/bin/bash
# 启动配置好的 Kimi Code Agent（完整版，包含引擎）

cd "$(dirname "$0")"

# 你的 Kimi API Key（从 https://platform.moonshot.cn/ 获取）
export KIMI_API_KEY="sk-CU3evCnG8Ohf2lwY9yxjBpGlxHEs8BinIbj4XRf6k2Bd2mYX"

APP_PATH="release-native/Kimi Code Agent.app"
EXEC_PATH="$APP_PATH/Contents/MacOS/KimiCodeAgent"

if [ ! -f "$EXEC_PATH" ]; then
  echo "错误：找不到打包好的 app"
  echo "请先运行: npm run native:package"
  exit 1
fi

echo "启动 Kimi Code Agent..."
echo "API Key: ${KIMI_API_KEY:0:20}..."
echo "App 路径: $APP_PATH"

# 直接执行 app 内的二进制文件（这样能继承环境变量）
"$EXEC_PATH"
