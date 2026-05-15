# TestFlight 部署手册

走到 **TestFlight 收到测试 build** 大约 1 小时（首次 + Apple 审 24h）。

---

## ✅ 前置条件（必须完成）

1. Apple Developer Program 已激活（个人 ¥688/年 已付）
2. Xcode 已登录你的 Apple ID（Settings → Accounts → 加 + Sign in）

---

## Step 1：Xcode 配置签名（5 分钟）

1. Xcode 左上点项目名 `AIMakeupAssistant` → 在中间面板选 **TARGETS → AIMakeupAssistant**
2. 切到 **Signing & Capabilities** tab
3. **Team** 下拉：选你的 Apple Developer 团队（不再是 "Personal Team"）
4. **Automatically manage signing** 保持勾选
5. **Bundle Identifier** 当前 `com.demo.AIMakeupAssistant`
   - 想换成自己专属：改成 `com.<你姓名拼音>.AIMakeupAssistant`（比如 `com.zhangsan.AIMakeupAssistant`）
   - **注意**：改完会自动生成新的 App ID，建议直接走 TestFlight 前再确认

预期看到下方一行绿色对勾：`Provisioning Profile: Xcode Managed Profile`

---

## Step 2：App Store Connect 创建 App 记录（5 分钟）

1. 浏览器打开：https://appstoreconnect.apple.com/apps
2. 左上角点 **"+"** → **新建 App**
3. 填表：
   - **平台**：iOS
   - **名称**：AI 美妆助手（这个名字会显示在 TestFlight 邀请里）
   - **主要语言**：简体中文
   - **Bundle ID**：从下拉选 `com.demo.AIMakeupAssistant`（如果列表里没有，回 Xcode Archive 一次再来）
   - **SKU**：随便填，比如 `aimakeup-001`
   - **用户访问权限**：完全访问
4. 点 **创建**

---

## Step 3：Xcode Archive 打包（5-10 分钟）

1. Xcode 顶部 device 下拉 → 选 **Any iOS Device (arm64)**（不是模拟器，不是某台具体的 iPhone）
2. 菜单 **Product → Archive**
3. 等编译 + 打包，~5 分钟
4. 完成后**自动弹出 Organizer 窗口**，显示你的 Archive

> 如果报错"missing signing"：回到 Step 1 检查 Team 是否选对。

---

## Step 4：上传到 App Store Connect（3 分钟）

在 Organizer 窗口里：

1. 选最新那个 Archive → 右边点 **Distribute App**
2. 选 **App Store Connect** → Next
3. 选 **Upload** → Next
4. 一路 Next 用默认设置（Symbol 上传、Manage Version 都勾选）
5. 等待"Upload to App Store Connect successful"

---

## Step 5：等 Apple 处理（~10-30 分钟）

1. 回到浏览器 https://appstoreconnect.apple.com/apps
2. 点你的 app → **TestFlight** tab
3. 等 "iOS Builds" 区域出现你刚上传的版本，状态从 **"Processing"** 变成 **"Ready to Submit"**

期间 Apple 会给你发邮件，要么是"build ready"，要么是"build issues"（按邮件指示修）。

---

## Step 6：配置测试员（10 分钟）

### 6A. 内部测试（你的 Apple ID + 同事，不需要审核）

1. **TestFlight → 内部群组** → 加群组 → 加成员（Email）
2. 选 build → 添加到测试群组
3. 成员收到邮件，装 TestFlight app 后看到。**0 等待**。

### 6B. 外部测试（任何邮箱 + 公开链接，需要审核）

1. **TestFlight → 外部群组** → 创建一个群组（取个名字"BetaUsers"）
2. 选 build → 添加到外部群组
3. 必须填写"测试备注"（写"AI 美妆助手 beta 测试"等）
4. 点 **提交审核**
5. **等 24 小时**，Apple 审核完会发邮件
6. 审核通过后：
   - 加成员邮箱（最多 10000 个）
   - 或者点"启用公开链接"得一个 https://testflight.apple.com/join/xxx URL，**发朋友圈、丢群里**，谁点谁能装

---

## Step 7：测试员装 TestFlight + 安装你的 app

测试员第一次：
1. App Store 装 **TestFlight**
2. 收到的邀请邮件/链接 → 点 **接受邀请** / 点公开链接
3. TestFlight 里看到你的 app → 点 **安装**
4. 装完直接在主屏打开

测试员永远**不需要装 Xcode**，**不需要插线**，跟正常用 App Store 一模一样的体验。

---

## 常见问题

**Q: 第一次 Archive 报错 "No account for team"?**
A: Xcode → Settings → Accounts → 加 + 你的 Apple Developer ID 登录。

**Q: Build 上传后 "Processing" 卡了 1 小时？**
A: Apple 服务器偶尔慢，正常 30 分钟搞定，超过 2 小时就重新 Archive 上传。

**Q: 朋友点公开链接说"无法接受邀请"？**
A: 他需要在 iPhone 上先装 App Store 的 TestFlight。然后用 **同一个 Apple ID** 点链接。

**Q: 一个 build 测试时长？**
A: TestFlight build 上传后**90 天有效**，过期前再 Archive 一个新 build 上传即可。

**Q: 改 .env / 改代理 / 不动 iOS 代码，需要重新 build 吗？**
A: 不需要！代理在云上跑，改完 systemctl restart 立刻生效，TestFlight 里的 app 自动用新逻辑。

---

## 改 Bundle ID（可选，建议上 App Store 前做）

如果想从 `com.demo.AIMakeupAssistant` 换成 `com.yourname.AIMakeupAssistant`：

1. Xcode → Target → General → **Bundle Identifier** 改字符串
2. 改完后第一次 Archive 时 Xcode 会自动注册新 App ID 到 Developer Center
3. App Store Connect 那边也要重新建一个 App 记录（用新 Bundle ID）

⚠️ 改 Bundle ID = 创建新 app，**旧版的 TestFlight 测试历史不会迁移**，慎重。
