# XVPN · Open passage

柔和的薄荷绿拱形轮廓环抱青蓝色路径，表达保护、连接与畅通。
相比旧版玫红盾牌和衬线 V，新标识与现有界面绿色强调色保持一致。

## 母版与导出

- `logo.svg`：可编辑矢量母版，透明背景，渐变折面。
- `logo.png`：1024px 母版渲染，真正 RGBA；不含棋盘格。
- `app-icon-1024.png`：不透明、未裁圆角的方形图标。
- `google-play-512.png`：512px 不透明商店素材。
- `preview.png`：平台遮罩和小尺寸视觉检查，不是设备截图。
- `ios/AppIcon.appiconset`：独立 iOS 资源目录；项目尚无 iOS 工程，未声称已完成 iOS 接入或构建。

Android：五档 legacy PNG，API 26 自适应图层，API 33 单色图层；
前景为 108dp 画布，主体最大 52dp，位于 66dp 安全区内。
通知使用独立白色 alpha 轮廓。Windows ICO 包含 16、20、24、32、40、48、64、96、128、256px。
Flutter 品牌组件使用深色底图标，在亮暗主题中保持对比度。

用 SVG 渲染器（例如 Node.js sharp）将 `logo.svg` 渲染到 `logo.png` 后，
从仓库根目录执行 `python scripts/export-icons.py`（需要 Pillow）即可重建资源。
导出脚本校验 iOS 尺寸与无 alpha、ICO 帧集合和 Android 前景安全区。
SVG 才是最终设计源；PNG 为它的渲染结果，不能独立修改后当作新母版。

## 平台依据

- [Android adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)
- [Apple asset catalogs](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple app icon design](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Windows icon construction](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction)

iOS 提供传统静态 AppIcon 资源，可由系统遮罩；未制作或验证 Icon Composer
分层 Liquid Glass 图标。商店最终审核和各设备启动器的实际显示需要对应平台验证。
PC 接入范围为项目现有 Windows 工程，未新增 macOS/Linux 工程。

## 设计过程与提示词

使用内置 image_gen 探索开放通道概念，随后整理为可编辑 SVG 母版并导出资源。
最终概念提示词：

> Design an open protected passage for XVPN. A substantial continuous mint-teal
> ribbon forms a welcoming rounded arch around an open tunnel. A flowing cyan
> path bends from the lower entrance toward the center. Broad sculptural surfaces,
> restrained tonal depth, readable small silhouette, generous breathing room.
> No X, crossed diagonals, checkmarks, prohibition signs, padlock, text or badges.
> Soft mint and cool teal on deep navy. Actual app icon, not a mockup.

最终交付为确定性 SVG 几何母版，简化生成概念中的纹理与光效，
透明图层与小尺寸资源均由母版生成，不包含生成图的背景伪影。
