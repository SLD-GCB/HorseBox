# HorseBox 10.69 更新说明

## Android 10.69

- 应用锁开启时启用系统 `FLAG_SECURE`。
- 最近任务缩略图不再显示 HorseBox 页面。
- 系统截图失败。
- 屏幕录制为黑屏。
- 关闭应用锁后，截图和最近任务恢复正常。
- 切到后台立即显示锁屏；回来未超时自动解锁，超时要求验证。
- 修正应用锁开启时的后台页面泄露。

## 说明

- 系统不允许把最近任务缩略图替换成自定义锁屏页，因此显示为空白/黑屏。
- `FLAG_SECURE` 只影响 Android；Windows 端应用锁不防录屏。
- 应用锁关闭时，防截图不生效。

## 版本

```
versionCode：48100
versionName：10.69
package：com.horseui.horsebox
```
