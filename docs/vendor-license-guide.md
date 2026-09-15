# 厂商指南：许可证签发 / Vendor License Guide

> 仅作者（vendor）需要本文件。私钥不入库（`.gitignore` 已排除 `app/keys/private.pem`），请离线备份。

## 一次性：密钥对

```bash
raco glaze keygen --out app/keys        # 生成 private.pem + public.pem
```

`public.pem` 随应用分发（`app/gate.rkt` 经 `define-runtime-path` 内嵌）；`private.pem` 自行保管。

## 签发一张许可证

```bash
racket -e '(require glaze/license)
(issue-license #:private-key "app/keys/private.pem"
               #:product "gPTP Studio"
               #:subject "customer@example.com"
               #:expiry "2027-12-31"          ; 可选
               #:machine-id (machine-id)      ; 可选（机器绑定，取客户机器上的值）
               #:out "customer.license")'
```

> 注：`raco glaze license sign` CLI 在含空格的 product 名上参数解析有缺陷，建议走上述 Racket 调用。

## 客户侧激活

1. GUI →「运行与日志 → 激活许可证」选择 `.license` 文件；或
2. 直接放入 `~/.gptp-studio/license.lic` 后重启。

校验完全离线：canonical JSON + RSA-SHA256（系统 openssl CLI），失败时返回稳定 reason（signature / product / expired / machine / malformed）。

## 验证 / 吊销

```bash
raco glaze license verify --pub app/keys/public.pem --product "gPTP Studio" customer.license
```

吊销 = 签发短期许可证（expiry），到期自然失效；换机 = 按新 machine-id 重签（免费政策见 PRICING.md）。

## 私钥泄漏预案

用 `raco glaze keygen` 换发新密钥对，替换仓库中 `public.pem`，随下一次更新发布；旧密钥签发的许可证全部失效。
