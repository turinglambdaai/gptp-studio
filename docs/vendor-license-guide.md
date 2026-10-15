# 厂商指南：Permit 授权签发 / Vendor License Guide

> 仅作者（vendor）需要本文件。私钥不入库，请离线备份（家族密钥库
> `~/Sync/Keys/gptp-studio-permit/`）。

商业授权基于 [Permit](https://github.com/turinglambdaai/permit)——离线可验证、
在线可管理的签名权利协议。应用内置的是公钥信任库（`app/keys/trust-store.json`），
验证完全离线；签发只需要 vendor 本机的私钥。

## 一次性：密钥对 + 信任库

```bash
raco permit keygen \
  --private ~/Sync/Keys/gptp-studio-permit/private-key.der \
  --public  ~/Sync/Keys/gptp-studio-permit/public-key.der \
  --trust-store app/keys/trust-store.json \
  --key-id gptp-pro-2026 \
  --issuer com.turinglambdaai.gptp-studio
```

`trust-store.json` 入库并随应用分发；`private-key.der` 自行保管、绝不入库。
轮换密钥时用 `next` 状态预分发新公钥（见 permit 的 trust 文档）。

## 签发一张 Pro 授权

从 permit 仓库 `examples/` 的模板出发改字段，或直接写 payload JSON（可省略
`credential_id` 等由签发器补全的字段时以 `raco permit issue` 的 schema 校验为
准）：

```json
{
  "protocol": "permit",
  "version": 1,
  "type": "entitlement",
  "credential_id": "cred_gptp_001",
  "entitlement_id": "ent_gptp_customer",
  "revision": 0,
  "issuer": "com.turinglambdaai.gptp-studio",
  "issued_at": "2026-10-16T00:00:00Z",
  "not_before": null,
  "subject": {
    "type": "person",
    "id": "customer_01",
    "display": "customer@example.com"
  },
  "channel": "commercial",
  "grants": [
    {
      "scope": { "products": ["gptp-studio"], "product_families": [] },
      "edition": "pro",
      "features": [],
      "addons": [],
      "capabilities": {},
      "feature_policy": "published-through"
    }
  ],
  "constraints": {
    "use_expires_at": null,
    "updates_through": null,
    "features_through": null,
    "version_policy": { "min": null, "max": null },
    "limits": { "named_seats": null, "device_activations": null,
                "concurrent_seats": null },
    "installation_id": null,
    "activation_required": false
  },
  "extensions": {}
}
```

字段语义：`use_expires_at` 设日期即订阅式（到期停用）；留 null 即永久。
注意 jsexpr 世界的"无值"写 JSON `null`，不是 `false`。

签发（签名覆盖 payload 字节本身，签发器会先做 schema 校验）：

```bash
raco permit issue \
  --key ~/Sync/Keys/gptp-studio-permit/private-key.der \
  --key-id gptp-pro-2026 \
  --trust-store app/keys/trust-store.json \
  --payload entitlement.json \
  --output customer.permit.json
```

发给客户的就是 `customer.permit.json`。

## 续订 / 变更

同一 `entitlement_id`、`revision` 加一，重新签发一份完整快照。客户激活新文件
即完成替换（客户端在收到的凭据间做确定性替换，不构成离线吊销）。

## 客户激活

客户在应用内输入 `.permit.json` 文件路径（About 页 → 激活）。应用验证签名、
信任库、issuer、有效期与 pro edition 后把文件复制到
`~/.gptp-studio/entitlement.permit.json`。

## 验证与巡检

```bash
raco permit verify --trust-store app/keys/trust-store.json \
                   --credential customer.permit.json
raco permit check  --trust-store app/keys/trust-store.json \
                   --credential customer.permit.json \
                   --product gptp-studio --edition pro   # 或 --feature
```

`raco permit inspect` 的输出刻意标记为未验证——任何授权判定只走 `verify`。

## 试用

14 天 Pro 试用由应用本地状态机管理（`app/gate.rkt` 的 gate-state），不依赖
签发；如需远程发放试用延期，签发 `trial-extension` 凭据（Protocol v1）。
