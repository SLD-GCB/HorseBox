# HorseBox

HorseBox 是 HorseUI 面板的专用双端代理客户端，一套 Flutter 代码同时构建 Windows 和 Android。

- **Windows**：以子进程方式运行官方 `sing-box.exe`，支持 TUN 和混合端口，关闭窗口后驻留托盘。
- **Android**：通过 `libbox` + `VpnService` 接管流量，前台通知常驻，支持分应用代理。

客户端本身不包含节点，所有节点和分流配置都来自 HorseUI 面板的订阅接口。

## 功能

- 订阅拉取：`https://面板地址/sub/<令牌>?target=singbox`
- 自签证书：添加订阅时填写面板证书 SHA-256 指纹，双端共用同一套校验
- 国内分流：内置 `geosite-cn` / `geoip-cn`，国内域名和 IP 直连，其余走代理
- 自定义规则：域名后缀、域名关键字、IP 段，可指定直连、代理或拦截
- 分应用代理（Android）：可选择走代理的应用和强制直连的应用，系统应用默认直连
- 节点管理：自动选择、手动切换、单节点测速、全部测速
- 网络设置：混合端口、TUN、TUN 栈（mixed / gvisor）、MTU、IPv6、局域网
- DNS：沿用面板下发，或自定义 UDP / DoT / DoH
- 其他：hosts 映射、连接列表、实时流量、日志、深色/浅色主题、Windows 数据目录自定义

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
│  └─ lib/src/             订阅、配置补丁、Clash API、内核进程、本地存储
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

## 构建 Windows

```bash
cd UI
flutter pub get
flutter build windows --release
```

构建完成后把内核复制进产物：

```bat
windows\package.bat
```

产物在 `UI\build\windows\x64\runner\Release\`。TUN 模式需要以管理员身份运行。

## 构建 Android

### 1. 签名配置

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

### 2. 构建

```bash
cd UI
flutter pub get
flutter build apk --release --target-platform android-arm64
```

产物：`UI/build/app/outputs/flutter-apk/app-release.apk`

没有 `key.properties` 时 Gradle 会直接报错，不会静默回退到 debug 签名。

## 一键打包

`build-all.bat` 会依次构建 Windows 和 Android，成品输出到 `app/`。

运行前按本机环境修改脚本顶部：

```bat
set "FLUTTER=D:\flutter\bin\flutter.bat"
set "JAVA_HOME=%USERPROFILE%\.jdks\jbr-21.0.11"
set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "NDK_VER=27.2.12479018"
```

## 使用方法

### 1. 在面板创建订阅

HorseUI 面板 → 用户 → 订阅，复制 sing-box 订阅地址：

```
https://面板地址/sub/<令牌>?target=singbox
```

如果面板使用自签证书，先到面板「设置 → 客户端证书指纹」点「显示」或「复制」，拿到 SHA-256。

### 2. 添加订阅

HorseBox → 订阅 → 添加订阅，填写：

- 订阅地址
- 名称（可选）
- 面板证书 SHA-256 指纹（自签证书时必填）

添加后会自动拉取一次并展开节点列表。卡片右上角的圆形按钮可以刷新节点。

### 3. 连接

回到首页点「连接」。

- Windows：TUN 模式需要管理员权限；关闭窗口会隐藏到托盘，代理继续运行。
- Android：首次连接会申请 VPN 权限和通知权限；通知栏常驻，可直接在通知里断开。

### 4. 分应用代理（Android）

设置 → 分应用代理：

- **代理应用**：只勾选需要走代理的应用；不勾选表示代理全部用户应用。
- **直连应用**：强制不进入 VPN，例如国内视频、国内购物。
- **系统应用**：默认直连，不显示在列表里；Google Play 服务、Google Services Framework、Play 商店除外，可以手动勾选。

保存后需要断开再重连才会生效。

### 5. 分流规则

设置 → 分流规则：

- 内置规则始终生效：`geosite-cn` 和 `geoip-cn` 直连。
- 自定义规则支持域名后缀、域名关键字、IP 段，动作可选直连、走代理、拦截。
- 规则顺序：自定义规则 → 国内域名/IP → 私有 IP → 其余走代理。

### 6. 节点选择与测速

展开订阅卡片后：

- 「自动选择」使用 urltest 按延迟自动挑选。
- 点击任意节点可手动切换，当前连接会立即生效。
- 节点右侧「测速」显示延迟，顶部「全部测速」批量检测。

## 已知限制

- Windows TUN 需要管理员权限；权限不足时连接会失败，需要以管理员身份重新启动。
- Android 的 `system` 栈在部分设备上会卡死，客户端只保留 `mixed` 和 `gvisor`。
- Android 分应用代理必须重新连接才生效，TUN 建立后无法动态修改应用列表。
- 国内分流依赖内置规则集，HTTPDNS、IP 直连等绕过域名的流量可能仍走代理；必要时把应用加入「直连应用」。
- 仓库不包含 `libbox.aar`、`sing-box.exe`、`libcronet.dll`，需要自行准备。

## 许可证

见 [LICENSE](LICENSE)。
