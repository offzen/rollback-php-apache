# rollback-php-apache

一键回滚被 `apt[-get] upgrade php` 顺带装上的 php / apache2 栈。

## 简介

Debian 上执行 `apt-get upgrade php` / `apt upgrade php` 时，apt 3.x 会把
「upgrade 某个包」当作 install 处理，于是 `php` 元包通过依赖链把
`php8.4`、`libapache2-mod-php8.4`、`apache2` 以及一串 `libapr*` / `libsodium*`
依赖一并装进来。这些包往往并不是本机需要的，却会占用 80 端口、拉起
`apache2.service`，甚至顶掉原本在该端口上的 web 服务。

本脚本把这类「误装」的 php / apache2 包干净地回滚掉，**只动 php / apache2 及其专属依赖**：

- 解析 `/var/log/apt/history.log*`，找出最近 24 小时（`--hours` 可调）内由 apt 安装的包
- 与实际已装状态求交集，避免删掉本来就有的服务
- 三道安全检查：非默认 vhost、`/var/www` 下的 php 业务文件、自定义 php-fpm pool
- 默认**干跑**（只报告计划，不做任何改动），加 `--apply` 才真正执行 `apt-get purge`
- 加 `--purge-libs` 时，按「无反向依赖」迭代清理专属依赖库

> 注意：被同一次升级顺带升版本的 docker / tailscale 等**不在**处理范围内 ——
> 那属于版本替换，需要单独降级评估。

## 用途

- 误执行 `apt-get upgrade php` / `apt upgrade php` 之后，清理被拉进来的 php + apache2 栈
- 新机器上 `apache2` 抢占 80 端口，需要把它释放给 nginx / caddy 等
- 需要把这台机器恢复成「没有 php / apache 运行环境」的干净状态
- 变更前先看计划：直接运行脚本即为干跑模式，输出将 purge 的包清单

## 直接下载运行

```bash
curl -fsSL --proto '=https' -o /root/rollback-php-apache.sh https://raw.githubusercontent.com/offzen/rollback-php-apache/main/rollback-php-apache.sh && echo "3aa7b3961caaa09bfa11781f96abfdfb979c94d3415bcbb559334325a8ac1336  /root/rollback-php-apache.sh" | sha256sum -c - && chmod +x /root/rollback-php-apache.sh && /root/rollback-php-apache.sh --apply --purge-libs
```

上面这条命令会**下载 + 校验 sha256 + 赋可执行权限 + 直接执行回滚**，不依赖任何内部源。
如果只想先看计划，把末尾的 `--apply --purge-libs` 去掉即可（默认干跑）：

```bash
curl -fsSL --proto '=https' -o /root/rollback-php-apache.sh https://raw.githubusercontent.com/offzen/rollback-php-apache/main/rollback-php-apache.sh && echo "3aa7b3961caaa09bfa11781f96abfdfb979c94d3415bcbb559334325a8ac1336  /root/rollback-php-apache.sh" | sha256sum -c - && chmod +x /root/rollback-php-apache.sh && /root/rollback-php-apache.sh
```

## 参数

| 参数 | 说明 |
| --- | --- |
| 无参数 | 干跑：只报告计划，不做任何改动 |
| `--apply` | 真正执行回滚 |
| `--hours N` | 回看窗口，默认最近 24 小时 |
| `--purge-libs` | 连专属依赖库（`libapr*`、`libsodium23` 等）一起删（只删无反向依赖的） |
| `--force` | 跳过「非默认站点 / 业务 php 文件」的安全拦截 |
| `--from-installed` | 忽略 apt history，直接以当前已装 php/apache 为准 |
| `-h`, `--help` | 显示用法 |

## 退出码

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功，或本来就没有需要处理的包 |
| 1 | 需人工确认（窗口内无记录，但当前已装） |
| 2 | 参数错误 |
| 3 | 被安全检查拦截（疑似有业务在用） |
| 4 | 执行失败 |

## 依赖

`bash`、`coreutils`、`gawk`/`mawk`、`dpkg`、`apt`（不需要 python3），需 root 运行。

## 维护

脚本由内部 Gitea 仓同步而来，本仓库是独立可用的公开镜像；下载与运行不依赖内部源。
