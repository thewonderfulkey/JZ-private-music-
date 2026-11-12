## GitHub 已更新为 v2.1.73，并以「第四版」发布

- 仓库 `thewonderfulkey/JZ-private-music-`：main 提交 `bf51a26`，根目录 APK 换成 `JZ Music-v2.1.73.apk`（29,617,967 B），`05-源码归档` 换成 v2.1.73 完整工程（78 个条目 / 18,174,478 B）。
- Tag `v2.1.73` 指向 `bf51a26`。
- Release「第四版 v2.1.73」：
  https://github.com/thewonderfulkey/JZ-private-music-/releases/tag/v2.1.73
  资产：`JZ-Music-v2.1.73.apk`（29,617,967 B）+ `JZ-music-helper-android-source-v2.1.73.zip`（18,174,478 B）。

说明两点：
1. 「第四版」这个 Release 是原来那条（第四版 v2.1.72）改版而来，标题与 tag 换成 v2.1.73、旧资产已替换，所以版本序列上第四版只有一条、指向最新版；v2.1.72 的包仍留在仓库历史提交 `ee2ec70` 里。
2. 这次 GitHub 只能走 REST 接口写：本机 `git push` 到 github.com 的 TLS 握手持续失败（schannel 与 openssl 两种后端都试过、`api.github.com` 与 `github.com` 网页均正常），所以远端提交由 API 生成，本地仓库停在 `0598b05`（内容与远端一致、hash 不同）。等网络恢复后 `git fetch && git reset --hard origin/main` 即可对齐。
