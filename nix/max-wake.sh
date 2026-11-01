# max-wake: wakes Max in this group, from a program in the VM; Max is
# shown the text as [max-wake] …. The VM service, at the host's vsock port
# 7778, answers whether Max was woken: a group's programs wake it a few
# times an hour at most, and the rest wait. See "常驻程序" in
# docs/rust-rewrite.md.
#
#   max-wake 'CI 跑完了：挂了 2 个'
#   echo 'CI 跑完了' | max-wake

if [ $# -gt 0 ]; then
  text="$*"
else
  text=$(cat)
fi
if [ -z "${text//[[:space:]]/}" ]; then
  echo "用法：max-wake 要说的事，或者从标准输入给" >&2
  exit 2
fi
if ! answer=$(jq -cn --arg text "$text" '{wake: $text}' | socat -t 15 - VSOCK-CONNECT:2:7778); then
  echo "连不上宿主" >&2
  exit 1
fi
said=$(jq -r '.said // "宿主没有回答"' <<< "$answer")
if [ "$(jq -r '.ok' <<< "$answer")" = true ]; then
  echo "$said"
else
  echo "$said" >&2
  exit 1
fi
