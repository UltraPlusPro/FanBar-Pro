#!/bin/bash
# 双击即编译：产出 build/FanBar Pro.app
cd "$(dirname "$0")" || exit 1
./脚本/构建-FanBar-Pro.command "$@"
status=$?
echo
if [ "${status}" -ne 0 ]; then
    echo "构建失败（退出码 ${status}），请把上面的报错发我。"
fi
read -n 1 -s -r -p "按任意键关闭窗口…"
echo
exit "${status}"
