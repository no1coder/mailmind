# 为 MailMind 注册微软应用（Outlook / Hotmail 登录）

微软已不允许第三方软件用密码登录个人 Outlook.com 邮箱，只能通过 OAuth 授权。
OAuth 需要一个「应用 ID」来标识 MailMind。整个项目只需注册一次，所有用户共用；
MailMind 是公共客户端（使用 PKCE，没有客户端密钥），应用 ID 可以公开写在源码里。

## 步骤（约 5 分钟，免费）

1. 打开 <https://portal.azure.com>，用任意微软账号登录
2. 进入 **Microsoft Entra ID → 应用注册 → 新注册**
   - 名称：`MailMind`（用户在授权页会看到这个名字）
   - 受支持的帐户类型：**任何组织目录中的帐户和个人 Microsoft 帐户**
   - 重定向 URI：平台选 **公共客户端/本机（移动和桌面）**，填写 `mailmind://oauth`
3. 进入 **API 权限 → 添加权限 → Microsoft Graph → 委托的权限**，勾选：
   - `IMAP.AccessAsUser.All`
   - `offline_access`、`openid`、`email`、`profile`
4. 在 **概述** 页复制「应用程序(客户端) ID」

## 填写应用 ID

- **发布版本**：写入 `Sources/MailMind/Mail/OAuth.swift` 中的 `MicrosoftOAuth.builtInClientID`
- **临时测试**：在 MailMind「添加邮箱 → Outlook」页面直接粘贴并保存

## 可选：发布者验证

未验证的应用在授权页会显示「未验证」，但可以正常使用。
完成 [发布者验证](https://learn.microsoft.com/entra/identity-platform/publisher-verification-overview) 后会显示已验证的发布者名称。

## 常见问题

- **公司 Microsoft 365 邮箱提示需要管理员同意**：组织限制了第三方应用，需要 IT 管理员在 Entra 中同意授权，并允许 IMAP。
- **授权成功但 IMAP 登录失败**：在 outlook.live.com →「设置 → 邮件 → 转发和 IMAP」中确认已开启 IMAP。
