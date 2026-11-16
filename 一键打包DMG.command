#!/bin/bash
# 双击即打包：编译 + 组装 + 签名 + 产出 DMG（落在 build/）
cd "$(dirname "$0")" || exit 1
./脚本/构建-FanBar-Pro.command --dmg "$@"
status=$?
echo
if [ "${status}" -ne 0 ]; then
    echo "打包失败（退出码 ${status}），请把上面的报错发我。"
fi
read -n 1 -s -r -p "按任意键关闭窗口…"
echo
exit "${status}"
