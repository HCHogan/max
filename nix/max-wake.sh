# max-wake: wakes Max in this group, from a program in the VM; Max is
# shown the text as [max-wake] …. It is maxx wake, kept for the programs
# written before maxx, and prints what Max's service says: that Max was
# woken, or when it will be, since a group's programs wake it a few times
# an hour at most. See "常驻程序" in docs/rust-rewrite.md.
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
answer=$(maxx wake --text "$text") || exit
jq -r '.said' <<< "$answer"
