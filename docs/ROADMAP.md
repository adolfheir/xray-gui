# XrayGUI 产品路线图

> 目标:在「同赛道」中确立 XrayGUI 的差异化定位。
> 对标对象:**Clash Verge Rev**(开源体验标杆)、**V2rayU**(同为 Xray 内核的直接竞品,已老化)、**Surge**(商业天花板,自研内核,不拼)。

---

## 0. 定位一句话

> **「Xray 内核的 Clash Verge Rev」** —— 用现代化 UI + Xray 独有的 Reality/XTLS 协议能力,填补 V2rayU 多年不更新留下的空白。

不去碰 Surge 的护城河(原生网络栈、抓包诊断),也不重复 Clash 生态已经做透的事;**把 Xray 内核的协议前沿性做成别人抄不动的卖点。**

---

## 1. 现状盘点(2026-06)

项目完成度已达 ~95%,以下为**已实现**能力,路线图不再重复投入:

| 已具备 | 说明 |
|--------|------|
| 订阅管理 | 自动更新、流量/到期追踪 |
| 分享链接导入 | vmess/vless/trojan/ss/ssr/socks/http/hy2/tuic 解析 |
| 路由规则 | 5 预设 + 图形化自定义规则编辑器 |
| TUN 模式 | 特权助手 + tun2socks + split-default 路由 |
| 流量统计 | 实时上下行 + 累计字节(xray api) |
| 国际化 | 运行时切换 en / zh-Hans / system |
| 协议配置生成 | **Reality / VLESS / XTLS-Vision 完整支持** + 全 transport |
| 延迟测试 | TCP ping + URL test + 批量 |
| 节点分享 | 复制 share link(单向导出) |
| 其它 | 系统代理、开机自启、日志流、原始 JSON 编辑、核心自动管理 |

**结论:协议能力不是差距,「能力的可达性与体验」才是差距。**

---

## 2. 三大目标(校准后)

### 目标一:UI / 规则配置体验对标 Clash Verge Rev

Clash Verge Rev 有、XrayGUI 缺的体验项:

| 缺口 | 优先级 | 说明 |
|------|--------|------|
| **主题 / 外观系统** | P1 | 浅色/深色/跟随系统切换 + 主题色。目前无 `preferredColorScheme` 控制 |
| **策略组 / 负载均衡** | P0 | 见目标二(用 Xray balancer 实现,是差异化核心) |
| **规则拖拽排序 + geosite/geoip 补全** | P1 | 现有规则编辑器是表格,缺顺序可视化与匹配项自动补全 |
| **规则集导入/导出** | P2 | 一键导入常用规则集(如 ACL4SSR 风格),降低上手成本 |
| **节点卡片体验** | P2 | 延迟着色、分组折叠、批量操作的视觉打磨 |

### 目标二:Reality / VLESS / XTLS 做差异化卖点

协议解析已就绪,差异化在于**让用户能"创建/调试/分发"这些协议**,而非只能被动导入:

| 能力 | 优先级 | 为什么是护城河 |
|------|--------|----------------|
| **手动新建/编辑节点表单** | **P0** | 当前**只能粘贴链接导入,没有创建表单**。Reality/VLESS/XTLS 字段多(pbk/sid/spx/flow/fp),图形化表单是刚需 |
| **Reality 密钥对生成器(x25519)** | **P0** | 内置生成 publicKey/privateKey,用户可直接配服务端。V2rayU/Clash 都做不到,**最强卖点** |
| **Xray Balancer / Observatory 策略组** | **P0** | leastPing / leastLoad / random 负载均衡 + burstObservatory 健康探测,是 **Xray 内核独有**,Clash 的 group 概念无法等价 |
| **二维码生成 / 分享** | P1 | 节点已能复制链接,补 QR 即可"扫码分享",移动端联动 |
| **XTLS-Vision flow 一键预设** | P1 | 表单里把 `xtls-rprx-vision` 等做成下拉,免手填 |
| **订阅/节点导出为分享链接批量** | P2 | 反向序列化 ProxyNode → URI(单个已支持,批量化) |

### 目标三:明确「不做」清单(投入产出比低)

| 不做 | 理由 |
|------|------|
| 抓包 / HTTPS 解密 / MITM | Surge 几年护城河,原生实现成本极高,Xray 用户诉求弱 |
| 网络诊断 / 连接列表实时面板 | 偏诊断,边际价值低;如做仅做轻量"活动连接"只读视图,排在最后 |
| 自研网络栈 / 替换 Xray 内核 | 与定位冲突,Xray 内核正是卖点来源 |

---

## 3. 实施阶段

### Phase 1 — 差异化核心(P0)✅ 已完成(2026-06-23)
建立"别人抄不动"的能力。已实现并通过编译 + SwiftFormat lint。

1. **手动节点编辑器** ✅
   - 新增 `Views/MainWindow/NodeEditorView.swift`(表单:协议/地址/端口/凭证/传输/TLS/Reality/flow,随协议条件渲染)
   - `AppState` 增加 `addNode` / `updateNode`(维持节点/组选择互斥)
   - 入口:`NodesView` 工具栏「New Node」+ 节点行「Edit」(sheet)
2. **Reality 密钥生成器** ✅
   - 新增 `Services/RealityKeygen.swift`,调用 `xray x25519` 生成 X25519 密钥对 + 本地随机 shortId
   - 嵌入节点编辑器:一键生成 → 公钥自动填入、私钥可复制展示(提示配服务端)
3. **Balancer 策略组** ✅
   - 新增 `Models/NodeGroup.swift`(`BalancerStrategy`: random/leastPing/leastLoad)
   - `Services/ConfigBuilder.swift` 新增组构建路径:多 `proxy-N` 出站 + `routing.balancers` + `observatory`(leastPing/leastLoad 时)
   - `AppState` 增加 `nodeGroups`/`selectedGroupId` + 持久化 + `prepareConfig` 分支
   - `Views/MainWindow/RoutingView.swift` 增加「Strategy Groups」管理 UI

### Phase 1.5 — 连接稳健性(P0)✅ 已完成(2026-06-23)
补齐"保活"盲区:进程崩溃自愈之外,处理睡眠唤醒、网络切换、系统代理被外部改动。

- **睡眠/唤醒** ✅ 新增 `Services/PowerEventMonitor.swift`(`NSWorkspace` willSleep/didWake)→ 唤醒后 `restart()`
- **网络变化** ✅ 新增 `Services/NetworkMonitor.swift`(`NWPathMonitor`,接口集合/可达性变化去重 + 首次基线不误触发)→ 恢复连接后 `restart()`
- **系统代理守卫** ✅ 新增 `Services/SystemProxyGuard.swift`(`SCDynamicStore` 监听全局代理 key,0.6s 去抖)→ 被外部改动时重设;`AppState` 用 `lastProxyWriteAt` 时间戳抑制"自写死循环"
- 接线集中在 `AppState`(`startResilienceMonitors`/`stopResilienceMonitors`/`wireResilienceIfNeeded`),仅在运行期启用,proxy 守卫仅系统代理模式启用
- 已有能力(保留):`XrayCoreManager` 进程崩溃监督(指数退避 1/2/4/8s,连续 5 次放弃)

### Phase 2 — 体验对标(P1)✅ 已完成(2026-06-23)
1. **主题系统** ✅ 新增 `Models/AppTheme.swift`(system/light/dark)+ `AppState.appTheme`(UserDefaults 持久化)+ `XrayGUIApp` 两个 Scene 应用 `.preferredColorScheme` + `SettingsView` 外观选择器,运行时即时切换
2. **二维码生成** ✅ 新增 `Services/QRCodeGenerator.swift`(CIQRCodeGenerator→NSImage)+ `Services/ShareLink/ShareLinkExporter.swift`(节点反向序列化 vless/vmess/trojan/ss,手动节点也能分享)+ `NodesView` 每行「二维码」按钮 + `NodeShareSheet`
3. **规则编辑器增强** ✅ `RoutingView` 自定义规则 `.onMove` 拖拽排序 + 规则编辑 sheet 内常用 geosite/geoip 匹配项一键插入
4. **XTLS-Vision flow 下拉** ✅(已在 Phase 1 节点编辑器内完成)

### Phase 3 — 打磨与生态(P2,按需)
1. 规则集导入/导出
2. 节点卡片视觉打磨(延迟着色、分组折叠、批量操作)
3. 批量导出分享链接

---

## 4. 成功指标

- **对 V2rayU**:支持其不支持的 Reality 密钥生成 + 现代 UI + 持续更新。
- **对 Clash Verge Rev**:协议前沿性领先(Reality/XTLS/Vision),体验不输。
- **可量化**:新用户从"零"到"配好一个 Reality 节点"全程图形化、无需手写 JSON。

---

## 5. 关键文件索引(实施参考)

| 用途 | 路径 |
|------|------|
| 配置生成 | `XrayGUI/Services/ConfigBuilder.swift` |
| 分享链接解析 | `XrayGUI/Services/ShareLink/ShareLinkParser.swift` |
| 节点模型 | `XrayGUI/Models/ProxyNode.swift` |
| 路由模型 | `XrayGUI/Models/RoutingSettings.swift` |
| 节点列表 UI | `XrayGUI/Views/MainWindow/NodesView.swift` |
| 路由 UI | `XrayGUI/Views/MainWindow/RoutingView.swift` |
| 全局状态 | `XrayGUI/AppState.swift` |
| 新增:节点编辑器 | `XrayGUI/Views/MainWindow/NodeEditorView.swift` *(待建)* |
| 新增:Reality 密钥 | `XrayGUI/Services/RealityKeygen.swift` *(待建)* |
