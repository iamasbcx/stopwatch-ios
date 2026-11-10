# 秒表与 TRON 管理器

iOS 17 及以上版本的 SwiftUI 应用。首屏是中文倒计时秒表，输入 `5201314` 后点击「开始」进入「TRON 管理器」。解锁码不作为查询地址；进入后填写真实的 TRON 地址。

## 使用与功能

按 `H:\sdk\transactions` 的桌面界面功能对齐：

- 查询 TRX 原生转账、全部 TRC20 代币转账（包含 USDT），使用节点游标分页。
- 查看 TRX、USDT 余额以及剩余能量、带宽；失败显示错误，不把失败当作零余额。
- 查看账户所有者、操作、见证人权限及阈值、权重、操作掩码。与桌面版一样，这是只读查询，不修改链上授权。
- 复制、分享查询结果，或通过系统文件选择器导出 UTF-8 的 TXT 文件。
- 前台每 10 秒监控新交易，退到后台暂停；重新前台后继续。分页历史记录不会当作新交易提醒。
- TRX / USDT 本地签名和广播，提交前核对收款地址、币种及金额。节点接受广播不等于链上确认。
- 私钥在本地转换为地址，可复制结果。私钥不写入持久化存储。
- 中文界面、中文收支标记与北京时间；币种、地址、交易 ID 和节点返回的原始错误保留原文。

界面按钮直接显示在管理器页面上，无需查找此前缺失的导航栏菜单。支持全部 TRC20 记录查询，转账资产为 TRX 和 USDT；未提供任意代币合约转账表单。移动端使用系统网络配置，未移植桌面 libcurl 的独立代理参数与关闭状态的查询缓存。

## 查询编辑框记忆

查询地址、查询模式、编辑框内容和自动生成文本基线通过 `UserDefaults` 保存。再次打开并进入管理器会恢复，私钥不会保存。

- 查询结果可以选择、修改、复制和粘贴。
- 刷新、分页、监控仅在文本仍等于上次自动生成内容时更新，不覆盖手工修改。
- 「恢复查询结果」经确认后，用当前链上交易列表重新生成文本。
- 切换地址或查询类型会清除上一查询的文本和记录，避免混用不同账户。
- 复制、分享和 TXT 导出以编辑框内容为准；下方链上交易列表显示原始查询结果。
- 更新 LiveContainer 中的应用时保留原数据容器；删除应用数据会清除保存内容。

## Codemagic 与 LiveContainer

仓库的 `codemagic.yaml` 先运行真实 Swift 地址/私钥转换回归（`-Onone` 与 `-O`）、模拟节点响应的 TRX 查询回归和状态持久化回归，再使用 Xcode 构建未签名归档并打包：

- `build/StopwatchIOS.ipa`：内部为 `Payload/LapTimer.app`，供 LiveContainer 导入。
- `build/StopwatchIOS.xcarchive`：保留完整归档。

无需配置 Apple 签名凭据。主可执行文件由 `CFBundleExecutable=$(EXECUTABLE_NAME)` 指定，打包步骤检查文件是否存在。本机是 Windows，不包含 Xcode 或 iOS SDK；本次界面与持久化变更尚需 Codemagic 编译和 iPhone 实机验证。

## 代码与验证

- `Sources/StopwatchApp.swift`：秒表与管理器入口。
- `Sources/LapView.swift`：`TronManagerView` 中文查询界面、编辑和 TXT 导出。
- `Sources/StopwatchState.swift`：主线程查询状态、持久化、防过期响应、前台监控。
- `Sources/StopwatchEngine.swift`：TronGrid 查询、余额、权限、签名广播和中文错误。
- `Sources/TronSigner.swift`：纯 Swift secp256k1、Keccak、Base58Check 和交易编码。
- `Sources/LapDetailsView.swift`、`SplitView.swift`、`TimeSettingsView.swift`：权限、转账、私钥转地址。
- `Tests/TronManagerStateTests.swift`：在独立存储域测试重建状态后的恢复、地址/模式切换清空及解锁码隔离；不访问网络、不广播交易。
- `Tests/TronSignerRuntimeTests.swift`：直接执行正式 Swift 实现，验证 UInt64 构造、Base58 除法/地址编码、公开私钥转换、签名向量及非法输入；无需真实私钥。
- `Tests/TronQueryRuntimeTests.swift`：以 `URLProtocol` 固定响应执行 `StopwatchEngine.records`，覆盖 TRX 十六进制地址转换、TRC20 和 HTTP 错误；不访问真实节点。
- `Tools/mirror_swift_tron_signer.py`：Python 算法参考测试，不能替代真实 Swift 执行。它曾因自行归一化小整数而漏掉 Swift 的构造缺陷；通过不代表 SwiftUI 编译或实机验证通过。

已修复查询 TRX 与私钥转地址共用的 Base58 越界问题：`TronBigInt(u64:)` 现在统一清除高位零，避免将 `58` 错误表示为 `[58, 0]` 后导致除法余数越界。此修复的实际 Swift 回归由 Codemagic 执行；Windows 本地验证范围仍仅为语法检查和参考算法复现。

建议在新 IPA 中核验：`5201314` 进入中文管理器；输入地址查询 TRX/TRC20；修改结果后刷新不丢失；关闭重开后地址与文本恢复；复制及导出中文文本；监控前后台切换；权限/转账/转换入口均可打开。本文未声称本次进行了主网真实转账。
