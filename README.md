# HorseBox

HorseUI 面板的专用双端代理客户端。一套 Flutter 代码同时构建 Windows 和 Android，配置和节点全部来自 HorseUI 面板的订阅接口，客户端本身不包含任何节点。

- **Windows**：以子进程方式运行官方 `sing-box.exe`，支持 TUN 和混合端口，关闭窗口后驻留托盘。
- **Android**：通过 `libbox` + `VpnService` 接管流量，前台通知常驻，支持分应用代理。

## 功能

- **订阅拉取**：`https://面板地址/sub/<令牌>?target=singbox`
- **证书固定**：自签面板用 SHA-256 指纹校验，每次 TLS 握手都比对，不匹配直接断开
- **首次登录**：没有订阅时也能直接连面板，先建入站再配订阅
- **国内分流**：内置 `geosite-cn` / `geoip-cn`，国内域名和 IP 直连，其余走代理
- **自定义规则**：域名后缀、域名关键字、IP 段，可指定直连、代理或拦截
- **分应用代理（Android）**：选择走代理的应用和强制直连的应用，系统应用默认直连
- **节点管理**：自动选择、手动切换、单节点测速、全部测速
- **网络设置**：混合端口、TUN、TUN 栈（mixed / gvisor）、MTU、IPv6、局域网
- **DNS**：沿用面板下发，或自定义 UDP / DoT / DoH
- **内嵌面板**：在客户端里直接打开 HorseUI 面板，安卓横屏沉浸式，Windows 左侧胶囊导航
- **其他**：hosts 映射、连接列表、实时流量、日志、深色/浅色主题、Windows 数据目录自定义

## 目录结构

```
HorseBox/
├─ UI/                     Flutter 工程（Android + Windows）
│  ├─ lib/                 界面与客户端状态
│  ├─ android/             Android 平台层（VpnService、libbox）
│  ├─ windows/             Windows 平台层（窗口、托盘）
│  ├─ assets/rules/        内置中国分流规则集
│  └─ test/                配置补丁单元测试
├─ back-machine/           Dart 后端包 horsebox_backend
│  └─ lib/src/             订阅、证书固定、面板预检、Clash API、内核进程、本地存储
├─ tools/patch-plugins.ps1 构建前修补第三方插件（见下文）
├─ android/sync-libbox.bat 同步 libbox.aar 到 Android 工程
├─ windows/package.bat     复制 Windows 内核到构建产物
└─ build-all.bat           双端一键打包
```

## 环境要求

- Flutter 3.x（Dart 3.13 及以上）
- Windows 构建：Visual Studio 2022，勾选「使用 C++ 的桌面开发」
- Android 构建：JDK 17 或 21、Android SDK、NDK `27.2.12479018`
- 不需要安装 Go，客户端后端是纯 Dart

## 准备依赖

仓库不包含以下二进制文件，需要自行准备。

### 1. libbox.aar（Android）

由 sing-box 源码通过 gomobile 构建，放到：

```
UI/android/app/libs/libbox.aar
```

也可以把文件放到 `core/libbox.aar`，再运行 `android/sync-libbox.bat` 复制过去。

### 2. sing-box.exe（Windows）

从 sing-box 官方 Release 下载 `sing-box-<版本>-windows-amd64.zip`，把以下文件放到：

```
core/sing-box.exe
core/libcronet.dll
```

`libcronet.dll` 必须与 `sing-box.exe` 同目录，缺少它内核无法启动。

## 构建

### 构建前必须先打插件补丁

Windows 端的自签证书校验依赖对 `flutter_inappwebview_windows` 的源码补丁：
插件的证书错误处理默认被注释掉，补丁会启用它，并把「放行一切」改成
「证书 SHA-256 必须等于 `%LOCALAPPDATA%\HorseBox\panel_pin`」。

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch-plugins.ps1
```

补丁脚本会：

1. 修正 Android 插件的 proguard 文件名（AGP 8+ 要求）
2. 给 Windows 插件注入指纹校验代码
3. 校验补丁标记 `horsebox-pin-v2`，失败时返回非 0

`build-all.bat` 会自动调用它；单独构建时请手动执行一次。`flutter pub get` / 升级插件后需要重新执行。

### Windows

```bash
cd UI
flutter pub get
flutter build windows --release --no-tree-shake-icons
```

构建完成后把内核复制进产物：

```bat
windows\package.bat
```

产物在 `UI\build\windows\x64\runner\Release\`。TUN 模式需要以管理员身份运行。

### Android

1. 签名配置

在 `UI/android/` 下创建 `key.properties`：

```properties
storePassword=你的密码
keyPassword=你的密码
keyAlias=horsebox
storeFile=horsebox-release.jks
```

生成 keystore（放在 `UI/android/app/`）：

```bash
keytool -genkeypair -v -keystore horsebox-release.jks -storetype PKCS12 \
  -alias horsebox -keyalg RSA -keysize 4096 -validity 10000
```

`key.properties` 和 `*.jks` 已在 `.gitignore` 中，不要提交。

2. 构建

```bash
cd UI
flutter pub get
flutter build apk --release --no-tree-shake-icons \
  --target-platform android-arm64,android-x64 --split-per-abi
```

产物：`UI/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

没有 `key.properties` 时 Gradle 会直接报错，不会静默回退到 debug 签名。

### 一键打包

`build-all.bat` 会依次构建 Windows 和 Android，成品输出到 `app/`。运行前按本机环境修改脚本顶部：

```bat
set "FLUTTER=D:\flutter\bin\flutter.bat"
set "JAVA_HOME=%USERPROFILE%\.jdks\jbr-21.0.11"
set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "NDK_VER=27.2.12479018"
```

脚本运行时会要求输入版本号，`--build-name` 使用该版本号，`--build-number` 默认是去掉点的数字。
注意 `--split-per-abi` 会由 Flutter 给 versionCode 加 ABI 偏移（arm64 +2000、x86_64 +4000），
发布到 F-Droid 前确认新包的 versionCode 大于上一版。需要固定 versionCode 时先 `set BUILDNO=3014` 再运行脚本。

## 使用流程

### 第一次使用：面板还没配好

1. 在服务器上装好 HorseUI，终端会打印管理员密码和面板地址（`https://IP:端口`）
2. 打开 HorseBox → 底部/左侧「面板」→「首次登录」
3. 填写面板地址，例如 `https://1.2.3.4:8443`，点「临时连接」
4. 连接是 TLS 加密的，但**这次不校验证书**，页面底部会有一条橙色横幅提示
5. 用管理员密码登录面板，建好入站和用户，复制订阅地址
6. 在面板的「设置 → 客户端证书指纹」里复制 SHA-256 指纹
7. 回到 HorseBox →「订阅」→ 添加订阅，填订阅地址、名称、指纹
8. 回首页点「连接」

从第 7 步开始，面板和订阅都只认这张证书：每次 TLS 握手都会比对指纹，不一致直接断开并提示。

### 已有订阅

- 「订阅」页点击订阅卡片可展开节点列表，右上角圆形按钮刷新
- 面板页直接点订阅条目即可打开面板，走严格指纹校验，不再有临时连接
- 指纹为空时才允许临时连接；填了指纹就不会降级

### 连接

- Windows：TUN 模式需要管理员权限；关闭窗口会隐藏到托盘，代理继续运行
- Android：首次连接会申请 VPN 权限和通知权限；通知栏常驻，可直接在通知里断开

### 分应用代理（Android）

设置 → 分应用代理：

- **代理应用**：只勾选需要走代理的应用；不勾选表示代理全部用户应用
- **直连应用**：强制不进入 VPN，例如国内视频、国内购物
- **系统应用**：默认直连，不显示在列表里；Google Play 服务、Google Services Framework、Play 商店除外，可以手动勾选

保存后需要断开再重连才会生效。

### 分流规则

设置 → 分流规则：

- 内置规则始终生效：`geosite-cn` 和 `geoip-cn` 直连
- 自定义规则支持域名后缀、域名关键字、IP 段，动作可选直连、走代理、拦截
- 规则顺序：自定义规则 → Google 强制代理 → 国内域名/IP → 私有 IP → 其余走代理

### 节点选择与测速

展开订阅卡片后：

- 「自动选择」使用 urltest 按延迟自动挑选
- 点击任意节点可手动切换，当前连接会立即生效
- 节点右侧「测速」显示延迟，顶部「全部测速」批量检测

## 证书与安全

客户端只信任一张证书：面板的 SHA-256 指纹。

- **订阅拉取**：用 `SecureSocket` 握手后直接对 `peerCertificate` 算指纹，任何证书（包括公网 CA 证书）都必须命中
- **面板 WebView（Android）**：每次 `onReceivedServerTrustAuthRequest` 都用回传的证书 DER 算指纹，不一致取消连接
- **面板 WebView（Windows）**：WebView2 的原生证书回调里比对 PEM → DER 的 SHA-256，不一致取消加载
- **临时连接**：只在没有填写指纹时出现，仍然加密，但不做身份校验，用于第一次进面板

指纹从哪里来：面板「设置 → 客户端证书指纹」，或 `GET /api/panelcert`。

换证书（重新生成自签 / 换成 ACME）后，旧指纹会立刻失效，需要重新复制。

> 说明：这套固定只覆盖自签证书。如果面板改用公网 CA 证书，WebView 层不会触发校验回调（证书链本身合法），此时保护来自 CA 体系而不是指纹。

## 常见问题

**连接后国内网站打不开**

检查是否误把国内应用加进了「代理应用」；或者把该应用加到「直连应用」。内置规则只覆盖常见域名/IP。

**Windows 连接失败，提示权限不足**

TUN 需要管理员权限，右键以管理员身份运行。

**面板打不开，提示证书指纹不匹配**

面板重新生成过证书。到面板复制新的 SHA-256，更新订阅里的指纹；临时连接仅在指纹为空时可用。

**Android 代理开着但应用不走代理**

部分应用会绕过 VPN（如自带网络栈的系统组件）。可以尝试关闭该应用的「私密 DNS」，或把它加入「代理应用」。

**构建时报 `certificate pinning patch missing`**

没有执行 `tools\patch-plugins.ps1`，或 `flutter pub get` 后插件被还原。重新执行补丁脚本再构建。

**Windows 编译报找不到 nuget.exe**

WebView2 的 C++ 依赖用 nuget 还原，把 `nuget.exe` 放到 `tools\` 下（`build-all.bat` 会检查）。

## 已知限制

- Windows TUN 需要管理员权限；权限不足时连接会失败
- Android 的 `system` 栈在部分设备上会卡死，客户端只保留 `mixed` 和 `gvisor`
- Android 分应用代理必须重新连接才生效，TUN 建立后无法动态修改应用列表
- 国内分流依赖内置规则集，HTTPDNS、IP 直连等绕过域名的流量可能仍走代理
- 仓库不包含 `libbox.aar`、`sing-box.exe`、`libcronet.dll`，需要自行准备
- 面板若改用公网 CA 证书，WebView 层不再做指纹校验

## 许可证

见 [LICENSE](LICENSE)。
