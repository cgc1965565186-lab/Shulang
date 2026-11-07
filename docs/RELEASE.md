# 构建、签名与发布

./Scripts/build-app.sh 依次执行：单元测试 → universal2 release 编译 →
组装 bundle（Info.plist / 可执行文件 / AppIcon.icns / PkgInfo）→ ad-hoc 签名
→ 产物校验与 SHA-256 清单。

脚本包含关键校验：主可执行文件必须含 GUI 特征、不含 CLI 特征。
APFS 默认大小写不敏感，Shulang（GUI）与 shulang（CLI）同名会互相覆盖；
因此 CLI 的 SwiftPM product 名为 shulang-cli，脚本再复制为用户可见的 shulang。

## 签名现状

当前为 ad-hoc 签名（codesign -s -），未使用 Developer ID，未公证。
本地构建不带 quarantine 属性，可直接打开；从网络下载后被 Gatekeeper 拦截时，
由用户在「系统设置 → 隐私与安全性」自行允许，项目不提供静默绕过脚本。

## 官方发布应补齐

1. Developer ID Application 签名 + Hardened Runtime + secure timestamp
2. xcrun notarytool submit 公证 + xcrun stapler staple 装订
3. codesign --verify --deep --strict 与 spctl -a -vvv --type exec 校验
4. 固定 Xcode / Swift 版本、锁定 Package.resolved、公开完整构建脚本
5. 生成 SPDX SBOM 与 GitHub Artifact Attestations / SLSA provenance
6. 校验实际发布文件的 SHA-256，Release 一经发布不覆盖；可复现性另针对固定工具链的未签名载荷验证，带时间戳的签名产物单独验证签名与来源
7. 签名私钥仅在受保护 tag 的受控 runner 使用；PR 只跑无签名构建
8. Sparkle appcast 或 Homebrew Cask 只分发已签名产物，校验后才替换

当前版本尚未实现第 1–7 步自动化，详见 docs/ROADMAP.md。
