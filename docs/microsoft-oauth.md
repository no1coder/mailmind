# 为 MailMind 注册微软应用（Outlook / Hotmail 登录）

微软已不允许第三方软件用密码登录个人 Outlook.com 邮箱，只能通过 OAuth 授权。
OAuth 需要一个「应用 ID」来标识 MailMind。整个项目只需注册一次，所有用户共用；
MailMind 是公共客户端（使用 PKCE，没有客户端密钥），应用 ID 可以公开写在源码里。

## 第 0 步：准备一个「目录（租户）」

微软已停用「在目录之外创建应用」。用个人微软账号登录时，如果没有自己的目录，
「应用注册」页面无法新建应用。先确认或创建一个目录：

1. 打开 <https://entra.microsoft.com>，用你的微软账号登录
2. 看右上角头像下方显示的目录名：
   - 如果能进入「应用注册 → 新注册」页面且不报错，说明已有目录，直接跳到第 1 步
   - 如果提示没有权限或没有目录，用以下任一方式创建：
     - **Azure 免费账户**：<https://azure.microsoft.com/free>，注册时需要手机号和信用卡做身份验证（不会扣费），完成后自动获得一个目录
     - **Microsoft 365 开发者计划**：<https://developer.microsoft.com/microsoft-365/dev-program>（是否提供免费沙盒视资格而定）

## 第 1 步：新建应用

1. 在 <https://entra.microsoft.com> 左侧进入 **应用程序 → 应用注册 → 新注册**
2. 填写：
   - **名称**：`MailMind`（用户在授权页会看到这个名字）
   - **受支持的帐户类型**：**任何组织目录中的帐户和个人 Microsoft 帐户**（多租户 + 个人账户）
   - **重定向 URI**：平台选 **公共客户端/本机（移动和桌面）**，填写 `mailmind://oauth`
3. 点击 **注册**

> 如果「受支持的帐户类型」里没有「个人 Microsoft 帐户」选项：先随便选一个完成注册，
> 然后进入 **清单（Manifest）**，把 `signInAudience` 改为 `AzureADandPersonalMicrosoftAccount` 并保存。

## 第 2 步：身份验证设置

进入 **身份验证（Authentication）**：

1. 确认「移动和桌面应用程序」下有 `mailmind://oauth`
2. 页面底部「高级设置」中，**允许公共客户端流** 选 **是**，保存

## 第 3 步：API 权限

进入 **API 权限 → 添加权限 → Microsoft Graph → 委托的权限**，搜索并勾选：

- `IMAP.AccessAsUser.All`
- `offline_access`
- `openid`、`email`、`profile`

点击 **添加权限**。个人账户不需要「授予管理员同意」。

## 第 4 步：复制应用 ID

在 **概述** 页复制 **应用程序(客户端) ID**（形如 `1a2b3c4d-1234-5678-9abc-def012345678`）。

注意：不要复制「目录(租户) ID」；也**不需要**创建「客户端密码」。

## 填写应用 ID

- **临时测试**：在 MailMind「添加邮箱 → Outlook」页面粘贴并保存
- **发布版本**：写入 `Sources/MailMind/Mail/OAuth.swift` 中的 `MicrosoftOAuth.builtInClientID`

## 可选：发布者验证

未验证的应用在授权页会显示「未验证」，但可以正常使用。
完成 [发布者验证](https://learn.microsoft.com/entra/identity-platform/publisher-verification-overview) 后会显示已验证的发布者名称（需要微软合作伙伴计划账号）。

## 常见问题

| 错误 | 原因与解决 |
|---|---|
| `AADSTS700016` 找不到应用 | 应用 ID 复制错了，或应用不支持个人账户（检查第 1 步的帐户类型 / 清单中的 `signInAudience`） |
| `AADSTS50011` 重定向 URI 不匹配 | 第 1 步的重定向 URI 必须完全是 `mailmind://oauth`，平台必须是「移动和桌面」 |
| `AADSTS7000218` 需要 client_secret | 第 2 步「允许公共客户端流」没有打开 |
| 公司邮箱提示需要管理员同意 | 组织限制了第三方应用，需要 IT 管理员在 Entra 中同意授权，并允许 IMAP |
| 授权成功但 IMAP 登录失败 | 在 outlook.live.com →「设置 → 邮件 → 转发和 IMAP」中确认已开启 IMAP |
