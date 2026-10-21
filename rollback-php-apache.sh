#!/usr/bin/env bash
# ============================================================================
# rollback-php-apache.sh —— 回滚因 `apt[-get] upgrade php` 误装的 php + apache2 栈
#
# 只处理 php / apache2 / libapache2-mod-php 及其专属依赖；
# docker、tailscale 等被顺带“升级”的包不在范围内（那是版本替换，只能降级）。
# 依赖：bash + coreutils + gawk/mawk + dpkg + apt（不需要 python3）
#
# 用法：
#   ./rollback-php-apache.sh                   干跑：只报告计划，不做任何改动
#   ./rollback-php-apache.sh --apply           真正执行回滚
#   ./rollback-php-apache.sh --hours 48        扩大回看窗口（默认最近 24 小时）
#   ./rollback-php-apache.sh --purge-libs      连专属依赖库（libapr*/libsodium23 等）一起删
#   ./rollback-php-apache.sh --force           跳过“非默认站点/业务 php 文件”的安全拦截
#   ./rollback-php-apache.sh --from-installed  忽略 history，直接以当前已装 php/apache 为准
#
# 退出码：0 成功/本来就没有  1 需人工确认(窗口内无记录但当前已装)  2 参数错误
#         3 被安全检查拦截  4 执行失败
# ============================================================================
set -uo pipefail
export LC_ALL=C

APPLY=0; FORCE=0; PURGE_LIBS=0; FROM_INSTALLED=0; HOURS=24

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)          APPLY=1 ;;
    --force)          FORCE=1 ;;
    --purge-libs)     PURGE_LIBS=1 ;;
    --from-installed) FROM_INSTALLED=1 ;;
    --hours)          HOURS="${2:?--hours 需要一个整数}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "未知参数：$1（-h 看用法）" >&2; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || { echo "错误：需要 root 运行" >&2; exit 1; }
case "$HOURS" in ''|*[!0-9]*) echo "错误：--hours 必须是正整数" >&2; exit 1 ;; esac

TS=$(date +%Y%m%d-%H%M%S)
LOG="/var/log/php-apache-rollback-$TS.log"
exec > >(tee -a "$LOG") 2>&1

echo "=========================================================================="
echo " php/apache 回滚脚本   $TS"
echo " 模式：$([ "$APPLY" -eq 1 ] && echo '执行(--apply)' || echo '干跑(不改动)')   窗口：最近 ${HOURS} 小时"
echo " 日志：$LOG"
echo "=========================================================================="

CUTOFF=$(date -d "-${HOURS} hours" +"%Y-%m-%d %H:%M:%S")

# ---------------------------------------------------------------------------
# 1. 解析 /var/log/apt/history.log*（纯 awk，无外部依赖）
#    输出行：hit<TAB>日期<TAB>命令<TAB>该笔包数 / cand<TAB>包名 / candlib / prior
# ---------------------------------------------------------------------------
echo
echo "[1/5] 解析 apt 历史（窗口起点 $CUTOFF）"
PARSED=$(
  { cat /var/log/apt/history.log 2>/dev/null
    for g in /var/log/apt/history.log.*.gz; do [ -e "$g" ] && gzip -dc "$g" 2>/dev/null; done
  } | awk -v CUT="$CUTOFF" '
    BEGIN { RS = ""; FS = "\n" }
    {
      d = ""; cmd = ""; ins = ""
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^Start-Date:/)       { sub(/^Start-Date:[ \t]*/, "", line);   d = line }
        else if (line ~ /^Commandline:/) { sub(/^Commandline:[ \t]*/, "", line); cmd = line }
        else if (line ~ /^Install:/)     { sub(/^Install:[ \t]*/, "", line);     ins = line }
      }
      if (d == "") next
      gsub(/[ \t]+/, " ", d)
      n = 0
      if (ins != "") n = split(ins, a, "),")
      if (d >= CUT) {
        core = 0
        for (j = 1; j <= n; j++) {
          p = a[j]
          sub(/\(.*/, "", p); sub(/:.*/, "", p); gsub(/^[ \t]+|[ \t]+$/, "", p)
          if (p == "") continue
          if (p ~ /^(php|libapache2-mod-php|apache2)([0-9]|$|-)/)    { print "cand\t" p; core = 1 }
          else if (p ~ /^(libapr|libsodium|liblua5\.4|libargon2|ssl-cert|psmisc)/) print "candlib\t" p
        }
        if (core) print "hit\t" d "\t" cmd "\t" n
      } else {
        for (j = 1; j <= n; j++) {
          p = a[j]
          sub(/\(.*/, "", p); sub(/:.*/, "", p); gsub(/^[ \t]+|[ \t]+$/, "", p)
          if (p ~ /^(php|libapache2-mod-php|apache2)([0-9]|$|-)/) { print "prior\t1"; break }
        }
      }
    }'
)

CAND=$(printf '%s\n' "$PARSED" | awk -F'\t' '$1=="cand"{print $2}' | sort -u | tr '\n' ' ')
CANDLIB=$(printf '%s\n' "$PARSED" | awk -F'\t' '$1=="candlib"{print $2}' | sort -u | tr '\n' ' ')
printf '%s\n' "$PARSED" | awk -F'\t' '$1=="hit"{printf "  · %s  %s  (该笔共装 %s 个)\n", $2, $3, $4}'
PRIOR=$(printf '%s\n' "$PARSED" | awk -F'\t' '$1=="prior"{print 1; exit}')
PRIOR=${PRIOR:-0}
[ -n "${CAND// /}" ] || echo "  （窗口内没有 php/apache 的安装记录）"

# ---------------------------------------------------------------------------
# 2. 与实际已装状态求交集
# ---------------------------------------------------------------------------
echo
echo "[2/5] 对照当前已装状态"
INSTALLED=$(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 2>/dev/null | awk '$2 ~ /^ii/{print $1}')
CUR=$(printf '%s\n' "$INSTALLED" | grep -E '^(php|apache2|libapache2-mod-php)' || true)

CORE_LIST=""; LIB_LIST=""
for p in $CAND; do
  printf '%s\n' "$INSTALLED" | grep -qx "$p" && CORE_LIST="$CORE_LIST $p"
done
for p in $CANDLIB; do
  printf '%s\n' "$INSTALLED" | grep -qx "$p" && LIB_LIST="$LIB_LIST $p"
done

if [ -z "${CORE_LIST// /}" ] && [ "$FROM_INSTALLED" -eq 1 ]; then
  for p in $CUR; do CORE_LIST="$CORE_LIST $p"; done
  echo "  · 已按 --from-installed 以当前已装集合为准"
fi
CORE_LIST="${CORE_LIST# }"; LIB_LIST="${LIB_LIST# }"

if [ -n "$PRIOR" ] && [ "$PRIOR" -eq 1 ] && [ -n "$CORE_LIST" ]; then
  echo "  ! 窗口之前的历史里也有过 php/apache 安装：若这台机原本就跑 php 站点，purge 会删业务。"
fi

if [ -z "${CORE_LIST// /}" ]; then
  if [ -z "${CUR// /}" ]; then
    echo "  ✓ 当前没有任何 php/apache 包在装。"
    echo; echo "结论：无需操作。"; exit 0
  fi
  echo "  ! 窗口内没找到安装记录，但当前已装："
  printf '      %s\n' $CUR
  echo "  确认这些确实是误装的，加 --from-installed 再跑一次。"
  exit 1
fi

echo "  · 将 purge（php/apache 本体）："
printf '      %s\n' $CORE_LIST
if [ -n "${LIB_LIST// /}" ]; then
  echo "  · 专属依赖库（默认不动；加 --purge-libs 时只删“无反向依赖”的）："
  printf '      %s\n' $LIB_LIST
fi

# ---------------------------------------------------------------------------
# 3. 安全检查
# ---------------------------------------------------------------------------
echo
echo "[3/5] 安全检查"
BLOCK=0
if [ -d /etc/apache2/sites-enabled ]; then
  EXTRA=$(ls /etc/apache2/sites-enabled/*.conf 2>/dev/null | grep -v '/000-default\.conf$' || true)
  if [ -n "$EXTRA" ]; then
    echo "  ✗ 存在非默认 vhost（可能真配过站点）："
    printf '      %s\n' $EXTRA
    BLOCK=1
  fi
fi
PHPFILES=$(find /var/www -type f -name '*.php' 2>/dev/null | head -5)
if [ -n "$PHPFILES" ]; then
  echo "  ✗ /var/www 下存在 php 业务文件："
  printf '      %s\n' $PHPFILES
  BLOCK=1
fi
POOLS=$(ls /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | grep -v '/www\.conf$' || true)
if [ -n "$POOLS" ]; then
  echo "  ✗ 存在自定义 php-fpm pool："
  printf '      %s\n' $POOLS
  BLOCK=1
fi
if [ "$BLOCK" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  echo "  中止：疑似有业务在用。确认不是后加 --force 重跑。"
  exit 3
fi
[ "$BLOCK" -eq 0 ] && echo "  ✓ 未发现真实站点或业务 php 文件（只有默认页）"

# ---------------------------------------------------------------------------
# 4. 干跑 / 执行
# ---------------------------------------------------------------------------
echo
echo "[4/5] 干跑 purge 计划"
apt-get -s purge $CORE_LIST 2>&1 | sed -n '/will be REMOVED\|newly installed\|upgraded,/,$p' | sed 's/^/  /'

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "干跑结束，未做任何改动。确认无误后重跑：$0 --apply"
  exit 0
fi

echo
echo "  执行：DEBIAN_FRONTEND=noninteractive apt-get purge -y $CORE_LIST"
DEBIAN_FRONTEND=noninteractive apt-get purge -y $CORE_LIST
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "  ✗ apt-get purge 失败（退出码 $RC）"
  exit 4
fi

if [ "$PURGE_LIBS" -eq 1 ] && [ -n "${LIB_LIST// /}" ]; then
  echo
  echo "  评估专属依赖库（迭代，只删反向依赖为空的）："
  PENDING="$LIB_LIST"
  for pass in 1 2 3; do
    [ -n "${PENDING// /}" ] || break
    ORPH=""; NEXT=""
    for p in $PENDING; do
      dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' || continue
      rd=$(apt-cache rdepends --installed "$p" 2>/dev/null | tail -n +3 | sed 's/^[ |]*//' | grep -cv '^$')
      if [ "$rd" -eq 0 ]; then ORPH="$ORPH $p"; else NEXT="$NEXT $p"; fi
    done
    [ -n "${ORPH// /}" ] || { echo "      第 $pass 轮：剩余均仍被别的包依赖，保留"; break; }
    echo "      第 $pass 轮删除：${ORPH# }"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y $ORPH || exit 4
    PENDING="${NEXT# }"
  done
  [ -n "${PENDING// /}" ] && { echo "      最终保留：$PENDING"; true; }
fi

# ---------------------------------------------------------------------------
# 5. 验收
# ---------------------------------------------------------------------------
echo
echo "[5/5] 验收"
LEFT=$(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 2>/dev/null \
       | awk '$2 ~ /^ii/ && $1 ~ /^(php|apache2|libapache2-mod-php)/{print $1}' | tr '\n' ' ')
if [ -z "${LEFT// /}" ]; then
  echo "  ✓ 已无 php/apache 包"
else
  echo "  ! 仍有残留：$LEFT"
fi

if command -v ss >/dev/null 2>&1; then
  P80=$(ss -ltnH 'sport = :80' 2>/dev/null | awk '{print $4}' | tr '\n' ' ')
  if [ -z "${P80// /}" ]; then
    echo "  ✓ 80 端口无监听（已释放）"
  else
    echo "  ! 80 端口仍被占用：$P80 —— 若本就该由 nginx/haproxy 等提供服务，属正常"
  fi
fi

systemctl list-unit-files apache2.service >/dev/null 2>&1 \
  && echo "  · apache2.service：$(systemctl is-active apache2 2>&1)"

echo
echo "完成。被顺带升级的包（docker/tailscale 等）未处理，如需降级请单独评估。"
echo "本机日志：$LOG"
