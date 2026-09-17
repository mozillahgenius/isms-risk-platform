# CHK-ENDPOINT-008 `remoteaccess` 承認判断待ち

## 現状

v2定義の `admin_exclusions` は、システムアカウントとして `root` と `_` 始まりだけを除外する。
実在するローカル管理者 `remoteaccess` は除外しない。

開発機での実測:

```text
GroupMembership: root service-user remoteaccess _mbsetupuser
```

したがって、現在の収集値は `service-user` と `remoteaccess` の2件である。
CHK-ENDPOINT-008の現在の閾値は2以下なので、この実測だけでは赤にはならない。
ただし `remoteaccess` が実在の特権アカウントであることは、件数とは別の承認判断を要する。

## ユーザー判断事項

`remoteaccess` を既知のサービスアカウントとして許容するか、また許容する場合の根拠
（用途、管理責任者、必要性、見直し期限）を確認する。

承認されるまでは、定義から名前で除外しない。承認後に定義へ残す場合も、承認記録と根拠を
同じ変更の証跡へ紐付ける。今回、作成元や運用目的の調査は行わない。
