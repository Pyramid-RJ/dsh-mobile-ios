# AltStore 源

给 AltStore / SideStore / Fresh 用的应用源。源里只有这一个 App，安装的始终是**未签名** `.ipa`，由 AltStore 用你自己的 Apple ID 重签。

## 加到 AltStore

在 AltStore 的 **Sources → +** 里填下面任意一个地址：

| 地址 | 特点 |
| --- | --- |
| `https://github.com/Pyramid-RJ/dsh-mobile-ios/releases/latest/download/source.json` | **推荐**。指向最新一次 Release 附带的源文件，永远是最新版本 |
| `https://raw.githubusercontent.com/Pyramid-RJ/dsh-mobile-ios/main/altstore/source.json` | 仓库里的副本，便于直接查看内容；更新依赖 Release 流程提交回来 |

两个地址都要求仓库是公开的，且使用 HTTPS。

## 它是怎么保持更新的

`source.json` 不是手写的，而是发布流程生成的：

1. `git tag ios-v0.1.0 && git push origin ios-v0.1.0` 触发 [`ios-release.yml`](../.github/workflows/ios-release.yml)；
2. 构建未签名 `.ipa` → 校验 → 计算大小；
3. [`build_source.py`](build_source.py) 以上一个 Release 的 `source.json` 为基础，把新版本插到 `versions` 最前面（版本号相同则替换）；
4. `source.json` 作为 Release 资产附上，所以 `releases/latest/download/source.json` 自动指向新内容；
5. 同一份文件尽量提交回 `main`，让仓库副本与线上一致。

新版本会不会覆盖旧版本：不会。`versions` 是累加的，AltStore 里点开 App 能看到历史版本并回退。

## 手工重建

改了 Bundle ID、图标或文案后，本地可以先验证格式：

```bash
python3 altstore/build_source.py \
  --base altstore/source.json --output /tmp/source.json \
  --repo Pyramid-RJ/dsh-mobile-ios --tag ios-v0.1.0 --version 0.1.0 \
  --bundle-id io.example.dshmobile.ios --ipa-name DSHMobile-0.1.0-unsigned.ipa \
  --size 112153 --min-os 17.0
```

## 注意

- `downloadURL` 指向 Release 资产，所以**必须先有对应的 Release**，AltStore 才装得上；源文件先于 Release 出现时会显示"下载失败"。
- 免费 Apple ID 的签名 7 天过期，AltStore 需要在同一 Wi-Fi 下有 AltServer 才能自动续签；覆盖安装即可，**不要删除 App**（否则可能丢配对数据）。
- 这个源描述的是社区衍生版本，不是上游 `saya-ch/dsh-mobile` 的官方 iOS 版。
