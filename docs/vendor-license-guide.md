# 厂商指南：Permit entitlement 签发

本文件已迁移到新的 Permit 商业运维流程。

请直接阅读 [permit-operations.md](permit-operations.md)。其中包含：

- 独立 entitlement Ed25519 密钥生成与 Keyward / 私有存储边界；
- 生产 public trust store 的提交与 Release fail-closed 检查；
- 永久 Pro + 维护期 entitlement 签发；
- 月度订阅签发；
- 可选随机 `installation_id` 绑定；
- 续费时稳定 `entitlement_id` + 递增 `revision` 的规则；
- 离线授权无法实时撤销/回收席位的明确边界。

旧的 `glaze/license`、RSA/OpenSSL CLI 和硬件 `machine-id` 流程已经退役，不再用于官方 gPTP Studio entitlement。
